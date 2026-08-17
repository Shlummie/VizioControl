import Foundation
import XCTest
@testable import VizioControl

@MainActor
final class RemoteControllerTests: XCTestCase, @unchecked Sendable {
    private let endpoint = DeviceEndpoint(host: "192.168.50.42", resolvedAddresses: ["192.168.50.42"], interfaceIndex: 4)
    private let fingerprint = String(repeating: "AB", count: 32)

    func testInitializeClearsOrphanedMetadataButKeepsSettingsAndCommands() async throws {
        let command = savedCommand()
        let device = pairedDevice()
        let store = MemoryAppStore(StoreFile(
            settings: AppSettings(manualAddress: "tv.local", manualMACAddress: "A8:C9:6B:12:34:56"),
            device: device,
            commands: [command]
        ))
        let controller = RemoteController(
            store: store,
            keychain: MemoryTokenStore(),
            discovery: DiscoveryStub(),
            clientFactory: unusedFactory(),
            wakeSender: RecordingWakeSender()
        )

        await controller.initialize()
        let storedAfterInitialization = await store.snapshot()

        XCTAssertNil(controller.pairedDevice)
        XCTAssertEqual(controller.settings.manualAddress, "tv.local")
        XCTAssertEqual(controller.commands.map(\.id), [command.id])
        XCTAssertNil(storedAfterInitialization.device)
        XCTAssertEqual(controller.errorBanner, VizioControlError.pairingCredentialsUnavailable.localizedDescription)
    }

    func testPairingReprovesFingerprintAndCommitsTokenBeforeMetadata() async throws {
        let contact = RemoteClientFake(
            endpoint: endpoint,
            state: TVState(),
            deviceInfo: SCPLResponse(
                statusCode: 200,
                body: ["SERIAL_NUMBER": "SERIAL-A", "CAST_NAME": "Living Room"],
                leafFingerprint: fingerprint
            )
        )
        let paired = RemoteClientFake(
            endpoint: endpoint,
            state: TVState(connected: true, power: true, volume: 17, endpoint: endpoint),
            pairingToken: "secret-token"
        )
        let store = MemoryAppStore()
        let tokens = MemoryTokenStore()
        let controller = RemoteController(
            store: store,
            keychain: tokens,
            discovery: DiscoveryStub(),
            clientFactory: factory(firstContact: contact, pinned: paired),
            wakeSender: RecordingWakeSender()
        )

        try await controller.pairStart(candidate())
        let device = try await controller.pairFinish(pin: "2468")
        await controller.handleScenePhase(.background)
        let storedToken = try await tokens.read(account: device.deviceID)
        let storedPairing = await store.snapshot()
        let contactEvents = await contact.events()
        let pairedEvents = await paired.events()

        XCTAssertEqual(device.name, "Living Room")
        XCTAssertEqual(device.serial, "SERIAL-A")
        XCTAssertEqual(device.deviceID.count, 32)
        XCTAssertTrue(device.deviceID.allSatisfy(\.isHexDigit))
        XCTAssertEqual(storedToken, "secret-token")
        XCTAssertEqual(storedPairing.device, device)
        XCTAssertEqual(controller.tvState.volume, 17)
        XCTAssertEqual(contactEvents, ["deviceInfo"])
        XCTAssertEqual(Array(pairedEvents.prefix(2)), ["pairStart", "pairFinish"])
    }

    func testPairingRejectsFingerprintChangeBeforePINRequest() async {
        let contact = RemoteClientFake(
            endpoint: endpoint,
            state: TVState(),
            deviceInfo: SCPLResponse(
                statusCode: 200,
                body: ["SERIAL_NUMBER": "SERIAL-A"],
                leafFingerprint: String(repeating: "CD", count: 32)
            )
        )
        let paired = RemoteClientFake(endpoint: endpoint)
        let controller = RemoteController(
            store: MemoryAppStore(),
            keychain: MemoryTokenStore(),
            discovery: DiscoveryStub(),
            clientFactory: factory(firstContact: contact, pinned: paired),
            wakeSender: RecordingWakeSender()
        )

        await XCTAssertThrowsRemoteError(try await controller.pairStart(candidate())) { error in
            XCTAssertEqual(error as? VizioControlError, .fingerprintChanged)
        }
        let pairedEvents = await paired.events()
        XCTAssertNil(controller.pairing)
        XCTAssertEqual(pairedEvents, [])
    }

