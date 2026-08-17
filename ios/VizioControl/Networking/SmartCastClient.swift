import Foundation

public struct SmartCastRequestError: Error, LocalizedError, Equatable, Sendable {
    public let statusCode: Int
    public let result: String?
    public let detail: String?

    public init(statusCode: Int, result: String?, detail: String?) {
        self.statusCode = statusCode
        self.result = result
        self.detail = detail
    }

    public var errorDescription: String? {
        if let detail, !detail.isEmpty { return detail }
        return "TV returned HTTP \(statusCode)."
    }
}

public struct ParsedDeviceInfo: Equatable, Sendable {
    public var model: String?
    public var serial: String?
    public var name: String?
}

public struct SmartCastAudioState: Equatable, Sendable {
    public var volume: Int?
    public var muted: Bool?
}

public struct SmartCastAppState: Equatable, Sendable {
    public var appID: String
    public var namespace: Int
    public var message: String
    public var name: String
}

public struct AppLaunchConfiguration: Equatable, Sendable {
    public var appID: String
    public var namespace: Int
    public var message: String
    public var name: String

    public init(appID: String, namespace: Int, message: String, name: String) {
        self.appID = appID
        self.namespace = namespace
        self.message = message
        self.name = name
    }
}

public struct QuickStartResult: Equatable, Sendable {
    public var changed: Bool
    public var value: String
}

public protocol SmartCastControlling: Actor {
    var endpoint: DeviceEndpoint { get }
    func setToken(_ token: String?)
    func setExpectedSerial(_ serial: String?)
    func getDeviceInfo(timeout: Duration) async throws -> SCPLResponse
    func getState() async -> TVState
    func startPairing(deviceID: String) async throws -> Int
    func finishPairing(deviceID: String, requestToken: Int, pin: String) async throws -> String
    func pressKey(_ key: TVKey, count: Int, timeout: Duration) async throws
    func setVolume(_ value: Double) async throws -> Int
    func typeText(_ value: String) async throws
    func ensureQuickStartPowerMode() async throws -> QuickStartResult
    func launchApp(_ configuration: AppLaunchConfiguration) async throws
}

