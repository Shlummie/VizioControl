import Darwin
import Foundation
import dnssd

public struct BonjourServiceDescriptor: Hashable, Sendable {
    public var name: String
    public var type: String
    public var domain: String
    public var interfaceIndex: UInt32

    public init(name: String, type: String, domain: String, interfaceIndex: UInt32) {
        self.name = name
        self.type = type
        self.domain = domain
        self.interfaceIndex = interfaceIndex
    }
}

public struct ResolvedBonjourService: Equatable, Sendable {
    public var endpoint: DeviceEndpoint
    public var txt: [String: String]

    public init(endpoint: DeviceEndpoint, txt: [String: String]) {
        self.endpoint = endpoint
        self.txt = txt
    }
}

public protocol BonjourResolving: Sendable {
    func resolve(_ service: BonjourServiceDescriptor, timeout: Duration) async throws -> ResolvedBonjourService
}

public final class BonjourResolver: BonjourResolving, @unchecked Sendable {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "com.shlummie.viziocontrol.bonjour-resolver")) {
        self.queue = queue
    }

    public func resolve(
        _ service: BonjourServiceDescriptor,
        timeout: Duration = .seconds(2.5)
    ) async throws -> ResolvedBonjourService {
        let operation = BonjourResolveOperation(service: service, queue: queue, timeout: timeout)
        return try await operation.run()
    }
}

private final class BonjourResolveOperation: @unchecked Sendable {
    private let service: BonjourServiceDescriptor
    private let queue: DispatchQueue
    private let timeout: Duration
    private var continuation: CheckedContinuation<ResolvedBonjourService, Error>?
    private var resolveRef: DNSServiceRef?
    private var addressRef: DNSServiceRef?
    private var timeoutTimer: DispatchSourceTimer?
    private var targetHost = ""
    private var txt: [String: String] = [:]
    private var addresses: Set<String> = []
    private var settled = false

    init(service: BonjourServiceDescriptor, queue: DispatchQueue, timeout: Duration) {
        self.service = service
        self.queue = queue
        self.timeout = timeout
    }

