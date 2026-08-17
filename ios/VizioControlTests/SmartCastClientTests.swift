import XCTest
@testable import VizioControl

final class SmartCastClientTests: XCTestCase, @unchecked Sendable {
    private let endpoint = DeviceEndpoint(host: "192.168.50.42", resolvedAddresses: ["192.168.50.42"])

    func testVerifiedKeyMapAndPayloads() {
        let expected: [TVKey: (Int, Int)] = [
            .powerOff: (11, 0), .powerOn: (11, 1), .powerToggle: (11, 2),
            .volumeDown: (5, 0), .volumeUp: (5, 1), .mute: (5, 4),
            .input: (7, 1), .down: (3, 0), .left: (3, 1), .ok: (3, 2),
            .right: (3, 7), .up: (3, 8), .back: (4, 0), .home: (4, 3),
            .menu: (4, 8), .exit: (9, 0), .fastForward: (2, 0),
            .rewind: (2, 1), .pause: (2, 2), .play: (2, 3)
        ]
        XCTAssertEqual(smartCastKeyCodes.count, expected.count)
        for (key, value) in expected {
            XCTAssertEqual(smartCastKeyCodes[key]?.codeset, value.0)
            XCTAssertEqual(smartCastKeyCodes[key]?.code, value.1)
        }
        XCTAssertEqual(keyPayload(.home), [
            "KEYLIST": [["CODESET": 4, "CODE": 3, "ACTION": "KEYPRESS"]]
        ])
        XCTAssertEqual(keyPayload(.down, count: 2), [
            "KEYLIST": [
                ["CODESET": 3, "CODE": 0, "ACTION": "KEYPRESS"],
                ["CODESET": 3, "CODE": 0, "ACTION": "KEYPRESS"]
            ]
        ])
        XCTAssertEqual(flatVolumePayload(101), ["LEVEL": 100])
        XCTAssertEqual(textPayload("Hi"), [
            "KEYLIST": [
                ["CODESET": 0, "CODE": 72, "ACTION": "KEYPRESS"],
                ["CODESET": 0, "CODE": 105, "ACTION": "KEYPRESS"]
            ]
        ])
    }

    func testPairingPayloadsAndUnauthenticatedPaths() async throws {
        let transport = RecordingSmartCastTransport(responses: [
            success(["ITEM": ["PAIRING_REQ_TOKEN": 42]]),
            success(["ITEM": ["AUTH_TOKEN": "secret-token"]])
        ])
        let client = SmartCastClient(endpoint: endpoint, transport: transport)

        let requestToken = try await client.startPairing(deviceID: "device-1")
        let token = try await client.finishPairing(deviceID: "device-1", requestToken: requestToken, pin: "1234")

        XCTAssertEqual(requestToken, 42)
        XCTAssertEqual(token, "secret-token")
        let records = await transport.recorded()
        XCTAssertEqual(records.map(\.request.path), ["/pairing/start", "/pairing/pair"])
        XCTAssertEqual(records.map(\.request.authenticated), [false, false])
        XCTAssertEqual(records[0].request.body, ["DEVICE_ID": "device-1", "DEVICE_NAME": "VizioControl"])
        XCTAssertEqual(records[1].request.body, [
            "DEVICE_ID": "device-1",
            "CHALLENGE_TYPE": 1,
            "RESPONSE_VALUE": "1234",
            "PAIRING_REQ_TOKEN": 42
        ])
        XCTAssertNil(records[0].token)
        XCTAssertNil(records[1].token)
    }

    func testNestedIdentityAndEveryPowerShape() async throws {
        let identity: JSONValue = [
            "ITEMS": [[
                "CNAME": "deviceInfo",
                "ITEMS": [
                    ["CNAME": "modelName", "VALUE": "TEST-MODEL"],
                    ["CNAME": "serialNumber", "VALUE": "SERIAL-1"],
                    ["CNAME": "deviceinfo", "VALUE": ["CAST_NAME": "Living Room TV"]]
                ]
            ]]
        ]
        XCTAssertEqual(
            parseDeviceInfo(identity),
            ParsedDeviceInfo(model: "TEST-MODEL", serial: "SERIAL-1", name: "Living Room TV")
        )

        let shapes: [JSONValue] = [
            ["ITEMS": [["CNAME": "power_mode", "VALUE": 1]]],
            ["ITEM": ["VALUE": 1]],
            ["ITEMS": [["VALUE": 1]]],
            ["VALUE": 1]
        ]
        for shape in shapes {
            let transport = RecordingSmartCastTransport(responses: [success(shape)])
            let client = SmartCastClient(endpoint: endpoint, transport: transport)
            let power = try await client.getPower()
            XCTAssertTrue(power)
        }
    }