public actor SmartCastClient: SmartCastControlling {
    public let endpoint: DeviceEndpoint

    private let transport: any SmartCastTransport
    private var token: String?
    private var expectedSerial: String?

    private struct PendingKeyRequest {
        let keys: [TVKey]
        let timeout: Duration
        let batchable: Bool
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct PendingVolumeRequest {
        var value: Int
        var waiters: [CheckedContinuation<Int, Error>]
    }

    private var pendingKeys: [PendingKeyRequest] = []
    private var keyPumpRunning = false
    private var pendingVolume: PendingVolumeRequest?
    private var volumePumpRunning = false

    public init(
        endpoint: DeviceEndpoint,
        transport: any SmartCastTransport,
        token: String? = nil,
        expectedSerial: String? = nil
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.token = token
        self.expectedSerial = expectedSerial
        _ = singleKeyPayloads.count
    }

    public func setToken(_ token: String?) {
        self.token = token
    }

    public func setExpectedSerial(_ serial: String?) {
        expectedSerial = serial
    }

    private func perform(_ request: SCPLRequest) async throws -> SCPLResponse {
        if request.authenticated, token == nil {
            throw VizioControlError.missingPairingToken
        }
        let response = try await transport.send(request, token: request.authenticated ? token : nil)
        let status = response.body["STATUS"]?.objectValue
        let result = status?["RESULT"]?.stringValue
        let detail = status?["DETAIL"]?.stringValue
        if response.statusCode >= 400 || (result != nil && result != "SUCCESS") {
            throw SmartCastRequestError(statusCode: response.statusCode, result: result, detail: detail)
        }
        return response
    }

    public func getDeviceInfo(timeout: Duration = .seconds(8)) async throws -> SCPLResponse {
        try await perform(SCPLRequest(
            path: "/state/device/deviceinfo",
            method: .get,
            authenticated: false,
            timeout: timeout
        ))
    }

    public func getPower(timeout: Duration = .seconds(8)) async throws -> Bool {
        let response = try await perform(SCPLRequest(
            path: "/state/device/power_mode",
            method: .get,
            authenticated: false,
            timeout: timeout
        ))
        let nested = findMenuItem(response.body, cname: "power_mode")?["VALUE"]
        let item = response.body["ITEM"]?["VALUE"]
        let firstItem = response.body["ITEMS"]?.arrayValue?.first?["VALUE"]
        let value = nested ?? item ?? firstItem ?? response.body["VALUE"]
        return value?.doubleValue == 1
    }

    public func getAudioState() async throws -> SmartCastAudioState {
        let response = try await perform(SCPLRequest(
            path: "/menu_native/dynamic/tv_settings/audio",
            method: .get
        ))
        let rawVolume = findMenuItem(response.body, cname: "volume")?["VALUE"]?.doubleValue
        let volume = rawVolume.flatMap { $0.isFinite ? Int($0.rounded()) : nil }
        let rawMute = findMenuItem(response.body, cname: "mute")?["VALUE"]?.stringValue?.lowercased()
        return SmartCastAudioState(
            volume: volume.map { min(100, max(0, $0)) },
            muted: rawMute.map { $0 == "on" }
        )
    }

    public func getCurrentApp() async throws -> SmartCastAppState {
        let response = try await perform(SCPLRequest(path: "/app/current", method: .get))
        let item = response.body["ITEM"]?.objectValue ?? [:]
        let value = item["VALUE"]?.objectValue ?? [:]
        return SmartCastAppState(
            appID: value["APP_ID"]?.stringValue ?? item["APP_ID"]?.stringValue ?? "",
            namespace: value["NAME_SPACE"]?.intValue ?? item["NAME_SPACE"]?.intValue ?? 0,
            message: value["MESSAGE"]?.stringValue ?? item["MESSAGE"]?.stringValue ?? "",
            name: value["NAME"]?.stringValue ?? item["NAME"]?.stringValue ?? ""
        )
    }

    public func getState() async -> TVState {
        do {
            if let expectedSerial {
                let deviceInfo = try await getDeviceInfo()
                let actual = parseDeviceInfo(deviceInfo.body).serial
                guard actual == expectedSerial else {
                    throw VizioControlError.message("The TV at this address is not the paired TV. Rediscovering the verified TV.")
                }
            }
            let power = try await getPower()
            guard power else {
                return TVState(connected: true, power: false, endpoint: endpoint)
            }

            async let audioRead: SmartCastAudioState? = optionalAudioState()
            async let appRead: SmartCastAppState? = optionalCurrentApp()
            let (audio, app) = await (audioRead, appRead)
            let appName = app.flatMap { state -> String? in
                if !state.name.isEmpty { return state.name }
                let messageName = appNameFromMessage(state.message)
                if !messageName.isEmpty { return messageName }
                let identityName = appNameFromIdentity(appID: state.appID, namespace: state.namespace)
                if !identityName.isEmpty { return identityName }
                return state.appID.isEmpty ? nil : "SmartCast app \(state.appID)"
            }
            return TVState(
                connected: true,
                power: true,
                volume: audio?.volume,
                muted: audio?.muted,
                currentApp: appName,
                endpoint: endpoint
            )
        } catch {
            return TVState(
                connected: false,
                endpoint: endpoint,
                error: errorMessage(error)
            )
        }
    }

    public func startPairing(deviceID: String) async throws -> Int {
        let response = try await perform(SCPLRequest(
            path: "/pairing/start",
            method: .put,
            body: pairingStartPayload(deviceID: deviceID),
            authenticated: false
        ))
        guard let requestToken = response.body["ITEM"]?["PAIRING_REQ_TOKEN"]?.intValue,
              requestToken != 0 else {
            throw VizioControlError.message("TV did not start pairing. Try discovery again.")
        }
        return requestToken
    }

    public func finishPairing(deviceID: String, requestToken: Int, pin: String) async throws -> String {
        let response = try await perform(SCPLRequest(
            path: "/pairing/pair",
            method: .put,
            body: pairingFinishPayload(deviceID: deviceID, requestToken: requestToken, pin: pin),
            authenticated: false
        ))
        guard let authToken = response.body["ITEM"]?["AUTH_TOKEN"]?.stringValue,
              !authToken.isEmpty else {
            let detail = response.body["STATUS"]?["DETAIL"]?.stringValue
            throw VizioControlError.message(
                detail?.isEmpty == false
                    ? detail!
                    : "That PIN was not accepted. Start a new pairing session after two failed attempts."
            )
        }
        token = authToken
        return authToken
    }

    public func pressKey(_ key: TVKey, count: Int = 1, timeout: Duration = .seconds(8)) async throws {
        let safeCount = min(10, max(1, count))
        if keyPumpRunning {
            let keys = Array(repeating: key, count: safeCount)
            try await withCheckedThrowingContinuation { continuation in
                pendingKeys.append(PendingKeyRequest(
                    keys: keys,
                    timeout: timeout,
                    batchable: !key.isPower,
                    continuation: continuation
                ))
            }
            return
        }

        keyPumpRunning = true
        defer { startPendingKeyPumpIfNeeded() }
        _ = try await perform(SCPLRequest(
            path: "/key_command/",
            method: .put,
            body: keyPayload(key, count: safeCount),
            timeout: timeout
        ))
    }

    private func startPendingKeyPumpIfNeeded() {
        guard !pendingKeys.isEmpty else {
            keyPumpRunning = false
            return
        }
        let batch = takeKeyBatch()
        Task { await self.runKeyPump(startingWith: batch) }
    }

    public func setVolume(_ value: Double) async throws -> Int {
        let safeValue = min(100, max(0, Int(value.rounded())))
        return try await withCheckedThrowingContinuation { continuation in
            if pendingVolume == nil {
                pendingVolume = PendingVolumeRequest(value: safeValue, waiters: [continuation])
            } else {
                pendingVolume?.value = safeValue
                pendingVolume?.waiters.append(continuation)
            }
            guard !volumePumpRunning else { return }
            volumePumpRunning = true
            let request = takePendingVolume()
            Task { await self.runVolumePump(startingWith: request) }
        }
    }

    public func typeText(_ value: String) async throws {
        let text = truncatedUTF16(value, limit: 120)
        guard !text.isEmpty,
              text.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw VizioControlError.message("Text entry accepts 1–120 ASCII characters.")
        }
        _ = try await perform(SCPLRequest(
            path: "/key_command/",
            method: .put,
            body: textPayload(text)
        ))
    }

    public func ensureQuickStartPowerMode() async throws -> QuickStartResult {
        let current = try await readConfiguredPowerMode()
        if isQuickStartPowerMode(current.value) {
            return QuickStartResult(changed: false, value: current.value)
        }
        guard isEcoPowerMode(current.value) else {
            throw VizioControlError.message("TV returned an unrecognized Power Mode setting.")
        }
        if current.item["READONLY"]?.boolValue == true
            || current.item["READONLY"]?.stringValue?.lowercased() == "true" {
            throw VizioControlError.message("TV reported that Power Mode is read-only.")
        }
        guard let hash = current.item["HASHVAL"]?.doubleValue, hash.isFinite else {
            throw VizioControlError.message("TV did not return the Power Mode setting hash.")
        }
        let advertised = settingOptionStrings(current.item["ELEMENTS"] ?? .null)
            .first(where: isQuickStartPowerMode)
        let target = advertised ?? "Quick Start"
        _ = try await perform(SCPLRequest(
            path: "/menu_native/dynamic/tv_settings/system/power_mode",
            method: .put,
            body: settingPayload(hash: hash, value: .string(target))
        ))
        let verified = try await readConfiguredPowerMode()
        guard isQuickStartPowerMode(verified.value) else {
            throw VizioControlError.message("TV did not confirm Quick Start Power Mode.")
        }
        return QuickStartResult(changed: true, value: verified.value)
    }

    public func launchApp(_ configuration: AppLaunchConfiguration) async throws {
        _ = try await perform(SCPLRequest(
            path: "/app/launch",
            method: .put,
            body: [
                "VALUE": [
                    "APP_ID": .string(configuration.appID),
                    "NAME_SPACE": .number(Double(configuration.namespace)),
                    "MESSAGE": .string(configuration.message)
                ]
            ]
        ))
    }

    private func optionalAudioState() async -> SmartCastAudioState? {
        try? await getAudioState()
    }

    private func optionalCurrentApp() async -> SmartCastAppState? {
        try? await getCurrentApp()
    }

    private func readConfiguredPowerMode() async throws -> (item: [String: JSONValue], value: String) {
        let response = try await perform(SCPLRequest(
            path: "/menu_native/dynamic/tv_settings/system",
            method: .get
        ))
        guard let item = findMenuItem(response.body, cname: "power_mode") else {
            throw VizioControlError.message("TV did not expose its Power Mode setting.")
        }
        let value = item["VALUE"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw VizioControlError.message("TV returned an empty Power Mode setting.")
        }
        return (item, value)
    }

    private func takeKeyBatch() -> [PendingKeyRequest] {
        precondition(!pendingKeys.isEmpty)
        var batch = [pendingKeys.removeFirst()]
        var keyCount = batch[0].keys.count
        if batch[0].batchable {
            while let next = pendingKeys.first,
                  next.batchable,
                  keyCount + next.keys.count <= 10 {
                batch.append(pendingKeys.removeFirst())
                keyCount += next.keys.count
            }
        }
        return batch
    }

    private func runKeyPump(startingWith firstBatch: [PendingKeyRequest]) async {
        var batch = firstBatch
        while true {
            let keys = batch.flatMap(\.keys)
            let timeout = batch.map(\.timeout).max() ?? .seconds(8)
            do {
                _ = try await perform(SCPLRequest(
                    path: "/key_command/",
                    method: .put,
                    body: keySequencePayload(keys),
                    timeout: timeout
                ))
                batch.forEach { $0.continuation.resume() }
            } catch {
                batch.forEach { $0.continuation.resume(throwing: error) }
            }
            guard !pendingKeys.isEmpty else {
                keyPumpRunning = false
                return
            }
            batch = takeKeyBatch()
        }
    }

    private func takePendingVolume() -> PendingVolumeRequest {
        precondition(pendingVolume != nil)
        defer { pendingVolume = nil }
        return pendingVolume!
    }

    private func runVolumePump(startingWith firstRequest: PendingVolumeRequest) async {
        var request = firstRequest
        while true {
            do {
                try await sendVolume(request.value)
                request.waiters.forEach { $0.resume(returning: request.value) }
            } catch {
                request.waiters.forEach { $0.resume(throwing: error) }
            }
            guard pendingVolume != nil else {
                volumePumpRunning = false
                return
            }
            request = takePendingVolume()
        }
    }

    private func sendVolume(_ value: Int) async throws {
        do {
            _ = try await perform(SCPLRequest(
                path: "/audio/volume/level",
                method: .put,
                body: flatVolumePayload(value)
            ))
            return
        } catch let error as SmartCastRequestError
            where error.statusCode == 404 || error.result == "URI_NOT_FOUND" {
            // Older firmware uses a menu-tree setting guarded by HASHVAL.
        }

        let current = try await perform(SCPLRequest(
            path: "/menu_native/dynamic/tv_settings/audio/volume",
            method: .get
        ))
        guard let hash = findMenuItem(current.body, cname: "volume")?["HASHVAL"]?.doubleValue,
              hash.isFinite else {
            throw VizioControlError.message("TV did not return the volume control hash.")
        }
        _ = try await perform(SCPLRequest(
            path: "/menu_native/dynamic/tv_settings/audio/volume",
            method: .put,
            body: volumePayload(hash: hash, value: value)
        ))
    }
}