    func run() async throws -> ResolvedBonjourService {
        let reference = ResolverReference(value: self)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    reference.value.start(continuation)
                }
            }
        } onCancel: {
            reference.value.queue.async {
                reference.value.finish(.failure(CancellationError()))
            }
        }
    }

    private func start(_ continuation: CheckedContinuation<ResolvedBonjourService, Error>) {
        guard !settled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + dispatchInterval(timeout))
        let reference = ResolverReference(value: self)
        timer.setEventHandler {
            reference.value.finish(.failure(VizioControlError.message("TV service resolution timed out.")))
        }
        timeoutTimer = timer
        timer.resume()

        var referenceValue: DNSServiceRef?
        let error = DNSServiceResolve(
            &referenceValue,
            0,
            service.interfaceIndex,
            service.name,
            service.type,
            service.domain,
            bonjourResolveReply,
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard error == kDNSServiceErr_NoError, let referenceValue else {
            finish(.failure(VizioControlError.message("TV service could not be resolved.")))
            return
        }
        resolveRef = referenceValue
        let queueError = DNSServiceSetDispatchQueue(referenceValue, queue)
        if queueError != kDNSServiceErr_NoError {
            finish(.failure(VizioControlError.message("TV service could not be resolved.")))
        }
    }

    fileprivate func didResolve(
        interfaceIndex: UInt32,
        errorCode: DNSServiceErrorType,
        hostTarget: UnsafePointer<CChar>?,
        txtLength: UInt16,
        txtRecord: UnsafePointer<UInt8>?
    ) {
        guard !settled else { return }
        guard errorCode == kDNSServiceErr_NoError, let hostTarget else {
            finish(.failure(VizioControlError.message("TV service could not be resolved.")))
            return
        }

        targetHost = String(cString: hostTarget).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        txt = parseTXTRecord(length: Int(txtLength), bytes: txtRecord)
        if let resolveRef {
            DNSServiceRefDeallocate(resolveRef)
            self.resolveRef = nil
        }

        var referenceValue: DNSServiceRef?
        let protocols = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
        let error = DNSServiceGetAddrInfo(
            &referenceValue,
            0,
            interfaceIndex,
            protocols,
            targetHost,
            bonjourAddressReply,
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard error == kDNSServiceErr_NoError, let referenceValue else {
            finish(.failure(VizioControlError.message("TV service address could not be resolved.")))
            return
        }
        addressRef = referenceValue
        let queueError = DNSServiceSetDispatchQueue(referenceValue, queue)
        if queueError != kDNSServiceErr_NoError {
            finish(.failure(VizioControlError.message("TV service address could not be resolved.")))
        }
    }

    fileprivate func didReceiveAddress(
        flags: DNSServiceFlags,
        interfaceIndex: UInt32,
        errorCode: DNSServiceErrorType,
        address: UnsafePointer<sockaddr>?
    ) {
        guard !settled else { return }
        if errorCode == kDNSServiceErr_NoError, let address, let value = numericAddress(address) {
            addresses.insert(value)
        }
        let moreComing = (flags & DNSServiceFlags(kDNSServiceFlagsMoreComing)) != 0
        guard !moreComing else { return }
        guard errorCode == kDNSServiceErr_NoError, !targetHost.isEmpty, !addresses.isEmpty else {
            finish(.failure(VizioControlError.message("TV service address could not be resolved.")))
            return
        }
        finish(.success(ResolvedBonjourService(
            endpoint: DeviceEndpoint(
                host: targetHost,
                resolvedAddresses: Array(addresses),
                interfaceIndex: interfaceIndex
            ),
            txt: txt
        )))
    }

    private func finish(_ result: Result<ResolvedBonjourService, Error>) {
        guard !settled else { return }
        settled = true
        timeoutTimer?.cancel()
        timeoutTimer = nil
        if let resolveRef {
            DNSServiceRefDeallocate(resolveRef)
            self.resolveRef = nil
        }
        if let addressRef {
            DNSServiceRefDeallocate(addressRef)
            self.addressRef = nil
        }
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

private let bonjourResolveReply: DNSServiceResolveReply = {
    _, _, interfaceIndex, errorCode, _, hostTarget, _, txtLength, txtRecord, context in
    guard let context else { return }
    Unmanaged<BonjourResolveOperation>.fromOpaque(context).takeUnretainedValue().didResolve(
        interfaceIndex: interfaceIndex,
        errorCode: errorCode,
        hostTarget: hostTarget,
        txtLength: txtLength,
        txtRecord: txtRecord
    )
}

private let bonjourAddressReply: DNSServiceGetAddrInfoReply = {
    _, flags, interfaceIndex, errorCode, _, address, _, context in
    guard let context else { return }
    Unmanaged<BonjourResolveOperation>.fromOpaque(context).takeUnretainedValue().didReceiveAddress(
        flags: flags,
        interfaceIndex: interfaceIndex,
        errorCode: errorCode,
        address: address
    )
}

private func parseTXTRecord(length: Int, bytes: UnsafePointer<UInt8>?) -> [String: String] {
    guard length > 0, let bytes else { return [:] }
    let data = Array(UnsafeBufferPointer(start: bytes, count: length))
    var result: [String: String] = [:]
    var offset = 0
    while offset < data.count {
        let itemLength = Int(data[offset])
        offset += 1
        guard itemLength > 0, offset + itemLength <= data.count else { break }
        let item = Data(data[offset..<(offset + itemLength)])
        offset += itemLength
        guard let text = String(data: item, encoding: .utf8) else { continue }
        let parts = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(parts[0])
        guard !key.isEmpty else { continue }
        result[key] = parts.count > 1 ? String(parts[1]) : ""
    }
    return result
}

private func numericAddress(_ address: UnsafePointer<sockaddr>) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let length = socklen_t(address.pointee.sa_len)
    let status = getnameinfo(
        address,
        length,
        &buffer,
        socklen_t(buffer.count),
        nil,
        0,
        NI_NUMERICHOST
    )
    guard status == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
    let components = duration.components
    let seconds = max(0, components.seconds)
    let fromSeconds = seconds > Int64(Int.max / 1_000_000_000)
        ? Int.max
        : Int(seconds) * 1_000_000_000
    let fromAttoseconds = max(0, Int(components.attoseconds / 1_000_000_000))
    return .nanoseconds(fromSeconds > Int.max - fromAttoseconds ? Int.max : fromSeconds + fromAttoseconds)
}

private struct ResolverReference<Value>: @unchecked Sendable {
    let value: Value
}
