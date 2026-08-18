#if DEBUG
import Foundation

@MainActor
enum UITestSupport {
    private static let modeArgument = "--ui-testing"
    private static let resetArgument = "--ui-testing-reset"
    private static let identifierKey = "VIZIO_UI_TEST_ID"

    static func makeControllerIfRequested() -> RemoteController? {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains(modeArgument) else { return nil }

        do {
            let identifier = process.environment[identifierKey] ?? "default"
            let safeIdentifier = identifier.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let baseDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let directory = baseDirectory
                .appendingPathComponent("VizioControlUITests", isDirectory: true)
                .appendingPathComponent(
                    safeIdentifier.isEmpty ? "default" : safeIdentifier,
                    isDirectory: true
                )

            if process.arguments.contains(resetArgument),
               FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try seedStoreIfNeeded(in: directory)

            return RemoteController(
                store: AppStore(directory: directory),
                keychain: UITestTokenStore(),
                clientFactory: { endpoint, _, _, _ in
                    UITestSmartCastClient(endpoint: endpoint)
                }
            )
        } catch {
            preconditionFailure("Could not prepare UI test state: \(error)")
        }
    }

    private static func seedStoreIfNeeded(in directory: URL) throws {
        let stateURL = directory.appendingPathComponent("viziocontrol.json", isDirectory: false)
        guard !FileManager.default.fileExists(atPath: stateURL.path) else { return }

        let endpoint = DeviceEndpoint(
            host: "192.0.2.42",
            resolvedAddresses: ["192.0.2.42"],
            interfaceIndex: 4
        )
        let device = PairedDevice(
            id: "ui-test-tv",
            name: "UI Test TV",
            endpoint: endpoint,
            model: "Simulator",
            serial: "UI-TEST-SERIAL",
            fingerprint: String(repeating: "AB", count: 32),
            macAddress: "A8:C9:6B:12:34:56",
            deviceID: "ui-test-device",
            pairedAt: Date(timeIntervalSince1970: 0)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(StoreFile(device: device))
        try data.write(to: stateURL, options: .atomic)
    }
}

private actor UITestTokenStore: TokenStoring {
    func save(_ token: String, account: String) async throws { }
    func read(account: String) async throws -> String? { "ui-test-token" }
    func delete(account: String) async throws { }
    func deleteAll() async throws { }
}

private actor UITestSmartCastClient: SmartCastControlling {
    let endpoint: DeviceEndpoint

    init(endpoint: DeviceEndpoint) {
        self.endpoint = endpoint
    }

    func setToken(_ token: String?) { }
    func setExpectedSerial(_ serial: String?) { }

    func getDeviceInfo(timeout: Duration) async throws -> SCPLResponse {
        SCPLResponse(statusCode: 200, body: .object([:]))
    }

    func getState() async -> TVState {
        TVState(
            connected: true,
            power: true,
            volume: 20,
            muted: false,
            endpoint: endpoint
        )
    }

    func startPairing(deviceID: String) async throws -> Int { 1 }
    func finishPairing(deviceID: String, requestToken: Int, pin: String) async throws -> String {
        "ui-test-token"
    }
    func pressKey(_ key: TVKey, count: Int, timeout: Duration) async throws { }
    func setVolume(_ value: Double) async throws -> Int { Int(value.rounded()) }
    func typeText(_ value: String) async throws { }
    func ensureQuickStartPowerMode() async throws -> QuickStartResult {
        QuickStartResult(changed: false, value: "Quick Start")
    }
    func launchApp(_ configuration: AppLaunchConfiguration) async throws { }
}
#endif