    func testAuthenticatedReadsAndAppNamingFallbacks() async throws {
        let secondaryState: JSONValue = [
            "ITEMS": [
                ["CNAME": "volume", "VALUE": 37],
                ["CNAME": "mute", "VALUE": "On"]
            ],
            "ITEM": ["VALUE": ["APP_ID": "1", "NAME_SPACE": 5, "MESSAGE": ""]]
        ]
        let transport = RecordingSmartCastTransport(responses: [
            success(["ITEMS": [["CNAME": "power_mode", "VALUE": 1]]]),
            success(secondaryState),
            success(secondaryState)
        ])
        let client = SmartCastClient(endpoint: endpoint, transport: transport, token: "test-token")

        let state = await client.getState()

        XCTAssertEqual(state.volume, 37)
        XCTAssertEqual(state.muted, true)
        XCTAssertEqual(state.currentApp, "YouTube")
        let records = await transport.recorded()
        XCTAssertEqual(Set(records.dropFirst().map(\.request.path)), Set([
            "/menu_native/dynamic/tv_settings/audio", "/app/current"
        ]))
        XCTAssertTrue(records.dropFirst().allSatisfy { $0.token == "test-token" })
        XCTAssertEqual(appNameFromIdentity(appID: "3", namespace: 2), "Hulu")
        XCTAssertEqual(appNameFromIdentity(appID: "1", namespace: 3), "Netflix")
        XCTAssertEqual(appNameFromIdentity(appID: "1", namespace: 4), "Prime Video")
    }

    @MainActor
    func testKeyBatchingAndPowerOrderingBarrier() async throws {
        let transport = BlockingSmartCastTransport()
        let client = SmartCastClient(endpoint: endpoint, transport: transport, token: "test-token")

        let right = Task { try await client.pressKey(.right) }
        await transport.waitForRequestCount(1)
        let down = Task { try await client.pressKey(.down) }
        try await Task.sleep(for: .milliseconds(1))
        let left = Task { try await client.pressKey(.left) }
        try await Task.sleep(for: .milliseconds(1))
        let ok = Task { try await client.pressKey(.ok) }
        try await Task.sleep(for: .milliseconds(1))
        await transport.releaseFirst()
        _ = try await [right.value, down.value, left.value, ok.value]

        let batched = await transport.recorded()
        XCTAssertEqual(batched.count, 2)
        XCTAssertEqual(batched[1].request.body, keySequencePayload([.down, .left, .ok]))

        let barrierTransport = BlockingSmartCastTransport()
        let barrierClient = SmartCastClient(endpoint: endpoint, transport: barrierTransport, token: "test-token")
        let first = Task { try await barrierClient.pressKey(.right) }
        await barrierTransport.waitForRequestCount(1)
        let power = Task { try await barrierClient.pressKey(.powerOff) }
        try await Task.sleep(for: .milliseconds(1))
        let last = Task { try await barrierClient.pressKey(.left) }
        try await Task.sleep(for: .milliseconds(1))
        await barrierTransport.releaseFirst()
        _ = try await [first.value, power.value, last.value]

        let ordered = await barrierTransport.recorded()
        XCTAssertEqual(ordered.map(\.request.body), [
            keyPayload(.right), keyPayload(.powerOff), keyPayload(.left)
        ])
    }

    @MainActor
    func testVolumeCoalescingReturnsTransmittedValues() async throws {
        let transport = BlockingSmartCastTransport()
        let client = SmartCastClient(endpoint: endpoint, transport: transport, token: "test-token")

        let volume20 = Task { try await client.setVolume(20) }
        await transport.waitForRequestCount(1)
        let volume35 = Task { try await client.setVolume(35) }
        try await Task.sleep(for: .milliseconds(1))
        let volume48 = Task { try await client.setVolume(48) }
        try await Task.sleep(for: .milliseconds(1))
        await transport.releaseFirst()

        let transmitted = try await [volume20.value, volume35.value, volume48.value]
        XCTAssertEqual(transmitted, [20, 48, 48])
        let records = await transport.recorded()
        XCTAssertEqual(records.map(\.request.body), [["LEVEL": 20], ["LEVEL": 48]])
    }

