import CryptoKit
import Darwin
import Foundation
import Network
import dnssd

public protocol BonjourBrowsing: Sendable {
    func browse(
        onProgress: @escaping @Sendable (DiscoveryProgress) -> Void
    ) async throws -> [BonjourServiceDescriptor]
    func cancel()
    func handleSceneActivity(_ activity: AppSceneActivity)
}

public struct DiscoveryProbeResult: Equatable, Sendable {
    public var info: ParsedDeviceInfo
    public var fingerprint: String

    public init(info: ParsedDeviceInfo, fingerprint: String) {
        self.info = info
        self.fingerprint = fingerprint
    }
}

public final class NetworkBonjourBrowser: BonjourBrowsing, @unchecked Sendable {
    private let lock = NSLock()
    private var runtime: BonjourBrowserRuntime?

    public init() {}

    public func browse(
        onProgress: @escaping @Sendable (DiscoveryProgress) -> Void
    ) async throws -> [BonjourServiceDescriptor] {
        let runtime = BonjourBrowserRuntime(onProgress: onProgress)
        let installed = lock.withLock {
            guard self.runtime == nil else { return false }
            self.runtime = runtime
            return true
        }
        guard installed else {
            throw VizioControlError.message("A TV scan is already running.")
        }
        defer {
            lock.withLock {
                if self.runtime === runtime { self.runtime = nil }
            }
        }
        return try await runtime.run()
    }

    public func cancel() {
        lock.withLock { runtime }?.cancel()
    }

    public func handleSceneActivity(_ activity: AppSceneActivity) {
        lock.withLock { runtime }?.handleSceneActivity(activity)
    }
}

private final class BonjourBrowserRuntime: @unchecked Sendable {
    private static let serviceTypes = ["_viziocast._tcp", "_googlecast._tcp", "_airplay._tcp"]

    private let queue = DispatchQueue(label: "com.shlummie.viziocontrol.bonjour-browser")
    private let state = BonjourPermissionState(browserCount: serviceTypes.count)
    private let onProgress: @Sendable (DiscoveryProgress) -> Void
    private let lock = NSLock()
    private var browsers: [NWBrowser] = []
    private var collectionTimer: DispatchSourceTimer?
    private var collectionContinuation: CheckedContinuation<Void, Error>?
    private var scanning = false
    private var cancelled = false

    init(onProgress: @escaping @Sendable (DiscoveryProgress) -> Void) {
        self.onProgress = onProgress
    }

    func run() async throws -> [BonjourServiceDescriptor] {
        onProgress(.waitingForPermission)
        startBrowsers()
        do {
            try await withTaskCancellationHandler {
                try await state.waitUntilReadyOrDenied()
            } onCancel: {
                self.cancel()
            }
        } catch {
            stopBrowsers()
            if case VizioControlError.localNetworkDenied = error {
                onProgress(.denied)
            }
            throw error
        }

        lock.withLock { scanning = true }
        onProgress(.scanning)
        do {
            try await withTaskCancellationHandler {
                try await collectionDelay()
            } onCancel: {
                self.cancel()
            }
        } catch {
            stopBrowsers()
            throw error
        }
        let results = await state.services()
        stopBrowsers()
        return results
    }

