import Foundation

public enum TVKey: String, Codable, CaseIterable, Sendable {
    case powerOff
    case powerOn
    case powerToggle
    case volumeDown
    case volumeUp
    case mute
    case input
    case down
    case left
    case ok
    case right
    case up
    case back
    case home
    case menu
    case exit
    case fastForward
    case rewind
    case pause
    case play

    public var isPower: Bool {
        self == .powerOff || self == .powerOn || self == .powerToggle
    }
}

public enum TVAction: Codable, Equatable, Sendable {
    case key(TVKey, count: Int)
    case setVolume(Int)
    case launchApp(String)
}

public enum DiscoverySource: String, Codable, Sendable {
    case mdns
    case cached
    case manual
}

public enum AppSceneActivity: Sendable {
    case active
    case inactive
    case background
}

public enum DiscoveryProgress: Equatable, Sendable {
    case idle
    case waitingForPermission
    case scanning
    case denied
}

public struct DeviceEndpoint: Codable, Equatable, Hashable, Sendable {
    public var host: String
    public var resolvedAddresses: [String]
    public var interfaceIndex: UInt32?

    public init(host: String, resolvedAddresses: [String] = [], interfaceIndex: UInt32? = nil) {
        self.host = host
        self.resolvedAddresses = Array(Set(resolvedAddresses)).sorted()
        self.interfaceIndex = interfaceIndex
    }
}

public struct DeviceCandidate: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var endpoint: DeviceEndpoint
    public var model: String?
    public var serial: String?
    public var fingerprint: String?
    public var macAddress: String?
    public var source: DiscoverySource

    public init(
        id: String,
        name: String,
        endpoint: DeviceEndpoint,
        model: String? = nil,
        serial: String? = nil,
        fingerprint: String? = nil,
        macAddress: String? = nil,
        source: DiscoverySource
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.model = model
        self.serial = serial
        self.fingerprint = fingerprint
        self.macAddress = macAddress
        self.source = source
    }
}

public struct PairedDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var endpoint: DeviceEndpoint
    public var model: String?
    public var serial: String?
    public var fingerprint: String?
    public var macAddress: String?
    public var deviceID: String
    public var pairedAt: Date

    public init(
        id: String,
        name: String,
        endpoint: DeviceEndpoint,
        model: String? = nil,
        serial: String? = nil,
        fingerprint: String? = nil,
        macAddress: String? = nil,
        deviceID: String,
        pairedAt: Date
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.model = model
        self.serial = serial
        self.fingerprint = fingerprint
        self.macAddress = macAddress
        self.deviceID = deviceID
        self.pairedAt = pairedAt
    }
}

public struct TVState: Codable, Equatable, Sendable {
    public var connected: Bool
    public var power: Bool?
    public var volume: Int?
    public var muted: Bool?
    public var currentApp: String?
    public var endpoint: DeviceEndpoint?
    public var error: String?

    public init(
        connected: Bool = false,
        power: Bool? = nil,
        volume: Int? = nil,
        muted: Bool? = nil,
        currentApp: String? = nil,
        endpoint: DeviceEndpoint? = nil,
        error: String? = nil
    ) {
        self.connected = connected
        self.power = power
        self.volume = volume
        self.muted = muted
        self.currentApp = currentApp
        self.endpoint = endpoint
        self.error = error
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var manualAddress: String
    public var manualMACAddress: String

    public init(manualAddress: String = "", manualMACAddress: String = "") {
        self.manualAddress = manualAddress
        self.manualMACAddress = manualMACAddress
    }
}

public struct SavedCommand: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var systemImage: String
    public var normalizedRequest: String
    public var order: Int
    public var usageCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var actions: [TVAction]

    public init(
        id: UUID = UUID(),
        label: String,
        systemImage: String,
        normalizedRequest: String,
        order: Int,
        usageCount: Int,
        createdAt: Date,
        updatedAt: Date,
        actions: [TVAction]
    ) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.normalizedRequest = normalizedRequest
        self.order = order
        self.usageCount = usageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.actions = actions
    }
}

public struct PairingStart: Equatable, Sendable {
    public var requestToken: Int
    public var deviceID: String
    public var candidate: DeviceCandidate

    public init(requestToken: Int, deviceID: String, candidate: DeviceCandidate) {
        self.requestToken = requestToken
        self.deviceID = deviceID
        self.candidate = candidate
    }
}

public enum VizioControlError: Error, LocalizedError, Equatable, Sendable {
    case message(String)
    case localNetworkDenied
    case fingerprintChanged
    case missingPairingToken
    case missingWakeAddress
    case offline(String?)
    case invalidManualEndpoint
    case invalidMACAddress
    case pairingCredentialsUnavailable

    public var errorDescription: String? {
        switch self {
        case let .message(message):
            message
        case .localNetworkDenied:
            "Local Network access is off. Allow VizioControl in Settings to find and control your TV."
        case .fingerprintChanged:
            "TV’s security fingerprint changed. Forget and pair the TV again before sending controls."
        case .missingPairingToken:
            "Pair TV before sending controls."
        case .missingWakeAddress:
            "TV is offline and its wake address is not saved. Enter the TV’s MAC address in Settings, then try Wake again."
        case let .offline(detail):
            if let detail, !detail.isEmpty {
                "TV is offline. Use Power to wake it, or turn it on once and press Refresh. \(detail)"
            } else {
                "TV is offline. Use Power to wake it, or turn it on once and press Refresh."
            }
        case .invalidManualEndpoint:
            "Enter a private LAN hostname or IP address."
        case .invalidMACAddress:
            "Enter a valid unicast TV MAC address."
        case .pairingCredentialsUnavailable:
            "Pairing credentials are unavailable. Pair the TV again."
        }
    }
}