    func testPairingMetadataFailureRollsBackToken() async throws {
        let contact = RemoteClientFake(
            endpoint: endpoint,
            deviceInfo: SCPLResponse(statusCode: 200, body: ["SERIAL_NUMBER": "SERIAL-A"], leafFingerprint: fingerprint)
        )
        let paired = RemoteClientFake(endpoint: endpoint, pairingToken: "secret-token")
        let store = MemoryAppStore()
        await store.setFailDeviceWrites(true)
        let tokens = MemoryTokenStore()
        let controller = RemoteController(
            store: store,
            keychain: tokens,
            discovery: DiscoveryStub(),
            clientFactory: factory(firstContact: contact, pinned: paired),
            wakeSender: RecordingWakeSender()
        )

        try await controller.pairStart(candidate())
        let account = try XCTUnwrap(controller.pairing?.deviceID)
        await XCTAssertThrowsRemoteError(try await controller.pairFinish(pin: "1357"))
        let rolledBackToken = try await tokens.read(account: account)

        XCTAssertNil(rolledBackToken)
        XCTAssertNotNil(controller.pairing)
        XCTAssertNil(controller.pairedDevice)
    }

    func testRefreshCoalescesAndIdentitySafeRediscoveryRepairsEndpoint() async throws {
        let device = pairedDevice()
        let store = MemoryAppStore(StoreFile(device: device))
        let tokens = MemoryTokenStore([device.deviceID: "token"])
        let client = RemoteClientFake(endpoint: endpoint, state: TVState(connected: true, power: true, endpoint: endpoint))
        let gate = ContinuationGate()
        let newEndpoint = DeviceEndpoint(host: "192.168.50.99", resolvedAddresses: ["192.168.50.99"], interfaceIndex: 4)
        let matching = DeviceCandidate(
            id: "new-id",
            name: "Moved TV",
            endpoint: newEndpoint,
            model: "D50",
            serial: "SERIAL-A",
            fingerprint: fingerprint,
            macAddress: "11:22:33:44:55:66",
            source: .mdns
        )
        let wrong = DeviceCandidate(
            id: "wrong",
            name: "Other TV",
            endpoint: DeviceEndpoint(host: "192.168.50.77"),
            serial: "SERIAL-B",
            fingerprint: fingerprint,
            source: .mdns
        )
        let discovery = DiscoveryStub(results: [wrong, matching])
        let controller = RemoteController(
            store: store,
            keychain: tokens,
            discovery: discovery,
            clientFactory: { _, _, _, _ in client },
            wakeSender: RecordingWakeSender()
        )
        await controller.initialize()
        await controller.handleScenePhase(.background)
        await client.setStateSequence([
            TVState(connected: false, endpoint: endpoint, error: "offline"),
            TVState(connected: true, power: true, volume: 22, endpoint: newEndpoint)
        ])
        await client.setGetStateGate(gate)

        async let first = controller.refreshTVState()
        async let second = controller.refreshTVState()
        await gate.waitUntilEntered()
        await gate.release()
        let values = await [first, second]
        let stateCalls = await client.getStateCallCount()

        XCTAssertEqual(values[0], values[1])
        XCTAssertEqual(values[0].endpoint, newEndpoint)
        XCTAssertEqual(stateCalls, 3)
        XCTAssertEqual(controller.pairedDevice?.id, device.id)
        XCTAssertEqual(controller.pairedDevice?.endpoint, newEndpoint)
        XCTAssertEqual(controller.pairedDevice?.macAddress, device.macAddress, "Stored MAC wins over discovery metadata")
    }

    func testFastControlSkipsPreflightAndPublishesOptimisticVolume() async throws {
        let setup = await pairedController(state: TVState(
            connected: true,
            power: true,
            volume: 10,
            muted: true,
            endpoint: endpoint
        ))

        let state = try await setup.controller.press(.volumeUp, count: 2)
        await setup.controller.handleScenePhase(.background)
        let stateCalls = await setup.client.getStateCallCount()
        let keyEvents = await setup.client.events().filter { $0.hasPrefix("key:") }

        XCTAssertEqual(state.volume, 12)
        XCTAssertEqual(state.muted, false)
        XCTAssertEqual(stateCalls, 1)
        XCTAssertEqual(keyEvents, ["key:volumeUp:2"])
    }

