import CryptoKit
import Foundation
import Security

public enum SCPLMethod: String, Sendable {
    case get = "GET"
    case put = "PUT"
}

public struct SCPLRequest: Sendable {
    public var path: String
    public var method: SCPLMethod
    public var body: JSONValue?
    public var authenticated: Bool
    public var timeout: Duration

    public init(
        path: String,
        method: SCPLMethod,
        body: JSONValue? = nil,
        authenticated: Bool = true,
        timeout: Duration = .seconds(8)
    ) {
        self.path = path
        self.method = method
        self.body = body
        self.authenticated = authenticated
        self.timeout = timeout
    }
}

public struct SCPLResponse: Equatable, Sendable {
    public var statusCode: Int
    public var body: JSONValue
    public var leafFingerprint: String

    public init(statusCode: Int, body: JSONValue, leafFingerprint: String = "") {
        self.statusCode = statusCode
        self.body = body
        self.leafFingerprint = leafFingerprint
    }
}

public protocol SmartCastTransport: Sendable {
    func send(_ request: SCPLRequest, token: String?) async throws -> SCPLResponse
}

public enum SmartCastTrustMode: Equatable, Sendable {
    case firstContact
    case pinned(String)
}

public func normalizeCertificateFingerprint(_ value: String) -> String? {
    let compact = value.uppercased().filter(\.isHexDigit)
    guard compact.count == 64 else { return nil }
    return stride(from: 0, to: compact.count, by: 2)
        .map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: 2)
            return String(compact[start..<end])
        }
        .joined(separator: ":")
}

enum TrustChallengeDecision: Equatable {
    case performDefaultHandling
    case accept
    case rejectHost
    case rejectFingerprint
}

struct SmartCastTrustPolicy: Sendable {
    let endpointHost: String
    let mode: SmartCastTrustMode

    func decision(authenticationMethod: String, challengeHost: String, fingerprint: String?) -> TrustChallengeDecision {
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return .performDefaultHandling
        }
        guard canonicalTrustHost(challengeHost) == canonicalTrustHost(endpointHost) else {
            return .rejectHost
        }
        guard let fingerprint = fingerprint.flatMap(normalizeCertificateFingerprint) else {
            return .rejectFingerprint
        }
        switch mode {
        case .firstContact:
            return .accept
        case let .pinned(expected):
            return normalizeCertificateFingerprint(expected) == fingerprint ? .accept : .rejectFingerprint
        }
    }
}

public final class URLSessionSmartCastTransport: SmartCastTransport, @unchecked Sendable {
    public typealias ConfigurationFactory = @Sendable () -> URLSessionConfiguration
    public typealias DeadlineSleep = @Sendable (Duration) async -> Void

    private let endpoint: DeviceEndpoint
    private let delegate: SmartCastTrustDelegate
    private let session: URLSession
    private let deadlineSleep: DeadlineSleep?

    public init(
        endpoint: DeviceEndpoint,
        trustMode: SmartCastTrustMode,
        configurationFactory: @escaping ConfigurationFactory = { .ephemeral },
        deadlineSleep: DeadlineSleep? = nil
    ) {
        self.endpoint = endpoint
        self.deadlineSleep = deadlineSleep
        let connectionHost = smartCastConnectionHost(endpoint)
        delegate = SmartCastTrustDelegate(policy: SmartCastTrustPolicy(endpointHost: connectionHost, mode: trustMode))

        let configuration = configurationFactory()
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }


    public func send(_ request: SCPLRequest, token: String?) async throws -> SCPLResponse {
        guard let url = smartCastURL(endpoint: endpoint, path: request.path) else {
            throw VizioControlError.message("TV address is invalid.")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        if let body = request.body {
            let data = try JSONEncoder().encode(body)
            urlRequest.httpBody = data
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        }
        if request.authenticated, let token {
            urlRequest.setValue(token, forHTTPHeaderField: "AUTH")
        }
        let preparedRequest = urlRequest

        let operation = URLSessionDeadlineOperation()
        let result: HTTPResult
        do {
            result = try await operation.run(
                session: session,
                request: preparedRequest,
                timeout: request.timeout,
                sleep: deadlineSleep
            )
        } catch {
            if let trustFailure = delegate.trustFailure {
                throw trustFailure
            }
            if error is CancellationError, Task.isCancelled {
                throw CancellationError()
            }
            if let urlError = error as? URLError, urlError.code == .timedOut {
                throw VizioControlError.message("TV did not respond in time.")
            }
            throw error
        }

        let body: JSONValue
        if result.data.isEmpty {
            body = .object([:])
        } else {
            do {
                body = try JSONDecoder().decode(JSONValue.self, from: result.data)
            } catch {
                throw VizioControlError.message("TV returned an unreadable response.")
            }
        }
        return SCPLResponse(
            statusCode: result.statusCode,
            body: body,
            leafFingerprint: delegate.leafFingerprint ?? ""
        )
    }
}

private struct HTTPResult: Sendable {
    let statusCode: Int
    let data: Data
}

private final class URLSessionDeadlineOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPResult, Error>?
    private var dataTask: URLSessionDataTask?
    private var deadlineTask: Task<Void, Never>?
    private var deadlineTimer: DispatchSourceTimer?
    private var settled = false
    private var cancellationRequested = false

