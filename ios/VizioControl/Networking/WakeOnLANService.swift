import Darwin
import Foundation

public struct WakeNetworkInterface: Equatable, Sendable {
    public var address: String
    public var netmask: String
    public var interfaceIndex: UInt32

    public init(address: String, netmask: String, interfaceIndex: UInt32) {
        self.address = address
        self.netmask = netmask
        self.interfaceIndex = interfaceIndex
    }
}

public protocol WakeDatagramSending: Sendable {
    func send(_ packet: Data, to host: String, port: UInt16, interfaceIndex: UInt32?) async throws
}

public protocol WakeOnLANSending: Sendable {
    func wake(macAddress: String, cachedAddresses: [String]) async throws
}

public struct WakeOnLANService: WakeOnLANSending, Sendable {
    public typealias InterfaceProvider = @Sendable () -> [WakeNetworkInterface]
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct Target: Hashable, Sendable {
        var host: String
        var port: UInt16
        var interfaceIndex: UInt32?
    }

    private let datagrams: any WakeDatagramSending
    private let interfaceProvider: InterfaceProvider
    private let sleep: Sleep

    public init(
        datagrams: any WakeDatagramSending = SystemWakeDatagramSender(),
        interfaceProvider: @escaping InterfaceProvider = activeIPv4Interfaces,
        sleep: @escaping Sleep = { try await ContinuousClock().sleep(for: $0) }
    ) {
        self.datagrams = datagrams
        self.interfaceProvider = interfaceProvider
        self.sleep = sleep
    }

    public func wake(macAddress: String, cachedAddresses: [String]) async throws {
        let packet = try magicPacket(for: macAddress)
        var targets = Set<Target>()
        for port in [UInt16(9), UInt16(7)] {
            targets.insert(Target(host: "255.255.255.255", port: port, interfaceIndex: nil))
        }
        for address in cachedAddresses where isLocalIPv4Address(address) {
            guard let broadcast = classCSubnetBroadcast(address) else { continue }
            for port in [UInt16(9), UInt16(7)] {
                targets.insert(Target(host: broadcast, port: port, interfaceIndex: nil))
            }
        }
        for interface in interfaceProvider() {
            guard let broadcast = subnetBroadcast(address: interface.address, netmask: interface.netmask) else { continue }
            for port in [UInt16(9), UInt16(7)] {
                targets.insert(Target(host: broadcast, port: port, interfaceIndex: interface.interfaceIndex))
            }
        }

        for burst in 0..<3 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for target in targets {
                    group.addTask { [datagrams] in
                        try await datagrams.send(
                            packet,
                            to: target.host,
                            port: target.port,
                            interfaceIndex: target.interfaceIndex
                        )
                    }
                }
                try await group.waitForAll()
            }
            if burst < 2 { try await sleep(.milliseconds(140)) }
        }
    }
}

public struct SystemWakeDatagramSender: WakeDatagramSending, Sendable {
    public init() {}

    public func send(_ packet: Data, to host: String, port: UInt16, interfaceIndex: UInt32?) async throws {
        try await Task.detached {
            let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard descriptor >= 0 else {
                throw VizioControlError.message("Wake-on-LAN socket could not be opened.")
            }
            defer { close(descriptor) }

            var enabled: Int32 = 1
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_BROADCAST,
                &enabled,
                socklen_t(MemoryLayout.size(ofValue: enabled))
            ) == 0 else {
                throw VizioControlError.message("Wake-on-LAN broadcast could not be enabled.")
            }
            if var interfaceIndex {
                guard setsockopt(
                    descriptor,
                    IPPROTO_IP,
                    IP_BOUND_IF,
                    &interfaceIndex,
                    socklen_t(MemoryLayout.size(ofValue: interfaceIndex))
                ) == 0 else {
                    throw VizioControlError.message("Wake-on-LAN could not bind to the local interface.")
                }
            }

            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = port.bigEndian
            guard host.withCString({ inet_pton(AF_INET, $0, &destination.sin_addr) }) == 1 else {
                throw VizioControlError.message("Wake-on-LAN broadcast address is invalid.")
            }
            let sent = packet.withUnsafeBytes { packetBytes -> Int in
                withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        Darwin.sendto(
                            descriptor,
                            packetBytes.baseAddress,
                            packet.count,
                            0,
                            socketAddress,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            }
            guard sent == packet.count else {
                throw VizioControlError.message("Wake-on-LAN packet could not be sent.")
            }
        }.value
    }
}

