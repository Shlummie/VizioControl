import Foundation
import XCTest
@testable import VizioControl

final class SmartCastTransportTests: XCTestCase, @unchecked Sendable {
    func testHardDeadlineCancelsHangingDataTaskForEveryRequestTimeout() async throws {
        for timeout in [Duration.seconds(1.2), .seconds(2.5), .seconds(8)] {
            hangingProtocolProbe.reset()
            let durationProbe = DurationProbe()
            let transport = URLSessionSmartCastTransport(
                endpoint: DeviceEndpoint(host: "192.168.50.42"),
                trustMode: .firstContact,
                configurationFactory: {
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.protocolClasses = [HangingURLProtocol.self]
                    return configuration
                },
                deadlineSleep: { duration in
                    await hangingProtocolProbe.waitUntilStarted()
                    await durationProbe.record(duration)
                }
            )

            do {
                _ = try await transport.send(SCPLRequest(
                    path: "/state/device/deviceinfo",
                    method: .get,
                    authenticated: false,
                    timeout: timeout
                ), token: nil)
                XCTFail("Expected hard deadline")
            } catch {
                XCTAssertEqual(error.localizedDescription, "TV did not respond in time.")
            }
            await hangingProtocolProbe.waitUntilStopped()
            let observed = await durationProbe.value
            XCTAssertEqual(observed, timeout)
        }
    }

    func testProductionRequestHeadersBodyAndURL() async throws {
        await captureProtocolProbe.reset()
        let transport = URLSessionSmartCastTransport(
            endpoint: DeviceEndpoint(host: "192.168.50.42"),
            trustMode: .firstContact,
            configurationFactory: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [CapturingURLProtocol.self]
                return configuration
            }
        )

        _ = try await transport.send(SCPLRequest(
            path: "/key_command/",
            method: .put,
            body: ["KEYLIST": [["CODESET": 3, "CODE": 2, "ACTION": "KEYPRESS"]]],
            timeout: .seconds(8)
        ), token: "secret")

        let request = await captureProtocolProbe.waitForRequest()
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "192.168.50.42")
        XCTAssertEqual(request.url?.port, 7345)
        XCTAssertEqual(request.url?.absoluteString, "https://192.168.50.42:7345/key_command/")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "AUTH"), "secret")
        XCTAssertNotNil(request.httpBody ?? request.httpBodyStream.map { _ in Data() })
    }

    func testOptimizedStatusRequestPreservesWireAndResponseContracts() async throws {
        await captureProtocolProbe.reset()
        let transport = URLSessionSmartCastTransport(
            endpoint: DeviceEndpoint(host: "192.168.50.42"),
            trustMode: .firstContact,
            configurationFactory: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [CapturingURLProtocol.self]
                return configuration
            }
        )
        let encodedBody = Data(#"{"LEVEL":20}"#.utf8)

        let response = try await transport.send(SCPLRequest(
            path: "/audio/volume/level",
            method: .put,
            body: ["LEVEL": 20],
            preencodedBody: encodedBody,
            statusOnlyResponse: true
        ), token: "secret")

        XCTAssertEqual(response.body["STATUS"]?["RESULT"]?.stringValue, "SUCCESS")
        let request = await captureProtocolProbe.waitForRequest()
        XCTAssertEqual(request.url?.absoluteString, "https://192.168.50.42:7345/audio/volume/level")
        XCTAssertNotNil(request.httpBody ?? request.httpBodyStream.map { _ in Data() })
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), String(encodedBody.count))
    }

    func testHostnameEndpointUsesResolvedPrivateIPv4ForTVRequests() {
        let endpoint = DeviceEndpoint(
            host: "living-room.local",
            resolvedAddresses: ["fe80::42", "192.168.50.42"],
            interfaceIndex: 5
        )

        XCTAssertEqual(smartCastConnectionHost(endpoint), "192.168.50.42")
        XCTAssertEqual(
            smartCastURL(endpoint: endpoint, path: "/state/device/deviceinfo")?.absoluteString,
            "https://192.168.50.42:7345/state/device/deviceinfo"
        )
    }

    func testUnreadableJSONHasExactError() async {
        let transport = URLSessionSmartCastTransport(
            endpoint: DeviceEndpoint(host: "192.168.50.42"),
            trustMode: .firstContact,
            configurationFactory: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [InvalidJSONURLProtocol.self]
                return configuration
            }
        )

        do {
            _ = try await transport.send(SCPLRequest(
                path: "/state/device/deviceinfo",
                method: .get,
                authenticated: false
            ), token: nil)
            XCTFail("Expected invalid JSON failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "TV returned an unreadable response.")
        }
    }

    func testFingerprintNormalizationAndScopedTrustDecisions() {
        let compact = String(repeating: "AB", count: 32)
        let normalized = stride(from: 0, to: compact.count, by: 2).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            return String(compact[start..<compact.index(start, offsetBy: 2)])
        }.joined(separator: ":")
        XCTAssertEqual(normalizeCertificateFingerprint(compact.lowercased()), normalized)
        XCTAssertEqual(normalizeCertificateFingerprint(normalized), normalized)
        XCTAssertNil(normalizeCertificateFingerprint("AA:BB"))

        let policy = SmartCastTrustPolicy(
            endpointHost: "living-room.local",
            mode: .pinned(normalized.lowercased())
        )
        XCTAssertEqual(policy.decision(
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            challengeHost: "LIVING-ROOM.LOCAL",
            fingerprint: compact
        ), .accept)
        XCTAssertEqual(policy.decision(
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            challengeHost: "living-room.local",
            fingerprint: String(repeating: "CD", count: 32)
        ), .rejectFingerprint)
        XCTAssertEqual(policy.decision(
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            challengeHost: "other.local",
            fingerprint: compact
        ), .rejectHost)
        XCTAssertEqual(policy.decision(
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
            challengeHost: "other.local",
            fingerprint: nil
        ), .performDefaultHandling)
    }

    func testRawIPv6URLIsBracketed() {
        let endpoint = DeviceEndpoint(host: "fd00::42")
        let url = smartCastURL(endpoint: endpoint, path: "/state/device/power_mode")
        XCTAssertEqual(url?.absoluteString, "https://[fd00::42]:7345/state/device/power_mode")
    }
}