    func testVolumeFallbackOnlyForUnsupportedEndpoint() async throws {
        let transport = RecordingSmartCastTransport(responses: [
            SCPLResponse(statusCode: 404, body: ["STATUS": ["RESULT": "URI_NOT_FOUND"]]),
            success(["ITEMS": [["CNAME": "volume", "VALUE": 20, "HASHVAL": 4_168_459_545]]]),
            success()
        ])
        let client = SmartCastClient(endpoint: endpoint, transport: transport, token: "test-token")

        let value = try await client.setVolume(101)

        XCTAssertEqual(value, 100)
        let records = await transport.recorded()
        XCTAssertEqual(records.map(\.request.path), [
            "/audio/volume/level",
            "/menu_native/dynamic/tv_settings/audio/volume",
            "/menu_native/dynamic/tv_settings/audio/volume"
        ])
        XCTAssertEqual(records.last?.request.body, [
            "REQUEST": "MODIFY", "HASHVAL": 4_168_459_545, "VALUE": 100
        ])
    }

    func testQuickStartUnchangedChangedAndFailClosed() async throws {
        let unchangedTransport = RecordingSmartCastTransport(responses: [success([
            "ITEMS": [["CNAME": "power_mode", "VALUE": "Quick Start", "HASHVAL": 9001]]
        ])])
        let unchangedClient = SmartCastClient(endpoint: endpoint, transport: unchangedTransport, token: "token")
        let unchanged = try await unchangedClient.ensureQuickStartPowerMode()
        XCTAssertEqual(unchanged, QuickStartResult(changed: false, value: "Quick Start"))
        let unchangedRequestCount = await unchangedTransport.recorded().count
        XCTAssertEqual(unchangedRequestCount, 1)

        let changedTransport = RecordingSmartCastTransport(responses: [
            success(["ITEMS": [[
                "CNAME": "power_mode", "VALUE": "Eco Mode", "HASHVAL": 9002,
                "ELEMENTS": ["Eco Mode", "Quick Start"]
            ]]]),
            success(),
            success(["ITEMS": [["CNAME": "power_mode", "VALUE": "Quick Start", "HASHVAL": 9003]]])
        ])
        let changedClient = SmartCastClient(endpoint: endpoint, transport: changedTransport, token: "token")
        let changed = try await changedClient.ensureQuickStartPowerMode()
        XCTAssertEqual(changed, QuickStartResult(changed: true, value: "Quick Start"))
        let changedRequests = await changedTransport.recorded()
        XCTAssertEqual(changedRequests.map(\.request.path), [
            "/menu_native/dynamic/tv_settings/system",
            "/menu_native/dynamic/tv_settings/system/power_mode",
            "/menu_native/dynamic/tv_settings/system"
        ])
        XCTAssertEqual(changedRequests[1].request.body, [
            "REQUEST": "MODIFY", "HASHVAL": 9002, "VALUE": "Quick Start"
        ])

        let failedTransport = RecordingSmartCastTransport(responses: [
            success(["ITEMS": [["CNAME": "power_mode", "VALUE": "Eco Mode", "HASHVAL": 9004]]]),
            success(),
            success(["ITEMS": [["CNAME": "power_mode", "VALUE": "Eco Mode", "HASHVAL": 9005]]])
        ])
        let failedClient = SmartCastClient(endpoint: endpoint, transport: failedTransport, token: "token")
        await XCTAssertThrowsErrorAsync(try await failedClient.ensureQuickStartPowerMode()) { error in
            XCTAssertEqual(error.localizedDescription, "TV did not confirm Quick Start Power Mode.")
        }
    }

    func testQuickStartRejectsUnknownAndReadOnlyModes() async {
        let unknown = RecordingSmartCastTransport(responses: [success([
            "ITEMS": [["CNAME": "power_mode", "VALUE": "Custom Mode", "HASHVAL": 1]]
        ])])
        let unknownClient = SmartCastClient(endpoint: endpoint, transport: unknown, token: "token")
        await XCTAssertThrowsErrorAsync(try await unknownClient.ensureQuickStartPowerMode()) { error in
            XCTAssertTrue(error.localizedDescription.contains("unrecognized Power Mode"))
        }

        let readOnly = RecordingSmartCastTransport(responses: [success([
            "ITEMS": [["CNAME": "power_mode", "VALUE": "Eco Mode", "HASHVAL": 1, "READONLY": "TRUE"]]
        ])])
        let readOnlyClient = SmartCastClient(endpoint: endpoint, transport: readOnly, token: "token")
        await XCTAssertThrowsErrorAsync(try await readOnlyClient.ensureQuickStartPowerMode()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Power Mode is read-only"))
        }
    }