    func cancel() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !cancelled else { return nil }
            cancelled = true
            collectionTimer?.cancel()
            collectionTimer = nil
            let continuation = collectionContinuation
            collectionContinuation = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
        stopBrowsers()
        Task { await state.cancel() }
    }

    func handleSceneActivity(_ activity: AppSceneActivity) {
        switch activity {
        case .background:
            cancel()
        case .inactive:
            let shouldCancel = lock.withLock { scanning }
            if shouldCancel { cancel() }
            else { Task { await state.setSceneActivity(.inactive) } }
        case .active:
            Task { await state.setSceneActivity(.active) }
        }
    }

    private func startBrowsers() {
        let reference = BrowserRuntimeReference(value: self)
        queue.sync {
            guard !cancelled else { return }
            browsers = Self.serviceTypes.enumerated().map { index, type in
                let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: type, domain: "local.")
                let browser = NWBrowser(for: descriptor, using: .tcp)
                browser.stateUpdateHandler = { state in
                    Task { await reference.value.state.updateBrowser(index: index, state: state) }
                }
                browser.browseResultsChangedHandler = { results, _ in
                    let services = results.compactMap { result -> BonjourServiceDescriptor? in
                        guard case let .service(name, type, domain, interface) = result.endpoint else { return nil }
                        return BonjourServiceDescriptor(
                            name: name,
                            type: type,
                            domain: domain,
                            interfaceIndex: interface.map { UInt32($0.index) } ?? 0
                        )
                    }
                    Task { await reference.value.state.replaceServices(for: index, with: services) }
                }
                browser.start(queue: queue)
                return browser
            }
        }
    }

    private func stopBrowsers() {
        let reference = BrowserRuntimeReference(value: self)
        queue.async {
            reference.value.browsers.forEach { $0.cancel() }
            reference.value.browsers = []
        }
    }

    private func collectionDelay() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(3_200))
            let reference = BrowserRuntimeReference(value: self)
            timer.setEventHandler {
                let completion = reference.value.lock.withLock { () -> CheckedContinuation<Void, Error>? in
                    guard !reference.value.cancelled else { return nil }
                    reference.value.collectionTimer = nil
                    let continuation = reference.value.collectionContinuation
                    reference.value.collectionContinuation = nil
                    return continuation
                }
                completion?.resume()
            }
            let cancelImmediately = lock.withLock {
                if cancelled { return true }
                collectionTimer = timer
                collectionContinuation = continuation
                return false
            }
            if cancelImmediately {
                timer.cancel()
                continuation.resume(throwing: CancellationError())
            } else {
                timer.resume()
            }
        }
    }
}

actor BonjourPermissionState {
    typealias Sleep = @Sendable (Duration) async -> Void

    private enum BrowserCondition {
        case pending
        case ready
        case policyDenied
        case terminal
    }

    private enum Resolution {
        case ready
        case denied
        case cancelled
    }

    private var conditions: [BrowserCondition]
    private var serviceSets: [Int: Set<BonjourServiceDescriptor>] = [:]
    private var continuation: CheckedContinuation<Void, Error>?
    private var resolution: Resolution?
    private var active = true
    private var sawInactive = false
    private var denialGeneration = 0
    private let sleep: Sleep

    init(
        browserCount: Int,
        sleep: @escaping Sleep = { try? await ContinuousClock().sleep(for: $0) }
    ) {
        conditions = Array(repeating: .pending, count: browserCount)
        self.sleep = sleep
    }

    func waitUntilReadyOrDenied() async throws {
        if let resolution {
            return try resolvedValue(resolution)
        }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func updateBrowser(index: Int, state: NWBrowser.State) {
        guard conditions.indices.contains(index), resolution == nil else { return }
        switch state {
        case .ready:
            conditions[index] = .ready
            resolveSuccess()
        case let .waiting(error):
            if case let .dns(code) = error, code == kDNSServiceErr_PolicyDenied {
                conditions[index] = .policyDenied
                scheduleDenialIfNeeded()
            } else {
                conditions[index] = .pending
            }
        case let .failed(error):
            if case let .dns(code) = error, code == kDNSServiceErr_PolicyDenied {
                conditions[index] = .policyDenied
                scheduleDenialIfNeeded()
            } else {
                conditions[index] = .terminal
                resolveIfNoLiveBrowsers()
            }
        case .cancelled:
            conditions[index] = .terminal
            resolveIfNoLiveBrowsers()
        case .setup:
            conditions[index] = .pending
        @unknown default:
            conditions[index] = .pending
        }
    }

    func replaceServices(for index: Int, with services: [BonjourServiceDescriptor]) {
        serviceSets[index] = Set(services)
    }

    func services() -> [BonjourServiceDescriptor] {
        Array(serviceSets.values.reduce(into: Set<BonjourServiceDescriptor>()) { result, services in
            result.formUnion(services)
        })
    }

    func setSceneActivity(_ activity: AppSceneActivity) {
        guard resolution == nil else { return }
        switch activity {
        case .inactive:
            active = false
            sawInactive = true
            denialGeneration += 1
        case .active:
            active = true
            scheduleDenialIfNeeded(delay: sawInactive ? .milliseconds(500) : .seconds(1))
        case .background:
            cancel()
        }
    }

    func cancel() {
        guard resolution == nil else { return }
        resolution = .cancelled
        denialGeneration += 1
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }

    private func resolveSuccess() {
        guard resolution == nil else { return }
        resolution = .ready
        denialGeneration += 1
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }

    private func scheduleDenialIfNeeded(delay: Duration = .seconds(1)) {
        guard active,
              resolution == nil,
              denialIsStable else { return }
        denialGeneration += 1
        let generation = denialGeneration
        Task {
            await sleep(delay)
            finalizeDenial(generation: generation)
        }
    }

    private func finalizeDenial(generation: Int) {
        guard generation == denialGeneration,
              active,
              resolution == nil,
              denialIsStable else { return }
        resolution = .denied
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: VizioControlError.localNetworkDenied)
    }

    private var denialIsStable: Bool {
        let hasDenial = conditions.contains { if case .policyDenied = $0 { true } else { false } }
        return hasDenial && conditions.allSatisfy {
            switch $0 {
            case .policyDenied, .terminal: true
            case .pending, .ready: false
            }
        }
    }

    private func resolveIfNoLiveBrowsers() {
        if conditions.allSatisfy({ if case .terminal = $0 { true } else { false } }) {
            resolveSuccess()
        } else {
            scheduleDenialIfNeeded()
        }
    }

    private func resolvedValue(_ resolution: Resolution) throws {
        switch resolution {
        case .ready: return
        case .denied: throw VizioControlError.localNetworkDenied
        case .cancelled: throw CancellationError()
        }
    }
}