    func run(
        session: URLSession,
        request: URLRequest,
        timeout: Duration,
        sleep: URLSessionSmartCastTransport.DeadlineSleep?
    ) async throws -> HTTPResult {
        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let reference = UnsafeSendableReference(value: self)
                    let task = session.dataTask(with: request) { data, response, error in
                        reference.value.networkCompleted(data: data, response: response, error: error)
                    }

                    let cancelledBeforeStart = lock.withLock {
                        self.continuation = continuation
                        dataTask = task
                        if cancellationRequested {
                            settled = true
                            self.continuation = nil
                            dataTask = nil
                            return true
                        }
                        return false
                    }
                    if cancelledBeforeStart {
                        task.cancel()
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    if let sleep {
                        let deadline = Task.detached {
                            await reference.value.waitForDeadline(timeout: timeout, sleep: sleep)
                        }
                        let completedBeforeDeadlineStarted = lock.withLock {
                            if settled { return true }
                            deadlineTask = deadline
                            return false
                        }
                        if completedBeforeDeadlineStarted {
                            deadline.cancel()
                            return
                        }
                    } else {
                        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
                        timer.schedule(deadline: .now() + dispatchDeadlineInterval(timeout))
                        timer.setEventHandler {
                            reference.value.deadlineReached()
                        }
                        timer.resume()
                        let completedBeforeDeadlineStarted = lock.withLock {
                            if settled { return true }
                            deadlineTimer = timer
                            return false
                        }
                        if completedBeforeDeadlineStarted {
                            timer.cancel()
                            return
                        }
                    }
                    task.resume()
                }
            } onCancel: {
                self.cancel()
            }
            await finishDeadlineWork()
            return result
        } catch {
            await finishDeadlineWork()
            throw error
        }
    }

    private func networkCompleted(data: Data?, response: URLResponse?, error: Error?) {
        let completion = lock.withLock {
            () -> (CheckedContinuation<HTTPResult, Error>, Task<Void, Never>?, DispatchSourceTimer?)? in
            guard !settled, let continuation else { return nil }
            settled = true
            self.continuation = nil
            dataTask = nil
            let deadline = deadlineTask
            let timer = deadlineTimer
            deadlineTimer = nil
            return (continuation, deadline, timer)
        }
        guard let (continuation, deadline, timer) = completion else { return }
        deadline?.cancel()
        timer?.cancel()
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let data, let http = response as? HTTPURLResponse else {
            continuation.resume(throwing: VizioControlError.message("TV returned an unreadable response."))
            return
        }
        continuation.resume(returning: HTTPResult(statusCode: http.statusCode, data: data))
    }

    private func waitForDeadline(
        timeout: Duration,
        sleep: @escaping URLSessionSmartCastTransport.DeadlineSleep
    ) async {
        await sleep(timeout)
        guard !Task.isCancelled else { return }
        deadlineReached()
    }

    private func deadlineReached() {
        settleFromDeadline(error: VizioControlError.message("TV did not respond in time."))
    }

    private func settleFromDeadline(error: Error) {
        let completion = lock.withLock {
            () -> (CheckedContinuation<HTTPResult, Error>, URLSessionDataTask?, DispatchSourceTimer?)? in
            guard !settled, let continuation else { return nil }
            settled = true
            self.continuation = nil
            let task = dataTask
            dataTask = nil
            let timer = deadlineTimer
            deadlineTimer = nil
            return (continuation, task, timer)
        }
        guard let (continuation, task, timer) = completion else { return }
        timer?.cancel()
        task?.cancel()
        continuation.resume(throwing: error)
    }

    private func cancel() {
        let completion = lock.withLock {
            () -> (CheckedContinuation<HTTPResult, Error>, URLSessionDataTask?, Task<Void, Never>?, DispatchSourceTimer?)? in
            cancellationRequested = true
            guard !settled, let continuation else { return nil }
            settled = true
            self.continuation = nil
            let task = dataTask
            dataTask = nil
            let deadline = deadlineTask
            let timer = deadlineTimer
            deadlineTimer = nil
            return (continuation, task, deadline, timer)
        }
        guard let (continuation, task, deadline, timer) = completion else { return }
        task?.cancel()
        deadline?.cancel()
        timer?.cancel()
        continuation.resume(throwing: CancellationError())
    }

    private func finishDeadlineWork() async {
        let state = lock.withLock { (deadlineTask, deadlineTimer) }
        state.1?.cancel()
        await state.0?.value
        lock.withLock {
            deadlineTask = nil
            deadlineTimer = nil
        }
    }
}