public let smartCastKeyCodes: [TVKey: (codeset: Int, code: Int)] = [
    .powerOff: (11, 0),
    .powerOn: (11, 1),
    .powerToggle: (11, 2),
    .volumeDown: (5, 0),
    .volumeUp: (5, 1),
    .mute: (5, 4),
    .input: (7, 1),
    .down: (3, 0),
    .left: (3, 1),
    .ok: (3, 2),
    .right: (3, 7),
    .up: (3, 8),
    .back: (4, 0),
    .home: (4, 3),
    .menu: (4, 8),
    .exit: (9, 0),
    .fastForward: (2, 0),
    .rewind: (2, 1),
    .pause: (2, 2),
    .play: (2, 3)
]

public func keySequencePayload(_ keys: [TVKey]) -> JSONValue {
    precondition((1...10).contains(keys.count), "SmartCast key sequences accept 1–10 commands.")
    return [
        "KEYLIST": .array(keys.map { key in
            let command = smartCastKeyCodes[key]!
            return [
                "CODESET": .number(Double(command.codeset)),
                "CODE": .number(Double(command.code)),
                "ACTION": "KEYPRESS"
            ]
        })
    ]
}

private let singleKeyPayloads = Dictionary(uniqueKeysWithValues:
    smartCastKeyCodes.keys.map { ($0, keySequencePayload([$0])) }
)