public protocol DeviceDiscovering: Sendable {
    func discover(
        cached: PairedDevice?,
        manualEndpoint: String,
        manualMAC: String,
        onProgress: @escaping @Sendable (DiscoveryProgress) -> Void
    ) async throws -> [DeviceCandidate]
    func cancel()
    func handleSceneActivity(_ activity: AppSceneActivity)
}

public final class DiscoveryService: DeviceDiscovering, @unchecked Sendable {
    public typealias Probe = @Sendable (DeviceEndpoint) async throws -> DiscoveryProbeResult

    fileprivate struct EndpointHint: Sendable {
        var endpoint: DeviceEndpoint
        var source: DiscoverySource
        var macAddress: String?
    }

    private let browser: any BonjourBrowsing
    private let resolver: any BonjourResolving
    private let probe: Probe

    public init(
        browser: any BonjourBrowsing = NetworkBonjourBrowser(),
        resolver: any BonjourResolving = BonjourResolver(),
        probe: @escaping Probe = DiscoveryService.productionProbe
    ) {
        self.browser = browser
        self.resolver = resolver
        self.probe = probe
    }

    public func discover(
        cached: PairedDevice?,
        manualEndpoint: String,
        manualMAC: String,
        onProgress: @escaping @Sendable (DiscoveryProgress) -> Void = { _ in }
    ) async throws -> [DeviceCandidate] {
        let normalizedManualMAC: String?
        if manualMAC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalizedManualMAC = nil
        } else if let normalized = normalizeMACAddress(manualMAC) {
            normalizedManualMAC = normalized
        } else {
            throw VizioControlError.invalidMACAddress
        }

        let services = try await browser.browse(onProgress: onProgress)
        var hints: [EndpointHint] = []
        if let cached {
            hints.append(EndpointHint(endpoint: cached.endpoint, source: .cached, macAddress: cached.macAddress))
        }
        let manual = manualEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty {
            let endpoint = try await validateManualEndpoint(manual)
            hints.append(EndpointHint(endpoint: endpoint, source: .manual, macAddress: normalizedManualMAC))
        }

        let resolved = await withTaskGroup(of: ResolvedBonjourService?.self) { group in
            for service in services {
                group.addTask { [resolver] in
                    try? await resolver.resolve(service, timeout: .seconds(2.5))
                }
            }
            var results: [ResolvedBonjourService] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }
        for service in resolved {
            let mac = ["deviceid", "deviceId", "mac", "macAddress", "wifi", "eth"]
                .compactMap { service.txt[$0] }
                .compactMap(normalizeMACAddress)
                .first
            hints.append(EndpointHint(endpoint: service.endpoint, source: .mdns, macAddress: mac))
        }

        let mergedHints = mergeEndpointHints(hints)
        let candidates = await withTaskGroup(of: DeviceCandidate?.self) { group in
            for hint in mergedHints {
                group.addTask { [probe] in
                    do {
                        let result = try await probe(hint.endpoint)
                        guard normalizeCertificateFingerprint(result.fingerprint) != nil else { return nil }
                        let serial = nonempty(result.info.serial)
                        let mac = normalizeMACAddress(hint.macAddress)
                        let identity = serial ?? mac ?? canonicalEndpoint(hint.endpoint)
                        return DeviceCandidate(
                            id: candidateID(identity: identity),
                            name: nonempty(result.info.name) ?? "Vizio TV",
                            endpoint: hint.endpoint,
                            model: nonempty(result.info.model),
                            serial: serial,
                            fingerprint: normalizeCertificateFingerprint(result.fingerprint),
                            macAddress: mac,
                            source: hint.source
                        )
                    } catch {
                        return nil
                    }
                }
            }
            var values: [DeviceCandidate] = []
            for await candidate in group {
                if let candidate { values.append(candidate) }
            }
            return values
        }
        onProgress(.idle)
        return mergeCandidates(candidates).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func cancel() {
        browser.cancel()
    }