    func testPairedSerialMismatchStopsBeforePowerRead() async {
        let transport = RecordingSmartCastTransport(responses: [success([
            "ITEMS": [["VALUE": ["MODEL_NAME": "MODEL-2", "SERIAL_NUMBER": "SERIAL-2"]]]
        ])])
        let client = SmartCastClient(
            endpoint: endpoint,
            transport: transport,
            expectedSerial: "SERIAL-1"
        )

        let state = await client.getState()

        XCTAssertFalse(state.connected)
        XCTAssertEqual(state.error, "The TV at this address is not the paired TV. Rediscovering the verified TV.")
        let paths = await transport.recorded().map(\.request.path)
        XCTAssertEqual(paths, ["/state/device/deviceinfo"])
    }

    func testTextTruncatesThenRejectsUnicode() async throws {
        let transport = RecordingSmartCastTransport()
        let client = SmartCastClient(endpoint: endpoint, transport: transport, token: "token")
        try await client.typeText(String(repeating: "a", count: 121))
        let body = await transport.recorded().first?.request.body
        XCTAssertEqual(body?["KEYLIST"]?.arrayValue?.count, 120)

        await XCTAssertThrowsErrorAsync(try await client.typeText("café")) { error in
            XCTAssertEqual(error.localizedDescription, "Text entry accepts 1–120 ASCII characters.")
        }
        let requestCount = await transport.recorded().count
        XCTAssertEqual(requestCount, 1)
    }

    func testExactErrorMappingAndMissingAuthentication() async {
        let missingClient = SmartCastClient(endpoint: endpoint, transport: RecordingSmartCastTransport())
        await XCTAssertThrowsErrorAsync(try await missingClient.pressKey(.ok)) { error in
            XCTAssertEqual(error.localizedDescription, "Pair TV before sending controls.")
        }

        let failedTransport = RecordingSmartCastTransport(responses: [
            SCPLResponse(statusCode: 200, body: ["STATUS": ["RESULT": "FAILURE", "DETAIL": "Nope"]])
        ])
        let failedClient = SmartCastClient(endpoint: endpoint, transport: failedTransport, token: "token")
        await XCTAssertThrowsErrorAsync(try await failedClient.pressKey(.ok)) { error in
            XCTAssertEqual(error.localizedDescription, "Nope")
            XCTAssertEqual((error as? SmartCastRequestError)?.result, "FAILURE")
            XCTAssertEqual((error as? SmartCastRequestError)?.statusCode, 200)
        }
    }
}

private struct RecordedSCPLRequest: Sendable {
    let request: SCPLRequest
    let token: String?
}

private actor RecordingSmartCastTransport: SmartCastTransport {
    private var responses: [SCPLResponse]
    private var records: [RecordedSCPLRequest] = []

    init(responses: [SCPLResponse] = []) {
        self.responses = responses
    }

    func send(_ request: SCPLRequest, token: String?) async throws -> SCPLResponse {
        records.append(RecordedSCPLRequest(request: request, token: token))
        if responses.isEmpty { return success() }
        return responses.removeFirst()
    }

    func recorded() -> [RecordedSCPLRequest] {
        records
    }
}

private actor BlockingSmartCastTransport: SmartCastTransport {
    private var records: [RecordedSCPLRequest] = []
    private var firstContinuation: CheckedContinuation<SCPLResponse, Error>?
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func send(_ request: SCPLRequest, token: String?) async throws -> SCPLResponse {
        records.append(RecordedSCPLRequest(request: request, token: token))
        let count = records.count
        let ready = countWaiters.filter { count >= $0.0 }
        countWaiters.removeAll { count >= $0.0 }
        ready.forEach { $0.1.resume() }
        if count == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return success()
    }

    func waitForRequestCount(_ count: Int) async {
        if records.count >= count { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func releaseFirst() {
        firstContinuation?.resume(returning: success())
        firstContinuation = nil
    }

    func recorded() -> [RecordedSCPLRequest] {
        records
    }
}

private func success(_ body: JSONValue = ["STATUS": ["RESULT": "SUCCESS"]]) -> SCPLResponse {
    SCPLResponse(statusCode: 200, body: body, leafFingerprint: "AA")
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        verify(error)
    }
}