public func keyPayload(_ key: TVKey, count: Int = 1) -> JSONValue {
    let safeCount = min(10, max(1, count))
    if safeCount == 1 { return singleKeyPayloads[key]! }
    return keySequencePayload(Array(repeating: key, count: safeCount))
}

public func flatVolumePayload(_ value: Int) -> JSONValue {
    ["LEVEL": .number(Double(min(100, max(0, value))))]
}

public func volumePayload(hash: Double, value: Int) -> JSONValue {
    [
        "REQUEST": "MODIFY",
        "HASHVAL": .number(hash),
        "VALUE": .number(Double(min(100, max(0, value))))
    ]
}

public func settingPayload(hash: Double, value: JSONValue) -> JSONValue {
    ["REQUEST": "MODIFY", "HASHVAL": .number(hash), "VALUE": value]
}

public func textPayload(_ value: String) -> JSONValue {
    [
        "KEYLIST": .array(value.unicodeScalars.map { scalar in
            ["CODESET": 0, "CODE": .number(Double(scalar.value)), "ACTION": "KEYPRESS"]
        })
    ]
}

public func pairingStartPayload(deviceID: String) -> JSONValue {
    ["DEVICE_ID": .string(deviceID), "DEVICE_NAME": "VizioControl"]
}

public func pairingFinishPayload(deviceID: String, requestToken: Int, pin: String) -> JSONValue {
    [
        "DEVICE_ID": .string(deviceID),
        "CHALLENGE_TYPE": 1,
        "RESPONSE_VALUE": .string(pin),
        "PAIRING_REQ_TOKEN": .number(Double(requestToken))
    ]
}

