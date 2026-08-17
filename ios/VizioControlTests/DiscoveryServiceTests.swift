import Foundation
import Network
import XCTest
@testable import VizioControl

final class DiscoveryServiceTests: XCTestCase, @unchecked Sendable {
    func testDiscoveryResolvesAndProbesConcurrentlyThenMergesByStrongestIdentity() async throws {
        let services = (0..<3).map {
            BonjourServiceDescriptor(name: "TV-\($0)", type: "_viziocast._tcp", domain: "local.", interfaceIndex: 4)
        }
        let browser = ImmediateBonjourBrowser(services: services)
        let resolver = BarrierBonjourResolver(expectedCount: services.count)
        let probes = ConcurrentProbeRecorder()
        let cached = PairedDevice(
            id: "cached",
            name: "Family Room",
            endpoint: DeviceEndpoint(host: "192.168.50.10", resolvedAddresses: ["192.168.50.10"]),
            model: nil,
            serial: "SERIAL-A",
            fingerprint: fingerprint("11"),
            macAddress: nil,
            deviceID: "device-a",
            pairedAt: Date(timeIntervalSince1970: 10)
        )
        let service = DiscoveryService(
            browser: browser,
            resolver: resolver,
            probe: { endpoint in await probes.probe(endpoint) }
        )

        let values = try await service.discover(
            cached: cached,
            manualEndpoint: "192.168.50.10",
            manualMAC: "A8-C9-6B-12-34-56"
        )

        let resolverMaximum = await resolver.maximumConcurrentCount()
        let probeMaximum = await probes.maximumConcurrentCount()
        XCTAssertEqual(resolverMaximum, 3)
        XCTAssertGreaterThan(probeMaximum, 1)
        XCTAssertEqual(values.count, 2)
        let primary = try XCTUnwrap(values.first { $0.serial == "SERIAL-A" })
        XCTAssertEqual(primary.source, .mdns)
        XCTAssertEqual(primary.macAddress, "A8:C9:6B:12:34:56")
        XCTAssertNotNil(primary.fingerprint)
        XCTAssertEqual(Set(primary.endpoint.resolvedAddresses), Set([
            "192.168.50.10", "192.168.50.20", "192.168.50.21",
        ]))
        XCTAssertNotEqual(primary.id, "cached")
        XCTAssertEqual(values.first { $0.serial == "SERIAL-C" }?.source, .mdns)
    }

    func testDiscoveryFailsClosedWithoutFingerprintAndCancellationStopsBrowser() async throws {
        let descriptor = BonjourServiceDescriptor(
            name: "TV", type: "_viziocast._tcp", domain: "local.", interfaceIndex: 4
        )
        let browser = ImmediateBonjourBrowser(services: [descriptor])
        let resolver = StaticBonjourResolver(result: ResolvedBonjourService(
            endpoint: DeviceEndpoint(host: "tv.local", resolvedAddresses: ["192.168.50.20"], interfaceIndex: 4),
            txt: [:]
        ))
        let service = DiscoveryService(
            browser: browser,
            resolver: resolver,
            probe: { _ in DiscoveryProbeResult(info: ParsedDeviceInfo(name: "TV"), fingerprint: "") }
        )
        let values = try await service.discover(cached: nil, manualEndpoint: "", manualMAC: "")
        XCTAssertTrue(values.isEmpty)

        let blockingBrowser = BlockingBonjourBrowser()
        let blockingService = DiscoveryService(browser: blockingBrowser, resolver: resolver, probe: { _ in
            XCTFail("Probe should not run")
            throw CancellationError()
        })
        let task = Task {
            try await blockingService.discover(cached: nil, manualEndpoint: "", manualMAC: "")
        }
        await blockingBrowser.waitUntilStarted()
        blockingService.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(blockingBrowser.wasCancelled())
    }