private func dispatchDeadlineInterval(_ duration: Duration) -> DispatchTimeInterval {
    let components = duration.components
    let seconds = max(0, components.seconds)
    let nanosecondsFromSeconds = seconds > Int64(Int.max / 1_000_000_000)
        ? Int.max
        : Int(seconds) * 1_000_000_000
    let nanosecondsFromAttoseconds = max(0, Int(components.attoseconds / 1_000_000_000))
    let total = nanosecondsFromSeconds > Int.max - nanosecondsFromAttoseconds
        ? Int.max
        : nanosecondsFromSeconds + nanosecondsFromAttoseconds
    return .nanoseconds(total)
}

private struct UnsafeSendableReference<Value>: @unchecked Sendable {
    let value: Value
}

private final class SmartCastTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let policy: SmartCastTrustPolicy
    private let lock = NSLock()
    private var storedFingerprint: String?
    private var storedFailure: VizioControlError?

    init(policy: SmartCastTrustPolicy) {
        self.policy = policy
    }

    var leafFingerprint: String? {
        lock.withLock { storedFingerprint }
    }

    var trustFailure: VizioControlError? {
        lock.withLock { storedFailure }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let serverTrust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let certificate = certificates.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let data = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: data)
        let fingerprint = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
        let decision = policy.decision(
            authenticationMethod: method,
            challengeHost: challenge.protectionSpace.host,
            fingerprint: fingerprint
        )

        switch decision {
        case .performDefaultHandling:
            completionHandler(.performDefaultHandling, nil)
        case .accept:
            lock.withLock { storedFingerprint = fingerprint }
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        case .rejectHost:
            lock.withLock {
                storedFailure = .message("TV certificate challenge did not match the requested endpoint.")
            }
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .rejectFingerprint:
            lock.withLock { storedFailure = .fingerprintChanged }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

func smartCastConnectionHost(_ endpoint: DeviceEndpoint) -> String {
    let endpointHost = unwrappedNetworkHost(endpoint.host)
    if isIPv4Address(endpointHost) || isIPv6ConnectionAddress(endpointHost) {
        return scopedConnectionAddress(endpointHost, interfaceIndex: endpoint.interfaceIndex)
    }

    let localAddresses = endpoint.resolvedAddresses
        .map(unwrappedNetworkHost)
        .filter(isLocalAddress)
    if let ipv4 = localAddresses.first(where: isIPv4Address) {
        return ipv4
    }
    if let ipv6 = localAddresses.first(where: isIPv6ConnectionAddress) {
        return scopedConnectionAddress(ipv6, interfaceIndex: endpoint.interfaceIndex)
    }
    return endpointHost
}

private func unwrappedNetworkHost(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return trimmed }
    return String(trimmed.dropFirst().dropLast())
}

private func isIPv6ConnectionAddress(_ value: String) -> Bool {
    let address = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? value
    return isIPv6Address(address)
}

private func scopedConnectionAddress(_ value: String, interfaceIndex: UInt32?) -> String {
    guard !value.contains("%"),
          let firstHextet = value.split(separator: ":", maxSplits: 1).first,
          let firstValue = UInt16(firstHextet, radix: 16),
          firstValue & 0xFFC0 == 0xFE80,
          let interfaceIndex,
          interfaceIndex != 0 else {
        return value
    }
    return "\(value)%\(interfaceIndex)"
}

func smartCastURL(endpoint: DeviceEndpoint, path: String) -> URL? {
    let rawHost = smartCastConnectionHost(endpoint)
    guard !rawHost.isEmpty else { return nil }
    let escapedHost = rawHost.replacingOccurrences(of: "%", with: "%25")
    let authority = escapedHost.contains(":") ? "[\(escapedHost)]" : escapedHost
    let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
    return URL(string: "https://\(authority):7345\(normalizedPath)")
}

private func canonicalTrustHost(_ value: String) -> String {
    value.trimmingCharacters(in: CharacterSet(charactersIn: "[]." )).lowercased()
}