    func testStandbyFailsClosedBeforePowerPacket() async throws {
        let setup = await pairedController(state: TVState(connected: true, power: true, endpoint: endpoint))
        await setup.client.setQuickStartError(.message("menu unavailable"))

        await XCTAssertThrowsRemoteError(try await setup.controller.press(.powerOff)) { error in
            XCTAssertEqual(error.localizedDescription, RemoteController.standbyFailureMessage)
        }
        XCTAssertEqual(setup.controller.tvState.power, true)
        await setup.client.setStateSequence([TVState(connected: true, power: nil, endpoint: endpoint)])
        _ = await setup.controller.refreshTVState()
        await XCTAssertThrowsRemoteError(try await setup.controller.press(.powerToggle)) { error in
            XCTAssertEqual(error.localizedDescription, RemoteController.standbyFailureMessage)
        }
        await setup.controller.handleScenePhase(.background)
        let keyEvents = await setup.client.events().filter { $0.hasPrefix("key:") }

        XCTAssertEqual(keyEvents, [])
        XCTAssertNil(setup.controller.tvState.power)
    }

    func testOfflineNonPowerNeverWakesButPowerUsesWakeAndAuthenticatedRetry() async throws {
        let clock = AdvancingClock()
        let setup = await pairedController(
            state: TVState(connected: false, endpoint: endpoint, error: "offline"),
            sleep: { duration in clock.advance(by: duration) },
            now: { clock.now() }
        )
        await setup.client.setPowerOnConnects(true)

        await XCTAssertThrowsRemoteError(try await setup.controller.press(.ok))
        let wakeCountBeforePower = await setup.wake.calls().count
        XCTAssertEqual(wakeCountBeforePower, 0)

        let state = try await setup.controller.press(.powerOn)
        await setup.controller.handleScenePhase(.background)
        let wakeCountAfterPower = await setup.wake.calls().count
        let clientEvents = await setup.client.events()

        XCTAssertEqual(wakeCountAfterPower, 1)
        XCTAssertEqual(state.power, true)
        XCTAssertTrue(clientEvents.contains("key:powerOn:1"))
    }

    func testWakeTimeoutIsBoundedAndUsesExactGuidance() async throws {
        let clock = AdvancingClock()
        let setup = await pairedController(
            state: TVState(connected: false, endpoint: endpoint, error: "offline"),
            sleep: { duration in clock.advance(by: duration) },
            now: { clock.now() }
        )

        await XCTAssertThrowsRemoteError(try await setup.controller.press(.powerOn)) { error in
            XCTAssertEqual(error.localizedDescription, RemoteController.wakeTimeoutMessage)
        }
        await setup.controller.handleScenePhase(.background)

        let retries = await setup.client.events().filter { $0 == "key:powerOn:1" }.count
        let wakeCount = await setup.wake.calls().count
        XCTAssertTrue((1...40).contains(retries))
        XCTAssertEqual(wakeCount, 1)
        XCTAssertEqual(setup.controller.errorBanner, RemoteController.wakeTimeoutMessage)
    }

    func testFailedCommandIsNotSavedAndSuccessfulReplayUpdatesUsage() async throws {
        let setup = await pairedController(state: TVState(connected: true, power: true, muted: false, endpoint: endpoint))
        await setup.client.setPressError(.message("packet failed"))

        await XCTAssertThrowsRemoteError(try await setup.controller.runLocalRequest("mute"))
        XCTAssertEqual(setup.controller.commands, [])

        await setup.client.setPressError(nil)
        let saved = try await setup.controller.runLocalRequest("mute")
        _ = try await setup.controller.runSavedCommand(id: saved.id)
        await setup.controller.handleScenePhase(.background)

        XCTAssertEqual(setup.controller.commands.count, 1)
        XCTAssertEqual(setup.controller.commands[0].usageCount, 2)
    }

