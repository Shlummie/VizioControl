import Foundation
import XCTest
@testable import VizioControl

@MainActor
final class RemoteControllerTests: XCTestCase, @unchecked Sendable {
    private let endpoint = DeviceEndpoint(host: "192.168.50.42", resolvedAddresses: ["192.168.50.42"], interfaceIndex: 4)
    private let fingerprint = String(repeating: "AB", count: 32)

    func testInitializeClearsOrphanedMetadataButKeepsSettingsAndMacros() async throws {
        let macro = savedMacro()
        let device = pairedDevice()
        let store = MemoryAppStore(StoreFile(
            settings: AppSettings(manualAddress: "tv.local", manualMACAddress: "A8:C9:6B:12:34:56"),
            device: device,
            macros: [macro]
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
        XCTAssertEqual(controller.macros.map(\.id), [macro.id])
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

    func testCreateAndUpdateMacroValidateWithoutControllingTV() async throws {
        let setup = await pairedController(
            state: TVState(connected: true, power: true, muted: false, endpoint: endpoint)
        )

        let saved = try await setup.controller.createMacro(
            name: "  Movie night  ",
            actions: [.key(.up, count: 1), .launchApp("youtube")]
        )
        let eventsAfterCreate = await setup.client.events()

        XCTAssertEqual(saved.name, "Movie night")
        XCTAssertEqual(saved.actions, [.key(.up, count: 1), .launchApp("YouTube")])
        XCTAssertEqual(saved.usageCount, 0)
        XCTAssertTrue(eventsAfterCreate.isEmpty)

        let updated = try await setup.controller.updateMacro(
            id: saved.id,
            name: "Intermission",
            actions: [.wait(milliseconds: 500), .setVolume(20)]
        )
        let eventsAfterUpdate = await setup.client.events()

        XCTAssertEqual(updated.id, saved.id)
        XCTAssertEqual(updated.name, "Intermission")
        XCTAssertEqual(updated.actions, [.wait(milliseconds: 500), .setVolume(20)])
        XCTAssertEqual(updated.order, saved.order)
        XCTAssertEqual(updated.createdAt, saved.createdAt)
        XCTAssertEqual(updated.usageCount, 0)
        XCTAssertTrue(eventsAfterUpdate.isEmpty)

        await XCTAssertThrowsRemoteError(
            try await setup.controller.updateMacro(id: saved.id, name: " ", actions: updated.actions)
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Macro name cannot be empty.")
        }
        XCTAssertEqual(setup.controller.macros, [updated])
    }

    func testDraftTestControlsTVWithoutSavingOrIncrementingUsage() async throws {
        let waitGate = ContinuationGate()
        let setup = await pairedController(
            state: TVState(connected: true, power: true, muted: false, endpoint: endpoint),
            sleep: { _ in await waitGate.enterAndWait() }
        )
        let saved = try await setup.controller.createMacro(
            name: "Saved",
            actions: [.key(.left, count: 1)]
        )

        let draftTest = Task { @MainActor in
            try await setup.controller.testMacro(
                name: "  Draft  ",
                actions: [
                    .key(.ok, count: 1),
                    .wait(milliseconds: 500),
                    .launchApp("netflix"),
                ]
            )
        }
        await waitGate.waitUntilEntered()
        XCTAssertEqual(
            setup.controller.macroRunProgress,
            MacroRunProgress(
                macroID: nil,
                name: "Draft",
                currentStep: 2,
                totalSteps: 3,
                action: .wait(milliseconds: 500)
            )
        )
        await waitGate.release()
        try await draftTest.value
        await setup.controller.handleScenePhase(.background)
        let events = await setup.client.events()

        XCTAssertEqual(events, ["key:ok:1", "app:Netflix"])
        XCTAssertEqual(setup.controller.macros, [saved])
        XCTAssertEqual(setup.controller.macros[0].usageCount, 0)
        XCTAssertEqual(setup.controller.successStatus, "Draft test completed.")
        XCTAssertNil(setup.controller.macroRunProgress)
    }

    func testMacroReplayWaitsInOrderRejectsInterleavingAndCountsCompletedRun() async throws {
        let waitGate = ContinuationGate()
        let setup = await pairedController(
            state: TVState(connected: true, power: true, endpoint: endpoint),
            sleep: { _ in await waitGate.enterAndWait() }
        )
        let saved = try await setup.controller.createMacro(
            name: "Ordered",
            actions: [
                .key(.up, count: 1),
                .wait(milliseconds: 500),
                .launchApp("Netflix"),
            ]
        )

        let replay = Task { @MainActor in
            try await setup.controller.runMacro(id: saved.id)
        }
        await waitGate.waitUntilEntered()
        let eventsBeforeWaitRelease = await setup.client.events()

        XCTAssertEqual(eventsBeforeWaitRelease, ["key:up:1"])
        XCTAssertTrue(setup.controller.isRunningMacro)
        XCTAssertEqual(
            setup.controller.macroRunProgress,
            MacroRunProgress(
                macroID: saved.id,
                name: "Ordered",
                currentStep: 2,
                totalSteps: 3,
                action: .wait(milliseconds: 500)
            )
        )
        await XCTAssertThrowsRemoteError(try await setup.controller.press(.left)) { error in
            XCTAssertEqual(error.localizedDescription, "Wait for the running macro to finish.")
        }
        await XCTAssertThrowsRemoteError(try await setup.controller.runMacro(id: saved.id)) { error in
            XCTAssertEqual(error.localizedDescription, "Another macro is already running.")
        }

        await waitGate.release()
        let completed = try await replay.value
        await setup.controller.handleScenePhase(.background)
        let completedEvents = await setup.client.events()

        XCTAssertEqual(completedEvents, ["key:up:1", "app:Netflix"])
        XCTAssertEqual(completed.usageCount, 1)
        XCTAssertEqual(setup.controller.macros[0].usageCount, 1)
        XCTAssertFalse(setup.controller.isRunningMacro)
        XCTAssertNil(setup.controller.macroRunProgress)
    }

    func testFailedMacroReplayStopsAtFirstErrorWithoutIncrementingUsage() async throws {
        let setup = await pairedController(
            state: TVState(connected: true, power: true, volume: 10, endpoint: endpoint)
        )
        let saved = try await setup.controller.createMacro(
            name: "Failure",
            actions: [.key(.up, count: 1), .key(.right, count: 1), .key(.left, count: 1)]
        )
        await setup.client.setPressError(.message("packet failed"), for: .right)

        await XCTAssertThrowsRemoteError(try await setup.controller.runMacro(id: saved.id)) { error in
            XCTAssertEqual(error.localizedDescription, "packet failed")
        }
        await setup.controller.handleScenePhase(.background)
        let events = await setup.client.events()

        XCTAssertEqual(events, ["key:up:1", "key:right:1"])
        XCTAssertEqual(setup.controller.macros[0].usageCount, 0)
        XCTAssertFalse(setup.controller.isRunningMacro)
        XCTAssertNil(setup.controller.macroRunProgress)
    }

    func testBackgroundCancellationStopsRemainingMacroStepsAndUsageAccounting() async throws {
        let waitGate = ContinuationGate()
        let setup = await pairedController(
            state: TVState(connected: true, power: true, endpoint: endpoint),
            sleep: { _ in await waitGate.enterAndWait() }
        )
        let saved = try await setup.controller.createMacro(
            name: "Cancelled",
            actions: [
                .key(.up, count: 1),
                .wait(milliseconds: 500),
                .key(.right, count: 1),
            ]
        )
        let replay = Task { @MainActor in
            try await setup.controller.runMacro(id: saved.id)
        }
        await waitGate.waitUntilEntered()
        XCTAssertEqual(setup.controller.macroRunProgress?.currentStep, 2)

        await setup.controller.handleScenePhase(.background)
        await waitGate.release()
        do {
            _ = try await replay.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let events = await setup.client.events()

        XCTAssertEqual(events, ["key:up:1"])
        XCTAssertEqual(setup.controller.macros[0].usageCount, 0)
        XCTAssertFalse(setup.controller.isRunningMacro)
        XCTAssertNil(setup.controller.macroRunProgress)
    }

    func testForegroundCancellationStopsBeforeNextStepAndClearsProgress() async throws {
        let waitGate = ContinuationGate()
        let setup = await pairedController(
            state: TVState(connected: true, power: true, endpoint: endpoint),
            sleep: { _ in await waitGate.enterAndWait() }
        )
        let saved = try await setup.controller.createMacro(
            name: "Cancel me",
            actions: [
                .key(.up, count: 1),
                .wait(milliseconds: 2_000),
                .key(.right, count: 1),
            ]
        )
        let replay = Task { @MainActor in
            try await setup.controller.runMacro(id: saved.id)
        }
        await waitGate.waitUntilEntered()

        XCTAssertEqual(
            setup.controller.macroRunProgress,
            MacroRunProgress(
                macroID: saved.id,
                name: "Cancel me",
                currentStep: 2,
                totalSteps: 3,
                action: .wait(milliseconds: 2_000)
            )
        )
        setup.controller.cancelMacro()
        await waitGate.release()

        do {
            _ = try await replay.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let events = await setup.client.events()
        XCTAssertEqual(events, ["key:up:1"])
        XCTAssertEqual(setup.controller.macros[0].usageCount, 0)
        XCTAssertFalse(setup.controller.isRunningMacro)
        XCTAssertNil(setup.controller.macroRunProgress)
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

    private func savedMacro() -> SavedMacro {
        SavedMacro(
            name: "Mute",
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
    private var failingKey: TVKey?
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
        if let pressError, failingKey == nil || failingKey == key { throw pressError }
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
    func setPressError(_ error: VizioControlError?, for key: TVKey? = nil) {
        pressError = error
        failingKey = key
    }
    func setPowerOnConnects(_ value: Bool) { powerOnConnects = value }
    func events() -> [String] { log }
    func getStateCallCount() -> Int { stateCalls }
}

private actor MemoryAppStore: AppStoring {
    private var data: StoreFile
    private var deletedMacro: SavedMacro?
    private var failDeviceWrites = false
    private var failAtomicWrites = false

    init(_ data: StoreFile = StoreFile()) { self.data = data }

    func load() throws -> StoreFile { snapshot() }
    func snapshot() -> StoreFile {
        var snapshot = data
        snapshot.macros = orderedMacros()
        return snapshot
    }
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
    func macros() -> [SavedMacro] { orderedMacros() }
    func insertMacro(_ macro: SavedMacro) throws -> [SavedMacro] {
        guard !data.macros.contains(where: { $0.id == macro.id }) else {
            throw VizioControlError.message("Macro already exists.")
        }
        var inserted = macro
        inserted.order = data.macros.count
        inserted.usageCount = 0
        data.macros.append(inserted)
        normalizeOrders()
        return orderedMacros()
    }
    func updateMacro(
        id: UUID,
        name: String,
        actions: [TVAction],
        updatedAt: Date
    ) throws -> [SavedMacro] {
        guard let index = data.macros.firstIndex(where: { $0.id == id }) else {
            throw VizioControlError.message("Saved macro not found.")
        }
        data.macros[index].name = name
        data.macros[index].actions = actions
        data.macros[index].updatedAt = updatedAt
        return orderedMacros()
    }
    func recordMacroRun(id: UUID, at date: Date) throws -> [SavedMacro] {
        guard let index = data.macros.firstIndex(where: { $0.id == id }) else {
            throw VizioControlError.message("Saved macro not found.")
        }
        data.macros[index].usageCount += 1
        data.macros[index].updatedAt = date
        return orderedMacros()
    }
    func duplicateMacro(id: UUID, at date: Date) throws -> [SavedMacro] {
        guard let source = data.macros.first(where: { $0.id == id }) else {
            throw VizioControlError.message("Saved macro not found.")
        }
        let suffix = " copy"
        let copy = SavedMacro(
            name: String(source.name.prefix(40 - suffix.count)) + suffix,
            order: data.macros.count,
            usageCount: 0,
            createdAt: date,
            updatedAt: date,
            actions: source.actions
        )
        data.macros.append(copy)
        normalizeOrders()
        return orderedMacros()
    }
    func deleteMacro(id: UUID) throws -> [SavedMacro] {
        guard let index = data.macros.firstIndex(where: { $0.id == id }) else {
            return orderedMacros()
        }
        deletedMacro = data.macros.remove(at: index)
        normalizeOrders()
        return orderedMacros()
    }
    func undoDeleteMacro() throws -> [SavedMacro] {
        if var deletedMacro {
            deletedMacro.order = min(deletedMacro.order, data.macros.count)
            data.macros.insert(deletedMacro, at: deletedMacro.order)
            self.deletedMacro = nil
            normalizeOrders()
        }
        return orderedMacros()
    }
    func reorderMacro(id: UUID, direction: Int) throws -> [SavedMacro] {
        var ordered = orderedMacros()
        guard let index = ordered.firstIndex(where: { $0.id == id }) else {
            throw VizioControlError.message("Saved macro not found.")
        }
        let target = index + direction
        guard ordered.indices.contains(target) else { return ordered }
        ordered.swapAt(index, target)
        data.macros = ordered
        normalizeOrders()
        return orderedMacros()
    }
    func setFailDeviceWrites(_ value: Bool) { failDeviceWrites = value }
    func setFailAtomicWrites(_ value: Bool) { failAtomicWrites = value }
    private func orderedMacros() -> [SavedMacro] {
        data.macros.sorted { $0.order < $1.order }
    }
    private func normalizeOrders() {
        data.macros = orderedMacros()
        for index in data.macros.indices { data.macros[index].order = index }
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
