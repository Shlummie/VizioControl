import Foundation
import VizioControl

private struct RequestWaiter {
    let count: Int
    let continuation: CheckedContinuation<Void, Never>
}

private struct BurstSamples: Sendable {
    let firstDispatchNanoseconds: [UInt64]
    let followupDispatchNanoseconds: [UInt64]
}

private final class BurstProtocolCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var collecting = false
    private var firstArmedAt: UInt64?
    private var followupArmedAt: UInt64?
    private var firstDispatchSamples: [UInt64] = []
    private var followupDispatchSamples: [UInt64] = []
    private var requestBodies: [Data] = []
    private var heldRequest: BurstURLProtocol?
    private var autoRespondFollowups = false
    private var waiters: [RequestWaiter] = []

    func beginCollection(capacity: Int) {
        lock.lock()
        collecting = true
        firstDispatchSamples.removeAll(keepingCapacity: true)
        followupDispatchSamples.removeAll(keepingCapacity: true)
        firstDispatchSamples.reserveCapacity(capacity)
        followupDispatchSamples.reserveCapacity(capacity)
        lock.unlock()
    }

    func beginBurst(firstArmedAt: UInt64) {
        lock.lock()
        precondition(heldRequest == nil, "Previous burst still has a held request.")
        precondition(waiters.isEmpty, "Previous burst still has request waiters.")
        requestBodies.removeAll(keepingCapacity: true)
        autoRespondFollowups = false
        self.firstArmedAt = collecting ? firstArmedAt : nil
        followupArmedAt = nil
        lock.unlock()
    }

    func recordKeyRequest(
        _ protocolInstance: BurstURLProtocol,
        body: Data,
        observedAt: UInt64
    ) -> Bool {
        var ready: [CheckedContinuation<Void, Never>] = []

        lock.lock()
        requestBodies.append(body)
        let requestCount = requestBodies.count
        if requestCount == 1, let firstArmedAt {
            firstDispatchSamples.append(observedAt &- firstArmedAt)
            self.firstArmedAt = nil
        } else if requestCount == 2, let followupArmedAt {
            followupDispatchSamples.append(observedAt &- followupArmedAt)
            self.followupArmedAt = nil
        }

        let shouldRespond = autoRespondFollowups
        if !shouldRespond {
            precondition(heldRequest == nil, "Only the first request in a burst may be held.")
            heldRequest = protocolInstance
        }

        var remaining: [RequestWaiter] = []
        remaining.reserveCapacity(waiters.count)
        for waiter in waiters {
            if requestCount >= waiter.count {
                ready.append(waiter.continuation)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
        lock.unlock()

        ready.forEach { $0.resume() }
        return shouldRespond
    }

    func waitForRequestCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if requestBodies.count >= count {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(RequestWaiter(count: count, continuation: continuation))
                lock.unlock()
            }
        }
    }

    func releaseFirstAndArmFollowup() throws -> UInt64 {
        let releasedAt = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard let request = heldRequest else {
            lock.unlock()
            throw BenchmarkFailure("Burst did not hold its first key request.")
        }
        heldRequest = nil
        autoRespondFollowups = true
        followupArmedAt = collecting ? releasedAt : nil
        lock.unlock()
        request.respond()
        return releasedAt
    }

    func requestBodiesSnapshot() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return requestBodies
    }

    func samples() -> BurstSamples {
        lock.lock()
        defer { lock.unlock() }
        return BurstSamples(
            firstDispatchNanoseconds: firstDispatchSamples,
            followupDispatchNanoseconds: followupDispatchSamples
        )
    }
}

private let burstProtocolCoordinator = BurstProtocolCoordinator()
private func requestBodyData(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            stream.read(
                bytes.bindMemory(to: UInt8.self).baseAddress!,
                maxLength: bytes.count
            )
        }
        guard count > 0 else { return data }
        data.append(buffer, count: count)
    }
}


private final class BurstURLProtocol: URLProtocol, @unchecked Sendable {
    private static let successData = Data(#"{"STATUS":{"RESULT":"SUCCESS"}}"#.utf8)
    private static let powerData = Data(#"{"STATUS":{"RESULT":"SUCCESS"},"VALUE":1}"#.utf8)
    private let finishLock = NSLock()
    private var finished = false

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        guard path.contains("key_command") else {
            respond()
            return
        }
        let observedAt = DispatchTime.now().uptimeNanoseconds
        let shouldRespond = burstProtocolCoordinator.recordKeyRequest(
            self,
            body: requestBodyData(request),
            observedAt: observedAt
        )
        if shouldRespond { respond() }
    }

    func respond() {
        finishLock.lock()
        guard !finished else {
            finishLock.unlock()
            return
        }
        finished = true
        finishLock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: BenchmarkFailure("Invalid benchmark request URL."))
            return
        }
        let data = request.url?.path.contains("power_mode") == true ? Self.powerData : Self.successData
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        finishLock.lock()
        finished = true
        finishLock.unlock()
    }
}