public func parseDeviceInfo(_ response: JSONValue) -> ParsedDeviceInfo {
    var values: [String: String] = [:]
    func visit(_ value: JSONValue) {
        switch value {
        case let .array(items):
            items.forEach(visit)
        case let .object(item):
            let cname = normalizeIdentityKey(item["CNAME"]?.stringValue ?? item["NAME"]?.stringValue ?? "")
            if !cname.isEmpty, let primitive = primitiveString(item["VALUE"]) {
                values[cname] = primitive
            }
            for (key, child) in item {
                if let primitive = primitiveString(child) {
                    values[normalizeIdentityKey(key)] = primitive
                } else {
                    visit(child)
                }
            }
        default:
            break
        }
    }
    visit(response)
    func first(_ aliases: [String]) -> String? {
        aliases.lazy.compactMap { values[normalizeIdentityKey($0)] }.first(where: { !$0.isEmpty })
    }
    return ParsedDeviceInfo(
        model: first(["MODEL_NAME", "modelName", "model"]),
        serial: first(["SERIAL_NUMBER", "serialNumber", "serial"]),
        name: first(["DEVICE_NAME", "deviceName", "friendlyName", "CAST_NAME", "castName", "name"])
    )
}

public func appNameFromIdentity(appID: String, namespace: Int) -> String {
    let knownApps = ["3:2": "Hulu", "1:3": "Netflix", "1:4": "Prime Video", "1:5": "YouTube"]
    return knownApps["\(appID):\(namespace)"] ?? ""
}

private func appNameFromMessage(_ message: String) -> String {
    guard let host = URL(string: message)?.host?.lowercased() else { return "" }
    if host.contains("hulu") { return "Hulu" }
    if host.contains("netflix") { return "Netflix" }
    if host.contains("youtube") { return "YouTube" }
    if host.contains("primevideo") || host.contains("amazon") { return "Prime Video" }
    return ""
}

func findMenuItem(_ value: JSONValue, cname: String) -> [String: JSONValue]? {
    switch value {
    case let .array(items):
        for item in items {
            if let match = findMenuItem(item, cname: cname) { return match }
        }
    case let .object(item):
        if item["CNAME"]?.stringValue?.lowercased() == cname.lowercased() { return item }
        for child in item.values {
            if let match = findMenuItem(child, cname: cname) { return match }
        }
    default:
        break
    }
    return nil
}

private func normalizeIdentityKey(_ value: String) -> String {
    value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
}

private func primitiveString(_ value: JSONValue?) -> String? {
    guard let value else { return nil }
    switch value {
    case .string, .number, .bool:
        return value.stringValue
    default:
        return nil
    }
}

private func normalizePowerMode(_ value: String) -> String {
    value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
}

private func isQuickStartPowerMode(_ value: String) -> Bool {
    normalizePowerMode(value).contains("quickstart")
}

private func isEcoPowerMode(_ value: String) -> Bool {
    normalizePowerMode(value).contains("eco")
}

private func settingOptionStrings(_ value: JSONValue) -> [String] {
    switch value {
    case let .string(value):
        [value]
    case let .array(values):
        values.flatMap(settingOptionStrings)
    case let .object(value):
        ["VALUE", "NAME", "LABEL"].flatMap { key in
            value[key].map(settingOptionStrings) ?? []
        }
    default:
        []
    }
}

private func truncatedUTF16(_ value: String, limit: Int) -> String {
    var count = 0
    var end = value.startIndex
    for character in value {
        let next = String(character).utf16.count
        guard count + next <= limit else { break }
        count += next
        end = value.index(end, offsetBy: 1)
    }
    return String(value[..<end])
}

private func errorMessage(_ error: Error) -> String {
    if let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty {
        return description
    }
    return error.localizedDescription
}