    public func handleSceneActivity(_ activity: AppSceneActivity) {
        browser.handleSceneActivity(activity)
    }

    public static func productionProbe(endpoint: DeviceEndpoint) async throws -> DiscoveryProbeResult {
        let transport = URLSessionSmartCastTransport(endpoint: endpoint, trustMode: .firstContact)
        let client = SmartCastClient(endpoint: endpoint, transport: transport)
        let response = try await client.getDeviceInfo(timeout: .seconds(2.5))
        guard !response.leafFingerprint.isEmpty else {
            throw VizioControlError.message("TV did not provide a TLS certificate fingerprint.")
        }
        return DiscoveryProbeResult(info: parseDeviceInfo(response.body), fingerprint: response.leafFingerprint)
    }
}

public func isSameDevice(_ device: PairedDevice, _ candidate: DeviceCandidate) -> Bool {
    if let deviceSerial = nonempty(device.serial), let candidateSerial = nonempty(candidate.serial) {
        return deviceSerial == candidateSerial
    }
    if let deviceMAC = normalizeMACAddress(device.macAddress),
       let candidateMAC = normalizeMACAddress(candidate.macAddress) {
        return deviceMAC == candidateMAC
    }
    if device.serial != nil || candidate.serial != nil { return false }
    return device.id == candidate.id && canonicalEndpoint(device.endpoint) == canonicalEndpoint(candidate.endpoint)
}

public func validateManualEndpoint(_ value: String) async throws -> DeviceEndpoint {
    let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else { throw VizioControlError.invalidManualEndpoint }
    if isIPv4Address(candidate) {
        guard isLocalIPv4Address(candidate) else { throw VizioControlError.invalidManualEndpoint }
        return DeviceEndpoint(host: candidate, resolvedAddresses: [candidate])
    }
    if isIPv6Address(candidate) {
        guard isIPv6ULA(candidate), !candidate.contains("%") else {
            throw VizioControlError.invalidManualEndpoint
        }
        return DeviceEndpoint(host: candidate.lowercased(), resolvedAddresses: [candidate.lowercased()])
    }

    let hostname = candidate.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard isAllowedLocalHostname(hostname) else { throw VizioControlError.invalidManualEndpoint }
    let addresses = await resolveHostAddresses(hostname).filter(isLocalAddress)
    guard !addresses.isEmpty else { throw VizioControlError.invalidManualEndpoint }
    return DeviceEndpoint(host: hostname, resolvedAddresses: addresses)
}

func mergeCandidates(_ candidates: [DeviceCandidate]) -> [DeviceCandidate] {
    var merged: [DeviceCandidate] = []
    for candidate in candidates {
        guard let index = merged.firstIndex(where: { candidatesShareIdentity($0, candidate) }) else {
            merged.append(candidate)
            continue
        }
        var current = merged[index]
        let candidatePreferred = sourceRank(candidate.source) < sourceRank(current.source)
        let addresses = Set(current.endpoint.resolvedAddresses).union(candidate.endpoint.resolvedAddresses)
        if candidatePreferred {
            current.endpoint = candidate.endpoint
            current.source = candidate.source
            current.fingerprint = candidate.fingerprint
        }
        current.endpoint.resolvedAddresses = Array(addresses).sorted()
        current.name = current.name == "Vizio TV" ? candidate.name : current.name
        current.model = current.model ?? candidate.model
        current.serial = current.serial ?? candidate.serial
        current.macAddress = normalizeMACAddress(current.macAddress) ?? normalizeMACAddress(candidate.macAddress)
        let identity = nonempty(current.serial) ?? current.macAddress ?? canonicalEndpoint(current.endpoint)
        current.id = candidateID(identity: identity)
        merged[index] = current
    }
    return merged
}