public func activeIPv4Interfaces() -> [WakeNetworkInterface] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let head else { return [] }
    defer { freeifaddrs(head) }

    var result: [WakeNetworkInterface] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = head
    while let entry = cursor?.pointee {
        defer { cursor = entry.ifa_next }
        guard let address = entry.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET),
              let netmask = entry.ifa_netmask else { continue }
        let flags = Int32(entry.ifa_flags)
        guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
        guard let addressValue = numericIPv4(address),
              let maskValue = numericIPv4(netmask) else { continue }
        let name = String(cString: entry.ifa_name)
        let index = if_nametoindex(name)
        guard index != 0 else { continue }
        result.append(WakeNetworkInterface(
            address: addressValue,
            netmask: maskValue,
            interfaceIndex: index
        ))
    }
    return result
}

public func normalizeMACAddress(_ value: String?) -> String? {
    guard let value else { return nil }
    let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    let separators = CharacterSet(charactersIn: ":-. \t")
    guard value.unicodeScalars.allSatisfy({ hexadecimal.contains($0) || separators.contains($0) }) else {
        return nil
    }
    let compact = value.unicodeScalars
        .filter { hexadecimal.contains($0) }
        .map(String.init)
        .joined()
        .uppercased()
    guard compact.count == 12,
          compact.allSatisfy({ $0.isHexDigit }),
          compact != "000000000000",
          compact != "FFFFFFFFFFFF",
          let firstByte = UInt8(compact.prefix(2), radix: 16),
          firstByte & 1 == 0 else { return nil }
    return stride(from: 0, to: compact.count, by: 2)
        .map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: 2)
            return String(compact[start..<end])
        }
        .joined(separator: ":")
}

public func magicPacket(for macAddress: String) throws -> Data {
    guard let normalized = normalizeMACAddress(macAddress) else {
        throw VizioControlError.invalidMACAddress
    }
    let octets = normalized.split(separator: ":").compactMap { UInt8($0, radix: 16) }
    guard octets.count == 6 else { throw VizioControlError.invalidMACAddress }
    var packet = Data(repeating: 0xFF, count: 6)
    for _ in 0..<16 { packet.append(contentsOf: octets) }
    return packet
}

func subnetBroadcast(address: String, netmask: String) -> String? {
    guard let addressValue = ipv4Number(address), let maskValue = ipv4Number(netmask) else { return nil }
    return ipv4String(addressValue | ~maskValue)
}

private func classCSubnetBroadcast(_ address: String) -> String? {
    guard let value = ipv4Number(address) else { return nil }
    return ipv4String(value | 0x000000FF)
}

private func ipv4Number(_ value: String) -> UInt32? {
    let parts = value.split(separator: ".")
    guard parts.count == 4 else { return nil }
    var result: UInt32 = 0
    for part in parts {
        guard let octet = UInt32(part), octet <= 255 else { return nil }
        result = (result << 8) | octet
    }
    return result
}

private func ipv4String(_ value: UInt32) -> String {
    [24, 16, 8, 0].map { String((value >> UInt32($0)) & 0xFF) }.joined(separator: ".")
}

private func numericIPv4(_ address: UnsafePointer<sockaddr>) -> String? {
    guard address.pointee.sa_family == UInt8(AF_INET) else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    let pointer = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self)
    var internetAddress = pointer.pointee.sin_addr
    guard inet_ntop(AF_INET, &internetAddress, &buffer, socklen_t(buffer.count)) != nil else {
        return nil
    }
    return utf8String(buffer)
}

private func utf8String(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
