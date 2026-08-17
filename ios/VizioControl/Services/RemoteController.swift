import Foundation
import Observation
import Security

public typealias SmartCastClientFactory = @Sendable (
    DeviceEndpoint,
    SmartCastTrustMode,
    String?,
    String?
) -> any SmartCastControlling

@MainActor
@Observable
public final class RemoteController {
    public static let standbyFailureMessage = "TV stayed on because network standby could not be verified. On the TV, choose Menu > System > Power Mode > Quick Start, then try Standby again."
    public static let wakeTimeoutMessage = "A wake signal was sent, but TV did not start its network controls. Turn it on once with the physical button and enable Quick Start mode for network power-on."
    public static let noTVsFoundMessage = "No compatible TVs responded. Confirm Local Network access, keep the TV on, or enter its private IPv4 address and scan again."

    public private(set) var isLoading = true
    public private(set) var isDiscovering = false
    public private(set) var discoveryProgress: DiscoveryProgress = .idle
    public private(set) var candidates: [DeviceCandidate] = []
    public private(set) var pairing: PairingStart?
    public private(set) var isPairing = false
    public private(set) var isWaking = false
    public private(set) var pairedDevice: PairedDevice?
    public private(set) var tvState = TVState()
    public private(set) var settings = AppSettings()
    public private(set) var commands: [SavedCommand] = []
    public private(set) var errorBanner: String?
    public private(set) var successStatus: String?

    @ObservationIgnored private let store: any AppStoring
    @ObservationIgnored private let keychain: any TokenStoring
    @ObservationIgnored private let discovery: any DeviceDiscovering
    @ObservationIgnored private let clientFactory: SmartCastClientFactory
    @ObservationIgnored private let catalog: any AppCataloging
    @ObservationIgnored private let parser: any RequestParsing
    @ObservationIgnored private let wakeSender: any WakeOnLANSending
    @ObservationIgnored private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void

    @ObservationIgnored private var client: (any SmartCastControlling)?
    @ObservationIgnored private var pairingClient: (any SmartCastControlling)?
    @ObservationIgnored private var discoveryTask: Task<[DeviceCandidate], Error>?
    @ObservationIgnored private var discoveryGeneration: UUID?
    @ObservationIgnored private var refreshContext: (id: UUID, task: Task<TVState, Never>)?
    @ObservationIgnored private var pollingTimer: DispatchSourceTimer?
    @ObservationIgnored private var postCommandRefreshWorkItem: DispatchWorkItem?
    @ObservationIgnored private var controlCancellations: [UUID: () -> Void] = [:]
    @ObservationIgnored private var sceneActivity: AppSceneActivity = .active

