import Foundation
import XCTest
@testable import VizioControl

final class WakeOnLANServiceTests: XCTestCase, @unchecked Sendable {
    func testMACNormalizationRejectsUnsafeAddressesAndPacketIsExact() throws {
        XCTAssertEqual(normalizeMACAddress("a8-c9-6b-12-34-56"), "A8:C9:6B:12:34:56")
        XCTAssertEqual(normalizeMACAddress("A8C9.6B12.3456"), "A8:C9:6B:12:34:56")
        XCTAssertEqual(normalizeMACAddress(" A8 C9 6B 12 34 56 "), "A8:C9:6B:12:34:56")
        XCTAssertNil(normalizeMACAddress("A8:C9:6B:12:34:5Z"))
        XCTAssertNil(normalizeMACAddress("00:00:00:00:00:00"))
        XCTAssertNil(normalizeMACAddress("FF:FF:FF:FF:FF:FF"))
        XCTAssertNil(normalizeMACAddress("A9:C9:6B:12:34:56"))

        let packet = try magicPacket(for: "A8:C9:6B:12:34:56")
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), Array(repeating: 0xFF, count: 6))
        let expectedMAC = [UInt8(0xA8), 0xC9, 0x6B, 0x12, 0x34, 0x56]
        for repetition in 0..<16 {
            let start = 6 + repetition * 6
            XCTAssertEqual(Array(packet[start..<(start + 6)]), expectedMAC)
        }
    }

    func testWakeUsesBoundedCachedAndInterfaceBroadcastsForEveryBurst() async throws {
        let sender = RecordingWakeDatagramSender()
        let sleeps = DurationRecorder()
        let service = WakeOnLANService(
            datagrams: sender,
            interfaceProvider: {
                [
                    WakeNetworkInterface(address: "192.168.50.42", netmask: "255.255.255.0", interfaceIndex: 4),
                    WakeNetworkInterface(address: "10.8.2.3", netmask: "255.255.0.0", interfaceIndex: 9),
                ]
            },
            sleep: { duration in await sleeps.record(duration) }
        )

        try await service.wake(
            macAddress: "A8:C9:6B:12:34:56",
            cachedAddresses: ["192.168.77.20", "8.8.8.8"]
        )

        let records = await sender.records()
        XCTAssertEqual(records.count, 24)
        let expected = Set([
            WakeTarget(host: "255.255.255.255", port: 9, interfaceIndex: nil),
            WakeTarget(host: "255.255.255.255", port: 7, interfaceIndex: nil),
            WakeTarget(host: "192.168.77.255", port: 9, interfaceIndex: nil),
            WakeTarget(host: "192.168.77.255", port: 7, interfaceIndex: nil),
            WakeTarget(host: "192.168.50.255", port: 9, interfaceIndex: 4),
            WakeTarget(host: "192.168.50.255", port: 7, interfaceIndex: 4),
            WakeTarget(host: "10.8.255.255", port: 9, interfaceIndex: 9),
            WakeTarget(host: "10.8.255.255", port: 7, interfaceIndex: 9),
        ])
        XCTAssertEqual(Set(records.map(\.target)), expected)
        for target in expected {
            XCTAssertEqual(records.filter { $0.target == target }.count, 3)
        }
        XCTAssertTrue(records.allSatisfy { $0.packet == records.first?.packet })
        let observedSleeps = await sleeps.values()
        XCTAssertEqual(observedSleeps, [.milliseconds(140), .milliseconds(140)])
    }

    func testSubnetBroadcastUsesActualNetmaskAndSocketFailurePropagates() async {
        XCTAssertEqual(subnetBroadcast(address: "172.20.18.9", netmask: "255.255.240.0"), "172.20.31.255")
        let service = WakeOnLANService(
            datagrams: FailingWakeDatagramSender(),
            interfaceProvider: { [] },
            sleep: { _ in }
        )
        do {
            try await service.wake(macAddress: "A8:C9:6B:12:34:56", cachedAddresses: [])
            XCTFail("Expected send failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "send failed")
        }
    }
}

private struct WakeTarget: Hashable, Sendable {
    var host: String
    var port: UInt16
    var interfaceIndex: UInt32?
}

private struct WakeRecord: Sendable {
    var packet: Data
    var target: WakeTarget
}

private actor RecordingWakeDatagramSender: WakeDatagramSending {
    private var values: [WakeRecord] = []

    func send(_ packet: Data, to host: String, port: UInt16, interfaceIndex: UInt32?) async throws {
        values.append(WakeRecord(
            packet: packet,
            target: WakeTarget(host: host, port: port, interfaceIndex: interfaceIndex)
        ))
    }

    func records() -> [WakeRecord] { values }
}

private struct FailingWakeDatagramSender: WakeDatagramSending {
    func send(_ packet: Data, to host: String, port: UInt16, interfaceIndex: UInt32?) async throws {
        throw VizioControlError.message("send failed")
    }
}

private actor DurationRecorder {
    private var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
    func values() -> [Duration] { durations }
}