    func testWakeMACSaveIsAtomicAcrossSettingsAndPairedDevice() async throws {
        let setup = await pairedController(state: TVState(connected: true, power: true, endpoint: endpoint))
        await setup.store.setFailAtomicWrites(true)

        await XCTAssertThrowsRemoteError(try await setup.controller.saveWakeMAC("12:22:33:44:55:66"))
        XCTAssertEqual(setup.controller.settings.manualMACAddress, "")
        XCTAssertEqual(setup.controller.pairedDevice?.macAddress, "A8:C9:6B:12:34:56")

        await setup.store.setFailAtomicWrites(false)
        try await setup.controller.saveWakeMAC("12-22-33-44-55-66")
        await setup.controller.handleScenePhase(.background)
        let stored = await setup.store.snapshot()

        XCTAssertEqual(setup.controller.settings.manualMACAddress, "12:22:33:44:55:66")
        XCTAssertEqual(setup.controller.pairedDevice?.macAddress, "12:22:33:44:55:66")
        XCTAssertEqual(stored.settings, setup.controller.settings)
        XCTAssertEqual(stored.device, setup.controller.pairedDevice)
    }

    func testPermissionPromptSurvivesInactiveAndActiveDoesNotDuplicateDiscovery() async throws {
        let gate = ContinuationGate()
        let discovery = DiscoveryStub(gate: gate, results: [candidate()])
        let controller = RemoteController(
            store: MemoryAppStore(),
            keychain: MemoryTokenStore(),
            discovery: discovery,
            clientFactory: unusedFactory(),
            wakeSender: RecordingWakeSender()
        )

        let scan = Task { await controller.discover() }
        await gate.waitUntilEntered()
        await controller.handleScenePhase(.inactive)
        XCTAssertTrue(controller.isDiscovering)
        XCTAssertEqual(controller.discoveryProgress, .waitingForPermission)
        await controller.handleScenePhase(.active)
        await gate.release()
        await scan.value
        let discoveryCalls = await discovery.callCount()

        XCTAssertEqual(discoveryCalls, 1)
        XCTAssertEqual(controller.candidates, [candidate()])
    }

    func testEmptyDiscoveryPublishesActionableError() async {
        let controller = RemoteController(
            store: MemoryAppStore(),
            keychain: MemoryTokenStore(),
            discovery: DiscoveryStub(),
            clientFactory: unusedFactory(),
            wakeSender: RecordingWakeSender()
        )

        await controller.discover()

        XCTAssertTrue(controller.candidates.isEmpty)
        XCTAssertEqual(controller.errorBanner, RemoteController.noTVsFoundMessage)
    }

    private func candidate() -> DeviceCandidate {
        DeviceCandidate(
            id: "candidate-a",
            name: "Vizio TV",
            endpoint: endpoint,
            model: "D50",
            serial: "SERIAL-A",
            fingerprint: fingerprint,
            macAddress: "A8:C9:6B:12:34:56",
            source: .mdns
        )
    }