    func testPermissionPromptInactivityDefersDenialAndActiveReturnUsesGraceWindow() async throws {
        let gate = PermissionSleepGate()
        let state = BonjourPermissionState(browserCount: 3, sleep: { duration in
            await gate.sleep(duration)
        })
        let completion = CompletionProbe()
        let waiter = Task {
            do {
                try await state.waitUntilReadyOrDenied()
                await completion.finish(nil)
            } catch {
                await completion.finish(error)
            }
        }

        for index in 0..<3 {
            await state.updateBrowser(
                index: index,
                state: .waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))
            )
        }
        await gate.waitForCount(1)
        let initialDelay = await gate.duration(at: 0)
        XCTAssertEqual(initialDelay, .seconds(1))
        await state.setSceneActivity(.inactive)
        await gate.resume(at: 0)
        await Task.yield()
        let finishedDuringPrompt = await completion.isFinished()
        XCTAssertFalse(finishedDuringPrompt)

        await state.setSceneActivity(.active)
        await gate.waitForCount(2)
        let graceDelay = await gate.duration(at: 1)
        XCTAssertEqual(graceDelay, .milliseconds(500))
        await gate.resume(at: 1)
        await waiter.value
        let error = await completion.error()
        guard let controlError = error as? VizioControlError, controlError == .localNetworkDenied else {
            return XCTFail("Expected local-network denial, got \(String(describing: error))")
        }
    }

    func testPermissionReadinessWinsAndBackgroundCancelsPendingPrompt() async throws {
        let gate = PermissionSleepGate()
        let state = BonjourPermissionState(browserCount: 3, sleep: { duration in await gate.sleep(duration) })
        let readyTask = Task { try await state.waitUntilReadyOrDenied() }
        for index in 0..<3 {
            await state.updateBrowser(
                index: index,
                state: .waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))
            )
        }
        await gate.waitForCount(1)
        await state.updateBrowser(index: 1, state: .ready)
        try await readyTask.value
        await gate.resume(at: 0)

        let pending = BonjourPermissionState(browserCount: 3)
        await pending.setSceneActivity(.background)
        do {
            try await pending.waitUntilReadyOrDenied()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    func testFailedPolicyAndTerminalBrowsersProduceDenial() async {
        let gate = PermissionSleepGate()
        let state = BonjourPermissionState(browserCount: 3, sleep: { duration in await gate.sleep(duration) })
        await state.updateBrowser(
            index: 0,
            state: .failed(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))
        )
        await state.updateBrowser(index: 1, state: .failed(.posix(.ECONNREFUSED)))
        await state.updateBrowser(index: 2, state: .cancelled)
        await gate.waitForCount(1)
        await gate.resume(at: 0)
        do {
            try await state.waitUntilReadyOrDenied()
            XCTFail("Expected local-network denial")
        } catch let error as VizioControlError {
            XCTAssertEqual(error, .localNetworkDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testManualEndpointPolicyAndIdentityRepairAreFailClosed() async throws {
        let privateA = try await validateManualEndpoint("10.2.3.4")
        let privateB = try await validateManualEndpoint("172.31.8.9")
        let privateC = try await validateManualEndpoint("192.168.1.9")
        let privateV6 = try await validateManualEndpoint("fd12:3456::9")
        XCTAssertEqual(privateA.host, "10.2.3.4")
        XCTAssertEqual(privateB.host, "172.31.8.9")
        XCTAssertEqual(privateC.host, "192.168.1.9")
        XCTAssertEqual(privateV6.host, "fd12:3456::9")
        for rejected in ["8.8.8.8", "172.32.0.1", "fe80::1%en0", "2001:4860:4860::8888"] {
            do {
                _ = try await validateManualEndpoint(rejected)
                XCTFail("Expected \(rejected) to be rejected")
            } catch VizioControlError.invalidManualEndpoint {
            } catch {
                XCTFail("Unexpected error for \(rejected): \(error)")
            }
        }

        let paired = PairedDevice(
            id: "device", name: "TV",
            endpoint: DeviceEndpoint(host: "192.168.1.10"),
            model: nil, serial: "SERIAL-A", fingerprint: fingerprint("11"), macAddress: nil,
            deviceID: "auth", pairedAt: Date()
        )
        let matching = DeviceCandidate(
            id: "new", name: "TV", endpoint: DeviceEndpoint(host: "192.168.1.22"),
            model: nil, serial: "SERIAL-A", fingerprint: fingerprint("22"), macAddress: nil, source: .mdns
        )
        var mismatch = matching
        mismatch.serial = "SERIAL-B"
        XCTAssertTrue(isSameDevice(paired, matching))
        XCTAssertFalse(isSameDevice(paired, mismatch))
    }
}

private func fingerprint(_ pair: String) -> String {
    Array(repeating: pair, count: 32).joined(separator: ":")
}

private final class ImmediateBonjourBrowser: BonjourBrowsing, @unchecked Sendable {
    private let services: [BonjourServiceDescriptor]
    init(services: [BonjourServiceDescriptor]) { self.services = services }

    func browse(onProgress: @escaping @Sendable (DiscoveryProgress) -> Void) async throws -> [BonjourServiceDescriptor] {
        onProgress(.waitingForPermission)
        onProgress(.scanning)
        return services
    }
    func cancel() {}
    func handleSceneActivity(_ activity: AppSceneActivity) {}
}

private actor BarrierBonjourResolver: BonjourResolving {
    private struct Waiter {
        var service: BonjourServiceDescriptor
        var continuation: CheckedContinuation<ResolvedBonjourService, Never>
    }

    private let expectedCount: Int
    private var waiters: [Waiter] = []
    private var active = 0
    private var maximum = 0

    init(expectedCount: Int) { self.expectedCount = expectedCount }

    func resolve(_ service: BonjourServiceDescriptor, timeout: Duration) async throws -> ResolvedBonjourService {
        active += 1
        maximum = max(maximum, active)
        let value = await withCheckedContinuation { continuation in
            waiters.append(Waiter(service: service, continuation: continuation))
            guard waiters.count == expectedCount else { return }
            let current = waiters
            waiters = []
            for waiter in current {
                let suffix = waiter.service.name == "TV-2" ? 30 : (waiter.service.name == "TV-1" ? 21 : 20)
                let mac = waiter.service.name == "TV-0" ? ["wifi": "A8C96B123456"] : [:]
                waiter.continuation.resume(returning: ResolvedBonjourService(
                    endpoint: DeviceEndpoint(
                        host: "tv-\(suffix).local",
                        resolvedAddresses: ["192.168.50.\(suffix)"],
                        interfaceIndex: 4
                    ),
                    txt: mac
                ))
            }
        }
        active -= 1
        return value
    }

    func maximumConcurrentCount() -> Int { maximum }
}

private actor StaticBonjourResolver: BonjourResolving {
    let result: ResolvedBonjourService
    init(result: ResolvedBonjourService) { self.result = result }
    func resolve(_ service: BonjourServiceDescriptor, timeout: Duration) async throws -> ResolvedBonjourService { result }
}

private actor ConcurrentProbeRecorder {
    private var active = 0
    private var maximum = 0

    func probe(_ endpoint: DeviceEndpoint) async -> DiscoveryProbeResult {
        active += 1
        maximum = max(maximum, active)
        try? await ContinuousClock().sleep(for: .milliseconds(2))
        active -= 1
        let serial = endpoint.host == "tv-30.local" ? "SERIAL-C" : "SERIAL-A"
        return DiscoveryProbeResult(
            info: ParsedDeviceInfo(model: "M55", serial: serial, name: "Family Room"),
            fingerprint: fingerprint("AA")
        )
    }

    func maximumConcurrentCount() -> Int { maximum }
}

private final class BlockingBonjourBrowser: BonjourBrowsing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[BonjourServiceDescriptor], Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false
    private var cancelled = false

    func browse(onProgress: @escaping @Sendable (DiscoveryProgress) -> Void) async throws -> [BonjourServiceDescriptor] {
        onProgress(.waitingForPermission)
        return try await withCheckedThrowingContinuation { continuation in
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                started = true
                self.continuation = continuation
                let waiters = startWaiters
                startWaiters = []
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func cancel() {
        let continuation = lock.withLock { () -> CheckedContinuation<[BonjourServiceDescriptor], Error>? in
            cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    func handleSceneActivity(_ activity: AppSceneActivity) {}

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if started { return true }
                startWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func wasCancelled() -> Bool {
        lock.withLock { cancelled }
    }
}

private actor PermissionSleepGate {
    private struct Entry {
        var duration: Duration
        var continuation: CheckedContinuation<Void, Never>
    }
    private var entries: [Entry] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            entries.append(Entry(duration: duration, continuation: continuation))
            let ready = countWaiters.filter { entries.count >= $0.0 }
            countWaiters.removeAll { entries.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitForCount(_ count: Int) async {
        if entries.count >= count { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func duration(at index: Int) -> Duration { entries[index].duration }
    func resume(at index: Int) { entries[index].continuation.resume() }
}

private actor CompletionProbe {
    private var finished = false
    private var storedError: Error?
    func finish(_ error: Error?) { finished = true; storedError = error }
    func isFinished() -> Bool { finished }
    func error() -> Error? { storedError }
}