private actor DurationProbe {
    private(set) var value: Duration?
    func record(_ value: Duration) { self.value = value }
}

private final class HangingProtocolProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    func reset() {
        lock.withLock {
            precondition(startWaiters.isEmpty && stopWaiters.isEmpty)
            started = false
            stopped = false
        }
    }

    func markStarted() {
        let waiters = lock.withLock {
            started = true
            let waiters = startWaiters
            startWaiters = []
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func markStopped() {
        let waiters = lock.withLock {
            stopped = true
            let waiters = stopWaiters
            stopWaiters = []
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if started { return true }
                startWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if stopped { return true }
                stopWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

private let hangingProtocolProbe = HangingProtocolProbe()

private final class HangingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        hangingProtocolProbe.markStarted()
    }

    override func stopLoading() {
        hangingProtocolProbe.markStopped()
    }
}

private actor CaptureProtocolProbe {
    private var request: URLRequest?
    private var waiters: [CheckedContinuation<URLRequest, Never>] = []

    func reset() {
        request = nil
        waiters = []
    }

    func record(_ request: URLRequest) {
        self.request = request
        waiters.forEach { $0.resume(returning: request) }
        waiters = []
    }

    func waitForRequest() async -> URLRequest {
        if let request { return request }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private let captureProtocolProbe = CaptureProtocolProbe()

private final class CapturingURLProtocol: URLProtocol, @unchecked Sendable {
    private var responseTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let box = UncheckedSendableBox(value: self)
        responseTask = Task.detached {
            await Task.yield()
            let protocolInstance = box.value
            guard !Task.isCancelled else { return }
            let request = protocolInstance.request
            await captureProtocolProbe.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data("{\"STATUS\":{\"RESULT\":\"SUCCESS\"}}".utf8))
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
    }

    override func stopLoading() {
        responseTask?.cancel()
    }
}

private final class InvalidJSONURLProtocol: URLProtocol, @unchecked Sendable {
    private var responseTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let box = UncheckedSendableBox(value: self)
        responseTask = Task.detached {
            await Task.yield()
            let protocolInstance = box.value
            guard !Task.isCancelled else { return }
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data("not-json".utf8))
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
    }

    override func stopLoading() {
        responseTask?.cancel()
    }
}

private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}