private actor BenchmarkStore: AppStoring {
    private var file: StoreFile

    init(device: PairedDevice) {
        file = StoreFile(device: device)
    }

    func load() throws -> StoreFile { file }
    func snapshot() -> StoreFile { file }

    func updateSettings(_ settings: AppSettings) throws -> AppSettings {
        file.settings = settings
        return settings
    }

    func updateSettingsAndDevice(settings: AppSettings, device: PairedDevice?) throws {
        file.settings = settings
        file.device = device
    }

    func setDevice(_ device: PairedDevice?) throws {
        file.device = device
    }

    func command(id: UUID) -> SavedCommand? {
        file.commands.first { $0.id == id }
    }

    func commands() -> [SavedCommand] { file.commands }

    func upsertCommand(_ command: SavedCommand) throws -> [SavedCommand] {
        if let index = file.commands.firstIndex(where: { $0.id == command.id }) {
            file.commands[index] = command
        } else {
            file.commands.append(command)
        }
        return file.commands
    }

    func editCommand(id: UUID, label: String, updatedAt: Date) throws -> [SavedCommand] {
        guard let index = file.commands.firstIndex(where: { $0.id == id }) else { return file.commands }
        file.commands[index].label = label
        file.commands[index].updatedAt = updatedAt
        return file.commands
    }

    func duplicateCommand(id: UUID, at date: Date) throws -> [SavedCommand] { file.commands }

    func deleteCommand(id: UUID) throws -> [SavedCommand] {
        file.commands.removeAll { $0.id == id }
        return file.commands
    }

    func undoDelete() throws -> [SavedCommand] { file.commands }
    func reorderCommand(id: UUID, direction: Int) throws -> [SavedCommand] { file.commands }
}

private struct BenchmarkTokenStore: TokenStoring {
    func save(_ token: String, account: String) async throws {}
    func read(account: String) async throws -> String? { "benchmark-token" }
    func delete(account: String) async throws {}
    func deleteAll() async throws {}
}

@main
private struct BurstButtonLatencyBenchmark {
    private static let warmupBursts = 300
    private static let measuredBursts = 3_000
    private static let burstKeys: [TVKey] = [
        .up, .right, .down, .left, .ok, .back, .play, .pause, .up, .right,
    ]

    @MainActor
    static func main() async throws {
        let endpoint = DeviceEndpoint(host: "192.0.2.42", resolvedAddresses: ["192.0.2.42"])
        let device = PairedDevice(
            id: "burst-benchmark-tv",
            name: "Burst Benchmark TV",
            endpoint: endpoint,
            fingerprint: String(repeating: "AA", count: 32),
            deviceID: "burst-benchmark-device",
            pairedAt: Date(timeIntervalSince1970: 0)
        )
        let store = BenchmarkStore(device: device)
        let controller = RemoteController(
            store: store,
            keychain: BenchmarkTokenStore(),
            clientFactory: { endpoint, trustMode, token, serial in
                let transport = URLSessionSmartCastTransport(
                    endpoint: endpoint,
                    trustMode: trustMode,
                    configurationFactory: {
                        let configuration = URLSessionConfiguration.ephemeral
                        configuration.protocolClasses = [BurstURLProtocol.self]
                        return configuration
                    }
                )
                return SmartCastClient(
                    endpoint: endpoint,
                    transport: transport,
                    token: token,
                    expectedSerial: serial
                )
            }
        )

        await controller.initialize()
        guard controller.tvState.connected else {
            throw BenchmarkFailure("Burst benchmark controller did not initialize a connected TV state.")
        }

        for _ in 0..<warmupBursts {
            _ = try await runBurst(controller: controller, burstIndex: nil)
        }

        burstProtocolCoordinator.beginCollection(capacity: measuredBursts)
        var completionSamples: [UInt64] = []
        completionSamples.reserveCapacity(measuredBursts)
        var checksum = 0
        var requestCount = 0

        for burstIndex in 0..<measuredBursts {
            let result = try await runBurst(controller: controller, burstIndex: burstIndex)
            completionSamples.append(result.completionNanoseconds)
            checksum &+= result.checksum
            requestCount &+= result.requestCount
        }
        await controller.handleScenePhase(.background)

        let dispatchSamples = burstProtocolCoordinator.samples()
        guard dispatchSamples.firstDispatchNanoseconds.count == measuredBursts,
              dispatchSamples.followupDispatchNanoseconds.count == measuredBursts,
              completionSamples.count == measuredBursts else {
            throw BenchmarkFailure("Burst benchmark did not collect every expected sample.")
        }

        let first = dispatchSamples.firstDispatchNanoseconds.sorted()
        let followup = dispatchSamples.followupDispatchNanoseconds.sorted()
        let completion = completionSamples.sorted()
        let totalCompletion = completionSamples.reduce(UInt64(0), &+)
        let presses = measuredBursts * burstKeys.count

        printMetric("burst_followup_latency_us", Double(percentile(followup, numerator: 50, denominator: 100)) / 1_000)
        printMetric("burst_followup_p95_us", Double(percentile(followup, numerator: 95, denominator: 100)) / 1_000)
        printMetric("burst_first_dispatch_us", Double(percentile(first, numerator: 50, denominator: 100)) / 1_000)
        printMetric("burst_completion_us", Double(percentile(completion, numerator: 50, denominator: 100)) / 1_000)
        printMetric("burst_completion_p95_us", Double(percentile(completion, numerator: 95, denominator: 100)) / 1_000)
        printMetric("burst_presses_per_second", Double(presses) * 1_000_000_000 / Double(totalCompletion))
        printMetric("burst_requests_per_10_presses", Double(requestCount) / Double(measuredBursts))
        print("ASI bursts=\(measuredBursts)")
        print("ASI presses=\(presses)")
        print("ASI requests=\(requestCount)")
        print("ASI checksum=\(checksum)")
    }

