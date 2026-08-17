import Foundation
import VizioControl

private final class DispatchLatencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var armedAt: UInt64?
    private var samplesNanoseconds: [UInt64] = []

    func beginCollection(capacity: Int) {
        lock.lock()
        armedAt = nil
        samplesNanoseconds.removeAll(keepingCapacity: true)
        samplesNanoseconds.reserveCapacity(capacity)
        lock.unlock()
    }

    func arm() {
        lock.lock()
        armedAt = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    func recordRequestStart() {
        let observedAt = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if let armedAt {
            samplesNanoseconds.append(observedAt &- armedAt)
            self.armedAt = nil
        }
        lock.unlock()
    }

    func samples() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return samplesNanoseconds
    }
}

private final class BenchmarkProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var probe: DispatchLatencyProbe?

    func configure(probe: DispatchLatencyProbe) {
        lock.lock()
        self.probe = probe
        lock.unlock()
    }

    func recordRequestStart() {
        lock.lock()
        let probe = probe
        lock.unlock()
        probe?.recordRequestStart()
    }
}

private final class BenchmarkURLProtocol: URLProtocol, @unchecked Sendable {
    private static let state = BenchmarkProtocolState()
    private static let successData = Data(#"{"STATUS":{"RESULT":"SUCCESS"}}"#.utf8)
    private static let powerData = Data(#"{"STATUS":{"RESULT":"SUCCESS"},"VALUE":1}"#.utf8)

    static func configure(probe: DispatchLatencyProbe) {
        state.configure(probe: probe)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if path.contains("key_command") {
            Self.state.recordRequestStart()
        }
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
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: path.contains("power_mode") ? Self.powerData : Self.successData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
private struct ButtonPressLatencyBenchmark {
    private static let warmupIterations = 2_000
    private static let measuredIterations = 30_000
    private static let keys: [TVKey] = [.up, .right, .down, .left, .ok, .back, .play, .pause]

    @MainActor
    static func main() async throws {
        let endpoint = DeviceEndpoint(host: "192.0.2.42", resolvedAddresses: ["192.0.2.42"])
        let device = PairedDevice(
            id: "benchmark-tv",
            name: "Benchmark TV",
            endpoint: endpoint,
            fingerprint: String(repeating: "AA", count: 32),
            deviceID: "benchmark-device",
            pairedAt: Date(timeIntervalSince1970: 0)
        )
        let probe = DispatchLatencyProbe()
        BenchmarkURLProtocol.configure(probe: probe)
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
                        configuration.protocolClasses = [BenchmarkURLProtocol.self]
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
            throw BenchmarkFailure("Benchmark controller did not initialize a connected TV state.")
        }

        for index in 0..<warmupIterations {
            let key = keys[index % keys.count]
            _ = try await Task { @MainActor in try await controller.press(key) }.value
        }

        probe.beginCollection(capacity: measuredIterations)
        let completionStart = ContinuousClock.now
        var checksum = 0
        for index in 0..<measuredIterations {
            let key = keys[index % keys.count]
            probe.arm()
            let state = try await Task { @MainActor in try await controller.press(key) }.value
            checksum &+= state.connected ? index &+ 1 : 0
        }
        let completionDuration = completionStart.duration(to: .now)
        await controller.handleScenePhase(.background)

        let samples = probe.samples().sorted()
        guard samples.count == measuredIterations else {
            throw BenchmarkFailure(
                "Expected \(measuredIterations) key requests, observed \(samples.count)."
            )
        }

        let medianNanoseconds = percentile(samples, numerator: 50, denominator: 100)
        let p95Nanoseconds = percentile(samples, numerator: 95, denominator: 100)
        let completionNanoseconds = nanoseconds(completionDuration)
        let completionPerPress = Double(completionNanoseconds) / Double(measuredIterations)

        printMetric("button_action_latency_us", Double(medianNanoseconds) / 1_000)
        printMetric("button_action_p95_us", Double(p95Nanoseconds) / 1_000)
        printMetric("button_completion_us", completionPerPress / 1_000)
        printMetric("button_presses_per_second", 1_000_000_000 / completionPerPress)
        print("ASI iterations=\(measuredIterations)")
        print("ASI checksum=\(checksum)")
    }

    private static func percentile(
        _ sortedSamples: [UInt64],
        numerator: Int,
        denominator: Int
    ) -> UInt64 {
        let index = ((sortedSamples.count - 1) * numerator) / denominator
        return sortedSamples[index]
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = UInt64(max(0, components.seconds))
        let attoseconds = UInt64(max(0, components.attoseconds))
        return seconds &* 1_000_000_000 &+ attoseconds / 1_000_000_000
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