    private func pairedDevice() -> PairedDevice {
        PairedDevice(
            id: "paired-a",
            name: "Living Room",
            endpoint: endpoint,
            model: "D50",
            serial: "SERIAL-A",
            fingerprint: fingerprint,
            macAddress: "A8:C9:6B:12:34:56",
            deviceID: "device-account",
            pairedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func savedCommand() -> SavedCommand {
        SavedCommand(
            label: "Mute",
            systemImage: "speaker.slash.fill",
            normalizedRequest: "mute",
            order: 0,
            usageCount: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            actions: [.key(.mute, count: 1)]
        )
    }

    private func factory(firstContact: RemoteClientFake, pinned: RemoteClientFake) -> SmartCastClientFactory {
        { _, mode, _, _ in mode == .firstContact ? firstContact : pinned }
    }

    private func unusedFactory() -> SmartCastClientFactory {
        { endpoint, _, _, _ in RemoteClientFake(endpoint: endpoint) }
    }

    private func pairedController(
        state: TVState,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await ContinuousClock().sleep(for: $0) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) async -> (
        controller: RemoteController,
        store: MemoryAppStore,
        client: RemoteClientFake,
        wake: RecordingWakeSender
    ) {
        let device = pairedDevice()
        let store = MemoryAppStore(StoreFile(device: device))
        let tokens = MemoryTokenStore([device.deviceID: "token"])
        let client = RemoteClientFake(endpoint: endpoint, state: state)
        let wake = RecordingWakeSender()
        let controller = RemoteController(
            store: store,
            keychain: tokens,
            discovery: DiscoveryStub(),
            clientFactory: { _, _, _, _ in client },
            wakeSender: wake,
            monotonicNow: now,
            sleep: sleep
        )
        await controller.initialize()
        await controller.handleScenePhase(.background)
        return (controller, store, client, wake)
    }
}

private actor RemoteClientFake: SmartCastControlling {
    let endpoint: DeviceEndpoint
    private var state: TVState
    private var stateSequence: [TVState] = []
    private var deviceInfo: SCPLResponse
    private var pairingToken: String
    private var log: [String] = []
    private var stateCalls = 0
    private var quickStartError: VizioControlError?
    private var pressError: VizioControlError?
    private var powerOnConnects = false
    private var getStateGate: ContinuationGate?

    init(
        endpoint: DeviceEndpoint,
        state: TVState = TVState(),
        deviceInfo: SCPLResponse = SCPLResponse(statusCode: 200, body: [:]),
        pairingToken: String = "token"
    ) {
        self.endpoint = endpoint
        self.state = state
        self.deviceInfo = deviceInfo
        self.pairingToken = pairingToken
    }

    func setToken(_ token: String?) {}
    func setExpectedSerial(_ serial: String?) {}

    func getDeviceInfo(timeout: Duration) async throws -> SCPLResponse {
        log.append("deviceInfo")
        return deviceInfo
    }

    func getState() async -> TVState {
        stateCalls += 1
        if let gate = getStateGate {
            getStateGate = nil
            await gate.enterAndWait()
        }
        if !stateSequence.isEmpty { state = stateSequence.removeFirst() }
        return state
    }

    func startPairing(deviceID: String) async throws -> Int {
        log.append("pairStart")
        return 7
    }

    func finishPairing(deviceID: String, requestToken: Int, pin: String) async throws -> String {
        log.append("pairFinish")
        return pairingToken
    }

    func pressKey(_ key: TVKey, count: Int, timeout: Duration) async throws {
        log.append("key:\(key.rawValue):\(count)")
        if let pressError { throw pressError }
        if key == .powerOn, powerOnConnects {
            state = TVState(connected: true, power: true, endpoint: endpoint)
        }
    }

    func setVolume(_ value: Double) async throws -> Int {
        log.append("volume:\(value)")
        let sent = min(100, max(0, Int(value.rounded())))
        state.volume = sent
        return sent
    }

    func typeText(_ value: String) async throws { log.append("text:\(value)") }

    func ensureQuickStartPowerMode() async throws -> QuickStartResult {
        log.append("quickStart")
        if let quickStartError { throw quickStartError }
        return QuickStartResult(changed: false, value: "Quick Start")
    }

    func launchApp(_ configuration: AppLaunchConfiguration) async throws {
        log.append("app:\(configuration.name)")
    }

    func setStateSequence(_ values: [TVState]) { stateSequence = values }
    func setGetStateGate(_ gate: ContinuationGate?) { getStateGate = gate }
    func setQuickStartError(_ error: VizioControlError?) { quickStartError = error }
    func setPressError(_ error: VizioControlError?) { pressError = error }
    func setPowerOnConnects(_ value: Bool) { powerOnConnects = value }
    func events() -> [String] { log }
    func getStateCallCount() -> Int { stateCalls }
}

private actor MemoryAppStore: AppStoring {
    private var data: StoreFile
    private var deleted: SavedCommand?
    private var failDeviceWrites = false
    private var failAtomicWrites = false

    init(_ data: StoreFile = StoreFile()) { self.data = data }

    func load() throws -> StoreFile { snapshot() }
    func snapshot() -> StoreFile { data }
    func updateSettings(_ settings: AppSettings) throws -> AppSettings {
        data.settings = settings
        return settings
    }
    func updateSettingsAndDevice(settings: AppSettings, device: PairedDevice?) throws {
        if failAtomicWrites { throw VizioControlError.message("disk full") }
        data.settings = settings
        data.device = device
    }
    func setDevice(_ device: PairedDevice?) throws {
        if failDeviceWrites { throw VizioControlError.message("disk full") }
        data.device = device
    }
    func command(id: UUID) -> SavedCommand? { data.commands.first { $0.id == id } }
    func commands() -> [SavedCommand] { data.commands.sorted { $0.order < $1.order } }
    func upsertCommand(_ command: SavedCommand) throws -> [SavedCommand] {
        if let index = data.commands.firstIndex(where: { $0.id == command.id || $0.normalizedRequest == command.normalizedRequest }) {
            var updated = command
            updated.id = data.commands[index].id
            updated.order = data.commands[index].order
            updated.createdAt = data.commands[index].createdAt
            updated.usageCount = data.commands[index].usageCount + 1
            data.commands[index] = updated
        } else {
            var inserted = command
            inserted.order = data.commands.count
            inserted.usageCount = 1
            data.commands.append(inserted)
        }
        return commands()
    }
    func editCommand(id: UUID, label: String, updatedAt: Date) throws -> [SavedCommand] {
        guard let index = data.commands.firstIndex(where: { $0.id == id }) else { throw VizioControlError.message("missing") }
        data.commands[index].label = label
        data.commands[index].updatedAt = updatedAt
        return commands()
    }
    func duplicateCommand(id: UUID, at date: Date) throws -> [SavedCommand] {
        guard var copy = data.commands.first(where: { $0.id == id }) else { throw VizioControlError.message("missing") }
        copy.id = UUID()
        copy.label += " copy"
        copy.normalizedRequest += "-copy-\(copy.id)"
        copy.order = data.commands.count
        copy.createdAt = date
        copy.updatedAt = date
        data.commands.append(copy)
        return commands()
    }
    func deleteCommand(id: UUID) throws -> [SavedCommand] {
        guard let index = data.commands.firstIndex(where: { $0.id == id }) else { return commands() }
        deleted = data.commands.remove(at: index)
        normalizeOrders()
        return commands()
    }
    func undoDelete() throws -> [SavedCommand] {
        if var deleted {
            deleted.order = min(deleted.order, data.commands.count)
            data.commands.insert(deleted, at: deleted.order)
            self.deleted = nil
            normalizeOrders()
        }
        return commands()
    }
    func reorderCommand(id: UUID, direction: Int) throws -> [SavedCommand] {
        guard let index = data.commands.firstIndex(where: { $0.id == id }) else { return commands() }
        let target = index + direction
        guard data.commands.indices.contains(target) else { return commands() }
        data.commands.swapAt(index, target)
        normalizeOrders()
        return commands()
    }
    func setFailDeviceWrites(_ value: Bool) { failDeviceWrites = value }
    func setFailAtomicWrites(_ value: Bool) { failAtomicWrites = value }
    private func normalizeOrders() {
        for index in data.commands.indices { data.commands[index].order = index }
    }
}

private actor MemoryTokenStore: TokenStoring {
    private var values: [String: String]
    init(_ values: [String: String] = [:]) { self.values = values }
    func save(_ token: String, account: String) throws { values[account] = token }
    func read(account: String) throws -> String? { values[account] }
    func delete(account: String) throws { values[account] = nil }
    func deleteAll() throws { values = [:] }
}

private final class DiscoveryStub: DeviceDiscovering, @unchecked Sendable {
    private let gate: ContinuationGate?
    private let results: [DeviceCandidate]
    private let lock = NSLock()
    private var calls = 0

    init(gate: ContinuationGate? = nil, results: [DeviceCandidate] = []) {
        self.gate = gate
        self.results = results
    }

    func discover(
        cached: PairedDevice?,
        manualEndpoint: String,
        manualMAC: String,
        onProgress: @escaping @Sendable (DiscoveryProgress) -> Void
    ) async throws -> [DeviceCandidate] {
        lock.withLock { calls += 1 }
        if let gate { await gate.enterAndWait() }
        try Task.checkCancellation()
        return results
    }

    func cancel() {}
    func handleSceneActivity(_ activity: AppSceneActivity) {}
    func callCount() async -> Int { lock.withLock { calls } }
}

private actor RecordingWakeSender: WakeOnLANSending {
    struct Call: Sendable { let mac: String; let addresses: [String] }
    private var recorded: [Call] = []
    func wake(macAddress: String, cachedAddresses: [String]) async throws {
        recorded.append(Call(mac: macAddress, addresses: cachedAddresses))
    }
    func calls() -> [Call] { recorded }
}

private actor ContinuationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters = []
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}

private final class AdvancingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now
    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance(by duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

@MainActor
private func XCTAssertThrowsRemoteError<T: Sendable>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