    @MainActor
    private static func runBurst(
        controller: RemoteController,
        burstIndex: Int?
    ) async throws -> (completionNanoseconds: UInt64, checksum: Int, requestCount: Int) {
        let firstArmedAt = DispatchTime.now().uptimeNanoseconds
        burstProtocolCoordinator.beginBurst(firstArmedAt: firstArmedAt)

        var tasks = [startPress(controller: controller, key: burstKeys[0])]
        await burstProtocolCoordinator.waitForRequestCount(1)
        for key in burstKeys.dropFirst() {
            tasks.append(startPress(controller: controller, key: key))
        }
        try await Task.sleep(for: .microseconds(250))

        let releasedAt = try burstProtocolCoordinator.releaseFirstAndArmFollowup()
        var checksum = 0
        for (index, task) in tasks.enumerated() {
            let state = try await task.value
            if let burstIndex, state.connected {
                checksum &+= (burstIndex &+ 1) &* (index &+ 1)
            }
        }
        let completedAt = DispatchTime.now().uptimeNanoseconds
        let requestBodies = burstProtocolCoordinator.requestBodiesSnapshot()
        try verifyRequests(requestBodies)
        return (completedAt &- releasedAt, checksum, requestBodies.count)
    }

    @MainActor
    private static func startPress(
        controller: RemoteController,
        key: TVKey
    ) -> Task<TVState, any Error> {
        if #available(macOS 26, *) {
            Task.immediate { @MainActor in try await controller.press(key) }
        } else {
            Task { @MainActor in try await controller.press(key) }
        }
    }

    private static func verifyRequests(_ bodies: [Data]) throws {
        guard bodies.count == 2 else {
            throw BenchmarkFailure("Expected two HTTP requests for ten queued presses; observed \(bodies.count).")
        }
        let actual = try bodies.map(keySignatures)
        let expected = [
            [signature(for: burstKeys[0])],
            burstKeys.dropFirst().map(signature),
        ]
        guard actual == expected else {
            throw BenchmarkFailure("Burst key order or batching changed: \(actual).")
        }
    }

    private static func keySignatures(_ data: Data) throws -> [String] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keys = root["KEYLIST"] as? [[String: Any]] else {
            throw BenchmarkFailure("Burst request body was not a SmartCast KEYLIST payload.")
        }
        return try keys.map { key in
            guard let codeset = (key["CODESET"] as? NSNumber)?.intValue,
                  let code = (key["CODE"] as? NSNumber)?.intValue,
                  key["ACTION"] as? String == "KEYPRESS" else {
                throw BenchmarkFailure("Burst request contained an invalid key entry.")
            }
            return "\(codeset):\(code)"
        }
    }

    private static func signature(for key: TVKey) -> String {
        switch key {
        case .powerOff: "11:0"
        case .powerOn: "11:1"
        case .powerToggle: "11:2"
        case .volumeDown: "5:0"
        case .volumeUp: "5:1"
        case .mute: "5:4"
        case .input: "7:1"
        case .down: "3:0"
        case .left: "3:1"
        case .ok: "3:2"
        case .right: "3:7"
        case .up: "3:8"
        case .back: "4:0"
        case .home: "4:3"
        case .menu: "4:8"
        case .exit: "9:0"
        case .fastForward: "2:0"
        case .rewind: "2:1"
        case .pause: "2:2"
        case .play: "2:3"
        }
    }

    private static func percentile(
        _ sortedSamples: [UInt64],
        numerator: Int,
        denominator: Int
    ) -> UInt64 {
        sortedSamples[((sortedSamples.count - 1) * numerator) / denominator]
    }

    private static func printMetric(_ name: String, _ value: Double) {
        print("METRIC \(name)=\(String(format: "%.3f", value))")
    }
}

private struct BenchmarkFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