private func mergeEndpointHints(_ hints: [DiscoveryService.EndpointHint]) -> [DiscoveryService.EndpointHint] {
    var result: [DiscoveryService.EndpointHint] = []
    for hint in hints {
        if let index = result.firstIndex(where: { canonicalEndpoint($0.endpoint) == canonicalEndpoint(hint.endpoint) }) {
            var existing = result[index]
            existing.endpoint.resolvedAddresses = Array(
                Set(existing.endpoint.resolvedAddresses).union(hint.endpoint.resolvedAddresses)
            ).sorted()
            existing.macAddress = normalizeMACAddress(existing.macAddress) ?? normalizeMACAddress(hint.macAddress)
            if sourceRank(hint.source) < sourceRank(existing.source) {
                existing.endpoint.host = hint.endpoint.host
                existing.endpoint.interfaceIndex = hint.endpoint.interfaceIndex
                existing.source = hint.source
            }
            result[index] = existing
        } else {
            result.append(hint)
        }
    }
    return result
}

private func candidatesShareIdentity(_ left: DeviceCandidate, _ right: DeviceCandidate) -> Bool {
    if let leftSerial = nonempty(left.serial), let rightSerial = nonempty(right.serial) {
        return leftSerial == rightSerial
    }
    if let leftMAC = normalizeMACAddress(left.macAddress), let rightMAC = normalizeMACAddress(right.macAddress) {
        return leftMAC == rightMAC
    }
    return canonicalEndpoint(left.endpoint) == canonicalEndpoint(right.endpoint)
}

private func sourceRank(_ source: DiscoverySource) -> Int {
    switch source {
    case .mdns: 0
    case .manual: 1
    case .cached: 2
    }
}

func canonicalEndpoint(_ endpoint: DeviceEndpoint) -> String {
    let host = endpoint.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
    return endpoint.interfaceIndex.map { "\(host)%\($0)" } ?? host
}

private func candidateID(identity: String) -> String {
    SHA256.hash(data: Data(identity.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}

private func nonempty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}

private func isAllowedLocalHostname(_ value: String) -> Bool {
    guard !value.isEmpty,
          value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else {
        return false
    }
    return !value.contains(".") || value.hasSuffix(".local")
}

private func resolveHostAddresses(_ host: String) async -> [String] {
    let task = Task.detached { () -> [String] in
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return [] }
        defer { if let result { freeaddrinfo(result) } }
        var values: Set<String> = []
        var cursor = result
        while let current = cursor {
            if let address = current.pointee.ai_addr, let value = numericHost(address) {
                values.insert(value)
            }
            cursor = current.pointee.ai_next
        }
        return Array(values).sorted()
    }
    return await task.value
}

private func numericHost(_ address: UnsafePointer<sockaddr>) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let result = getnameinfo(
        address,
        socklen_t(address.pointee.sa_len),
        &buffer,
        socklen_t(buffer.count),
        nil,
        0,
        NI_NUMERICHOST
    )
    return result == 0 ? decodeCString(buffer) : nil
}

private func decodeCString(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func isLocalAddress(_ value: String) -> Bool {
    isLocalIPv4Address(value) || isIPv6ULA(value) || isIPv6LinkLocal(value)
}

func isIPv4Address(_ value: String) -> Bool {
    var address = in_addr()
    return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
}

func isIPv6Address(_ value: String) -> Bool {
    var address = in6_addr()
    return value.withCString { inet_pton(AF_INET6, $0, &address) } == 1
}

func isLocalIPv4Address(_ value: String) -> Bool {
    guard let bytes = ipv4Bytes(value) else { return false }
    return bytes[0] == 10
        || (bytes[0] == 172 && (16...31).contains(bytes[1]))
        || (bytes[0] == 192 && bytes[1] == 168)
        || (bytes[0] == 169 && bytes[1] == 254)
}

private func ipv4Bytes(_ value: String) -> [UInt8]? {
    var address = in_addr()
    guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
    return withUnsafeBytes(of: &address.s_addr) { Array($0) }
}

private func isIPv6ULA(_ value: String) -> Bool {
    guard let bytes = ipv6Bytes(value) else { return false }
    return (bytes[0] & 0xFE) == 0xFC
}

private func isIPv6LinkLocal(_ value: String) -> Bool {
    guard let bytes = ipv6Bytes(value) else { return false }
    return bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
}

private func ipv6Bytes(_ value: String) -> [UInt8]? {
    var address = in6_addr()
    let raw = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? value
    guard raw.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
    return withUnsafeBytes(of: &address) { Array($0) }
}

private struct BrowserRuntimeReference<Value>: @unchecked Sendable {
    let value: Value
}