    public init(
        store: any AppStoring = AppStore(),
        keychain: any TokenStoring = KeychainStore(),
        discovery: any DeviceDiscovering = DiscoveryService(),
        clientFactory: @escaping SmartCastClientFactory = RemoteController.productionClientFactory,
        catalog: any AppCataloging = AppCatalog(),
        parser: (any RequestParsing)? = nil,
        wakeSender: any WakeOnLANSending = WakeOnLANService(),
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        sleep: @escaping @Sendable (Duration) async -> Void = {
            try? await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.store = store
        self.keychain = keychain
        self.discovery = discovery
        self.clientFactory = clientFactory
        self.catalog = catalog
        self.parser = parser ?? RequestParser(catalog: catalog)
        self.wakeSender = wakeSender
        self.monotonicNow = monotonicNow
        self.sleep = sleep
    }

    public func initialize() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await store.load()
            settings = snapshot.settings
            commands = snapshot.commands
            guard let device = snapshot.device else {
                try await keychain.deleteAll()
                pairedDevice = nil
                tvState = TVState()
                return
            }
            guard let token = try await keychain.read(account: device.deviceID) else {
                try await store.setDevice(nil)
                pairedDevice = nil
                tvState = TVState()
                errorBanner = VizioControlError.pairingCredentialsUnavailable.localizedDescription
                return
            }
            try configure(device: device, token: token)
            _ = await refreshTVState()
            startPolling()
        } catch {
            publish(error)
        }
    }

    public func discover() async {
        guard !isDiscovering else { return }
        let generation = UUID()
        discoveryGeneration = generation
        candidates = []
        errorBanner = nil
        isDiscovering = true
        discoveryProgress = .waitingForPermission
        let cached = pairedDevice
        let manualAddress = settings.manualAddress
        let manualMAC = settings.manualMACAddress
        let task = Task { [discovery] in
            try await discovery.discover(
                cached: cached,
                manualEndpoint: manualAddress,
                manualMAC: manualMAC,
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        guard self?.discoveryGeneration == generation else { return }
                        self?.discoveryProgress = progress
                    }
                }
            )
        }
        discoveryTask = task
        do {
            let discovered = try await task.value
            guard discoveryGeneration == generation else { return }
            candidates = discovered
            if discovered.isEmpty {
                errorBanner = Self.noTVsFoundMessage
            }
            discoveryProgress = .idle
            isDiscovering = false
            discoveryTask = nil
            discoveryGeneration = nil
        } catch is CancellationError {
            guard discoveryGeneration == generation else { return }
            discoveryProgress = .idle
            isDiscovering = false
            discoveryTask = nil
            discoveryGeneration = nil
        } catch {
            guard discoveryGeneration == generation else { return }
            discoveryProgress = error as? VizioControlError == .localNetworkDenied ? .denied : .idle
            isDiscovering = false
            discoveryTask = nil
            discoveryGeneration = nil
            publish(error)
        }
    }

    public func cancelDiscovery() {
        discoveryGeneration = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        discovery.cancel()
        isDiscovering = false
        discoveryProgress = .idle
        candidates = []
    }

    public func cancelPairing() {
        pairingClient = nil
        pairing = nil
        isPairing = false
    }

    public func pairStart(_ candidate: DeviceCandidate) async throws {
        try await performUserOperation {
            guard let expectedFingerprint = candidate.fingerprint.flatMap(normalizeCertificateFingerprint) else {
                throw VizioControlError.message("TV must be verified again before pairing.")
            }
            self.isPairing = true
            defer { if self.pairing == nil { self.isPairing = false } }

            let firstContact = self.clientFactory(candidate.endpoint, .firstContact, nil, nil)
            let response = try await firstContact.getDeviceInfo(timeout: .seconds(2.5))
            guard normalizeCertificateFingerprint(response.leafFingerprint) == expectedFingerprint else {
                throw VizioControlError.fingerprintChanged
            }
            let info = parseDeviceInfo(response.body)
            if let expectedSerial = candidate.serial,
               let actualSerial = info.serial,
               expectedSerial != actualSerial {
                throw VizioControlError.message("The TV selected for pairing changed identity. Run Find TVs again.")
            }

            let deviceID = try secureDeviceID()
            var verified = candidate
            verified.name = nonemptyValue(info.name) ?? candidate.name
            verified.model = nonemptyValue(info.model) ?? candidate.model
            verified.serial = nonemptyValue(info.serial) ?? candidate.serial
            verified.fingerprint = expectedFingerprint
            let pinned = self.clientFactory(verified.endpoint, .pinned(expectedFingerprint), nil, nil)
            let requestToken = try await pinned.startPairing(deviceID: deviceID)
            self.pairingClient = pinned
            self.pairing = PairingStart(requestToken: requestToken, deviceID: deviceID, candidate: verified)
        }
    }

    @discardableResult
    public func pairFinish(pin: String) async throws -> PairedDevice {
        try await performUserOperation {
            guard let pairing = self.pairing, let pairingClient = self.pairingClient else {
                throw VizioControlError.message("Start a new pairing session first.")
            }
            guard pin.count == 4, pin.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
                throw VizioControlError.message("Enter the four-digit PIN shown on TV.")
            }
            let token = try await pairingClient.finishPairing(
                deviceID: pairing.deviceID,
                requestToken: pairing.requestToken,
                pin: pin
            )
            let candidate = pairing.candidate
            let device = PairedDevice(
                id: candidate.id,
                name: nonemptyValue(candidate.name) ?? "Vizio TV",
                endpoint: candidate.endpoint,
                model: candidate.model,
                serial: candidate.serial,
                fingerprint: candidate.fingerprint,
                macAddress: normalizeMACAddress(candidate.macAddress),
                deviceID: pairing.deviceID,
                pairedAt: Date()
            )
            try await self.keychain.save(token, account: device.deviceID)
            do {
                try await self.store.setDevice(device)
            } catch {
                try? await self.keychain.delete(account: device.deviceID)
                throw error
            }
            try self.configure(device: device, token: token)
            let state = await self.client?.getState() ?? TVState()
            self.tvState = state
            self.pairing = nil
            self.pairingClient = nil
            self.isPairing = false
            self.successStatus = "Paired with \(device.name)."
            self.startPolling()
            return device
        }
    }

    public func forgetDevice() async throws {
        try await performUserOperation {
            self.cancelDiscovery()
            self.stopOperationalTasks()
            if let device = self.pairedDevice {
                try await self.keychain.delete(account: device.deviceID)
            }
            try await self.store.setDevice(nil)
            self.client = nil
            self.pairingClient = nil
            self.pairing = nil
            self.pairedDevice = nil
            self.tvState = TVState()
            self.successStatus = "TV pairing erased. Saved local commands were kept."
        }
    }

    @discardableResult
    public func refreshTVState() async -> TVState {
        if let refreshContext { return await refreshContext.task.value }
        let id = UUID()
        let task = Task { @MainActor in await self.refreshOnce() }
        refreshContext = (id, task)
        let state = await task.value
        if refreshContext?.id == id { refreshContext = nil }
        tvState = state
        return state
    }

    @discardableResult
    public func press(_ key: TVKey, count: Int = 1) async throws -> TVState {
        try await performUserOperation {
            try await self.pressUntracked(key, count: count)
        }
    }

    @discardableResult
    public func setVolume(_ value: Double) async throws -> TVState {
        try await performUserOperation {
            guard let client = self.client else { throw VizioControlError.missingPairingToken }
            let state = try await self.connectedControlState()
            guard state.power != false else {
                throw VizioControlError.message("TV is off. Turn it on before changing volume.")
            }
            let sent = try await client.setVolume(value)
            self.tvState = TVState(
                connected: state.connected,
                power: state.power,
                volume: sent,
                muted: false,
                currentApp: state.currentApp,
                endpoint: state.endpoint,
                error: nil
            )
            self.scheduleRefresh(after: .milliseconds(250))
            return self.tvState
        }
    }

    public func sendText(_ value: String) async throws {
        try await performUserOperation {
            guard let client = self.client else { throw VizioControlError.missingPairingToken }
            let state = try await self.connectedControlState()
            guard state.power != false else {
                throw VizioControlError.message("TV is off. Turn it on before entering text.")
            }
            try await client.typeText(value)
            self.successStatus = "Text sent to TV."
        }
    }

    public func launchApp(_ name: String) async throws {
        try await performUserOperation {
            guard let client = self.client else { throw VizioControlError.missingPairingToken }
            let state = try await self.connectedControlState()
            guard state.power != false else {
                throw VizioControlError.message("TV is off. Turn it on before opening an app.")
            }
            let app = try self.catalog.resolve(name)
            try await client.launchApp(app)
            self.tvState.currentApp = app.name
            self.successStatus = "Opened \(app.name)."
            self.scheduleRefresh(after: .milliseconds(1_200))
        }
    }

    @discardableResult
    public func runLocalRequest(_ request: String) async throws -> SavedCommand {
        try await performUserOperation {
            _ = try self.requireDevice()
            let parsed = try self.parser.parse(request)
            try await self.runActions(parsed.actions)
            let now = Date()
            let newCommand = SavedCommand(
                label: parsed.label,
                systemImage: parsed.systemImage,
                normalizedRequest: parsed.normalizedRequest,
                order: self.commands.count,
                usageCount: 1,
                createdAt: now,
                updatedAt: now,
                actions: parsed.actions
            )
            self.commands = try await self.store.upsertCommand(newCommand)
            let saved = self.commands.first { $0.normalizedRequest == parsed.normalizedRequest }!
            self.successStatus = "\(saved.label) completed and saved."
            return saved
        }
    }

    @discardableResult
    public func runSavedCommand(id: UUID) async throws -> SavedCommand {
        try await performUserOperation {
            guard let command = self.commands.first(where: { $0.id == id }) else {
                throw VizioControlError.message("Saved command not found.")
            }
            try await self.runActions(command.actions)
            var updated = command
            updated.updatedAt = Date()
            self.commands = try await self.store.upsertCommand(updated)
            let saved = self.commands.first { $0.id == id }!
            self.successStatus = "\(saved.label) completed."
            return saved
        }
    }

    public func editCommand(id: UUID, label: String) async throws {
        try await performUserOperation {
            self.commands = try await self.store.editCommand(id: id, label: label, updatedAt: Date())
            self.successStatus = "Saved command label updated."
        }
    }

    public func duplicateCommand(id: UUID) async throws {
        try await performUserOperation {
            self.commands = try await self.store.duplicateCommand(id: id, at: Date())
            self.successStatus = "Saved command duplicated."
        }
    }

    public func deleteCommand(id: UUID) async throws {
        try await performUserOperation {
            self.commands = try await self.store.deleteCommand(id: id)
            self.successStatus = "Saved command deleted."
        }
    }

    public func undoDeleteCommand() async throws {
        try await performUserOperation {
            self.commands = try await self.store.undoDelete()
            self.successStatus = "Saved command restored."
        }
    }

    public func reorderCommand(id: UUID, direction: Int) async throws {
        try await performUserOperation {
            self.commands = try await self.store.reorderCommand(id: id, direction: direction)
            self.successStatus = "Saved command moved."
        }
    }

    public func saveManualEndpoint(_ value: String) async throws {
        try await performUserOperation {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.isEmpty ? "" : try await validateManualEndpoint(trimmed).host
            var settings = self.settings
            settings.manualAddress = normalized
            self.settings = try await self.store.updateSettings(settings)
            self.successStatus = normalized.isEmpty ? "Manual TV address cleared." : "Manual TV address saved for rediscovery."
        }
    }

    public func saveWakeMAC(_ value: String) async throws {
        try await performUserOperation {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized: String
            if trimmed.isEmpty {
                normalized = ""
            } else if let address = normalizeMACAddress(trimmed) {
                normalized = address
            } else {
                throw VizioControlError.invalidMACAddress
            }
            var settings = self.settings
            settings.manualMACAddress = normalized
            var device = self.pairedDevice
            device?.macAddress = normalized.isEmpty ? nil : normalized
            try await self.store.updateSettingsAndDevice(settings: settings, device: device)
            self.settings = settings
            self.pairedDevice = device
            self.successStatus = normalized.isEmpty ? "Wake address cleared." : "Wake address saved."
        }
    }

    public func handleScenePhase(_ activity: AppSceneActivity) async {
        let previous = sceneActivity
        sceneActivity = activity
        discovery.handleSceneActivity(activity)
        switch activity {
        case .inactive:
            stopOperationalTasks()
            if discoveryProgress != .waitingForPermission { cancelDiscovery() }
        case .background:
            cancelDiscovery()
            stopOperationalTasks()
        case .active:
            guard previous != .active else { return }
            if !(isDiscovering && discoveryProgress == .waitingForPermission), pairedDevice != nil {
                _ = await refreshTVState()
            }
            startPolling()
        }
    }

    public func dismissError() {
        errorBanner = nil
    }

    public func clearSuccessStatus() {
        successStatus = nil
    }

    private func refreshOnce() async -> TVState {
        guard let device = pairedDevice, let client else { return TVState() }
        let initial = await client.getState()
        guard !initial.connected else { return initial }
        do {
            return try await rediscoverDevice(device, fallback: initial)
        } catch {
            if error as? VizioControlError == .fingerprintChanged { publish(error) }
            return TVState(
                connected: false,
                endpoint: initial.endpoint ?? device.endpoint,
                error: error.localizedDescription
            )
        }
    }

    private func rediscoverDevice(_ device: PairedDevice, fallback: TVState) async throws -> TVState {
        let discovered = try await discovery.discover(
            cached: device,
            manualEndpoint: settings.manualAddress,
            manualMAC: settings.manualMACAddress,
            onProgress: { _ in }
        )
        guard let match = discovered.first(where: { isSameDevice(device, $0) }) else { return fallback }
        if let storedFingerprint = device.fingerprint.flatMap(normalizeCertificateFingerprint),
           let discoveredFingerprint = match.fingerprint.flatMap(normalizeCertificateFingerprint),
           storedFingerprint != discoveredFingerprint {
            throw VizioControlError.fingerprintChanged
        }
        var repaired = device
        repaired.endpoint = match.endpoint
        repaired.name = nonemptyValue(match.name) ?? device.name
        repaired.model = match.model ?? device.model
        repaired.serial = device.serial ?? match.serial
        repaired.macAddress = normalizeMACAddress(device.macAddress) ?? normalizeMACAddress(match.macAddress)
        try await store.setDevice(repaired)
        guard let token = try await keychain.read(account: repaired.deviceID) else {
            throw VizioControlError.pairingCredentialsUnavailable
        }
        try configure(device: repaired, token: token)
        return await client?.getState() ?? fallback
    }

    private func pressUntracked(_ key: TVKey, count: Int) async throws -> TVState {
        let device = try requireDevice()
        guard let client else { throw VizioControlError.missingPairingToken }
        var state = tvState.connected ? tvState : await refreshTVState()
        if (key == .powerOn || key == .powerToggle), !state.connected {
            return try await wakeDevice(device)
        }
        guard state.connected else { throw VizioControlError.offline(state.error) }
        if key == .powerOn, state.power == true { return state }
        if key == .powerOff, state.power == false { return state }
        if state.power == false, key != .powerOn, key != .powerToggle {
            throw VizioControlError.message("TV is off. Turn it on before sending controls.")
        }
        let turningOff = key == .powerOff || (key == .powerToggle && state.power != false)
        let actualKey: TVKey = turningOff ? .powerOff : (key == .powerToggle && state.power == false ? .powerOn : key)
        if turningOff {
            do {
                _ = try await client.ensureQuickStartPowerMode()
            } catch {
                throw VizioControlError.message(Self.standbyFailureMessage)
            }
        }
        do {
            try await client.pressKey(actualKey, count: count, timeout: .seconds(8))
        } catch {
            if actualKey == .powerOn { return try await wakeDevice(device) }
            scheduleRefresh(after: .zero)
            throw error
        }
        state = optimisticTVState(tvState.connected ? tvState : state, key: actualKey, count: count)
        tvState = state
        if let delay = stateRefreshDelay(for: actualKey) { scheduleRefresh(after: delay) }
        return state
    }

    private func connectedControlState() async throws -> TVState {
        let state = tvState.connected ? tvState : await refreshTVState()
        guard state.connected else { throw VizioControlError.offline(state.error) }
        return state
    }

    private func wakeDevice(_ device: PairedDevice) async throws -> TVState {
        guard let mac = normalizeMACAddress(device.macAddress) else { throw VizioControlError.missingWakeAddress }
        isWaking = true
        defer { isWaking = false }
        let cachedAddresses = device.endpoint.resolvedAddresses + [device.endpoint.host]
        try await wakeSender.wake(macAddress: mac, cachedAddresses: cachedAddresses)
        let deadline = monotonicNow().advanced(by: .seconds(30))
        var attempt = 0
        while monotonicNow() < deadline, attempt < 40 {
            await sleep(attempt == 0 ? .milliseconds(250) : .milliseconds(900))
            try Task.checkCancellation()
            guard let client else { throw VizioControlError.missingPairingToken }
            try? await client.pressKey(.powerOn, count: 1, timeout: .seconds(1.2))
            await sleep(.milliseconds(200))
            try Task.checkCancellation()
            tvState = await client.getState()
            if tvState.connected, tvState.power == true { return tvState }
            attempt += 1
            if attempt == 5 || attempt == 12 {
                tvState = try await rediscoverDevice(device, fallback: tvState)
                if tvState.connected, tvState.power == true { return tvState }
            }
        }
        tvState.connected = false
        tvState.error = Self.wakeTimeoutMessage
        throw VizioControlError.message(Self.wakeTimeoutMessage)
    }

    private func runActions(_ actions: [TVAction]) async throws {
        for action in actions {
            switch action {
            case let .key(key, count): _ = try await pressUntracked(key, count: count)
            case let .setVolume(value): _ = try await setVolume(Double(value))
            case let .launchApp(name): try await launchApp(name)
            }
        }
    }

    private func requireDevice() throws -> PairedDevice {
        guard let pairedDevice else { throw VizioControlError.missingPairingToken }
        return pairedDevice
    }

    private func configure(device: PairedDevice, token: String) throws {
        guard let fingerprint = device.fingerprint.flatMap(normalizeCertificateFingerprint) else {
            throw VizioControlError.pairingCredentialsUnavailable
        }
        client = clientFactory(device.endpoint, .pinned(fingerprint), token, device.serial)
        pairedDevice = device
        tvState = TVState(endpoint: device.endpoint)
    }

    private func scheduleRefresh(after delay: Duration) {
        postCommandRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.postCommandRefreshWorkItem = nil
                _ = await self.refreshTVState()
            }
        }
        postCommandRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + durationSeconds(delay),
            execute: workItem
        )
    }

    private func startPolling() {
        pollingTimer?.cancel()
        pollingTimer = nil
        guard sceneActivity == .active, pairedDevice != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sceneActivity == .active else { return }
                _ = await self.refreshTVState()
            }
        }
        pollingTimer = timer
        timer.resume()
    }

    private func stopOperationalTasks() {
        pollingTimer?.cancel()
        pollingTimer = nil
        postCommandRefreshWorkItem?.cancel()
        postCommandRefreshWorkItem = nil
        refreshContext?.task.cancel()
        refreshContext = nil
        let cancellations = controlCancellations.values
        controlCancellations = [:]
        cancellations.forEach { $0() }
    }

    private func performUserOperation<Value: Sendable>(
        _ operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        let task: Task<Value, any Error>
        if #available(iOS 26, macOS 26, *) {
            task = Task.immediate { @MainActor in try await operation() }
        } else {
            task = Task { @MainActor in try await operation() }
        }
        controlCancellations[id] = { task.cancel() }
        defer { controlCancellations[id] = nil }
        do {
            return try await task.value
        } catch {
            publish(error)
            throw error
        }
    }

    private func publish(_ error: Error) {
        guard !(error is CancellationError) else { return }
        errorBanner = error.localizedDescription
    }

    nonisolated public static func productionClientFactory(
        endpoint: DeviceEndpoint,
        trustMode: SmartCastTrustMode,
        token: String?,
        expectedSerial: String?
    ) -> any SmartCastControlling {
        SmartCastClient(
            endpoint: endpoint,
            transport: URLSessionSmartCastTransport(endpoint: endpoint, trustMode: trustMode),
            token: token,
            expectedSerial: expectedSerial
        )
    }
}

public func optimisticTVState(_ state: TVState, key: TVKey, count: Int = 1) -> TVState {
    var state = state
    let presses = min(10, max(1, count))
    switch key {
    case .powerOff:
        state.power = false
        state.volume = nil
        state.muted = nil
        state.currentApp = nil
    case .powerOn:
        state.power = true
    case .mute:
        if let muted = state.muted { state.muted = !muted }
    case .volumeUp:
        if let volume = state.volume {
            state.volume = min(100, volume + presses)
            state.muted = false
        }
    case .volumeDown:
        if let volume = state.volume {
            state.volume = max(0, volume - presses)
            state.muted = false
        }
    default:
        break
    }
    return state
}

public func stateRefreshDelay(for key: TVKey) -> Duration? {
    if key.isPower { return .seconds(1) }
    if key == .volumeUp || key == .volumeDown || key == .mute { return .milliseconds(250) }
    if key == .home || key == .input { return .milliseconds(700) }
    return nil
}

private func durationSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return max(0, Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000)
}

private func secureDeviceID() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw VizioControlError.message("A secure pairing identity could not be generated.")
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

private func nonemptyValue(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
}
