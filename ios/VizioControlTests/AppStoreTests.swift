import Foundation
import XCTest
@testable import VizioControl

final class AppStoreTests: XCTestCase, @unchecked Sendable {
    func testCorruptStateIsQuarantinedAndDefaultsPersisted() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("viziocontrol.json")
        try Data("not-json".utf8).write(to: stateURL)

        let store = AppStore(directory: directory)
        let snapshot = try await store.load()

        XCTAssertEqual(snapshot, StoreFile())
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains("viziocontrol.json"))
        XCTAssertEqual(names.filter { $0.hasPrefix("viziocontrol.json.corrupt-") }.count, 1)
        let persisted = try JSONDecoder.vizio.decode(StoreFile.self, from: Data(contentsOf: stateURL))
        XCTAssertEqual(persisted, StoreFile())
    }

    func testCommandUpsertEditDuplicateOrderDeleteUndoAndReload() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        _ = try await store.load()
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let first = savedCommand(
            id: firstID,
            label: "Mute",
            normalized: "mute",
            order: 88,
            usage: 99,
            date: firstDate,
            actions: [.key(.mute, count: 1)]
        )

        var commands = try await store.upsertCommand(first)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].order, 0)
        XCTAssertEqual(commands[0].usageCount, 1)

        let replacement = savedCommand(
            id: UUID(),
            label: "Quiet",
            normalized: "mute",
            order: 9,
            usage: 0,
            date: Date(timeIntervalSince1970: 1_700_000_100),
            actions: [.key(.mute, count: 2)]
        )
        commands = try await store.upsertCommand(replacement)
        XCTAssertEqual(commands[0].id, firstID)
        XCTAssertEqual(commands[0].order, 0)
        XCTAssertEqual(commands[0].createdAt, firstDate)
        XCTAssertEqual(commands[0].usageCount, 2)
        XCTAssertEqual(commands[0].label, "Quiet")
        XCTAssertEqual(commands[0].actions, [.key(.mute, count: 2)])

        let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let second = savedCommand(
            id: secondID,
            label: "Power",
            normalized: "power on",
            order: -4,
            usage: 0,
            date: Date(timeIntervalSince1970: 1_700_000_200),
            actions: [.key(.powerOn, count: 1)]
        )
        commands = try await store.upsertCommand(second)
        XCTAssertEqual(commands.map(\.order), [0, 1])

        commands = try await store.editCommand(
            id: firstID,
            label: "   123456789012345678901234567890123456789012345   ",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        XCTAssertEqual(commands[0].label, "1234567890123456789012345678901234567890")
        do {
            _ = try await store.editCommand(id: firstID, label: "  \n ")
            XCTFail("Expected empty-label rejection")
        } catch let error as VizioControlError {
            XCTAssertEqual(error.localizedDescription, "Saved command label cannot be empty.")
        }

        let duplicateDate = Date(timeIntervalSince1970: 1_700_000_400)
        commands = try await store.duplicateCommand(id: firstID, at: duplicateDate)
        let duplicate = try XCTUnwrap(commands.last)
        XCTAssertNotEqual(duplicate.id, firstID)
        XCTAssertEqual(duplicate.label, "\(commands[0].label) copy")
        XCTAssertEqual(duplicate.systemImage, commands[0].systemImage)
        XCTAssertEqual(duplicate.actions, commands[0].actions)
        XCTAssertEqual(duplicate.usageCount, 0)
        XCTAssertEqual(duplicate.order, 2)
        XCTAssertEqual(duplicate.createdAt, duplicateDate)
        XCTAssertEqual(
            duplicate.normalizedRequest,
            "mute-copy-\(duplicate.id.uuidString.lowercased())"
        )

        commands = try await store.reorderCommand(id: duplicate.id, direction: -1)
        XCTAssertEqual(commands.map(\.id), [firstID, duplicate.id, secondID])
        commands = try await store.deleteCommand(id: duplicate.id)
        XCTAssertEqual(commands.map(\.id), [firstID, secondID])
        commands = try await store.deleteCommand(id: UUID())
        XCTAssertEqual(commands.map(\.id), [firstID, secondID])
        commands = try await store.undoDelete()
        XCTAssertEqual(commands.map(\.id), [firstID, duplicate.id, secondID])
        commands = try await store.undoDelete()
        XCTAssertEqual(commands.map(\.id), [firstID, duplicate.id, secondID])

        let reloaded = AppStore(directory: directory)
        let persisted = try await reloaded.load()
        XCTAssertEqual(persisted.commands, commands)
    }

    func testOnlyLatestDeletionCanUndoAndConcurrentWritesRemainComplete() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        _ = try await store.load()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let date = Date(timeIntervalSince1970: TimeInterval(1_700_001_000 + index))
                    _ = try await store.upsertCommand(savedCommand(
                        label: "Command \(index)",
                        normalized: "command \(index)",
                        order: index,
                        usage: 0,
                        date: date,
                        actions: [.key(.right, count: 1)]
                    ))
                }
            }
            try await group.waitForAll()
        }
        var commands = await store.commands()
        XCTAssertEqual(commands.count, 20)
        XCTAssertEqual(commands.map(\.order), Array(0..<20))

        let first = commands[0].id
        let second = commands[1].id
        _ = try await store.deleteCommand(id: first)
        _ = try await store.deleteCommand(id: second)
        commands = try await store.undoDelete()
        XCTAssertFalse(commands.contains { $0.id == first })
        XCTAssertTrue(commands.contains { $0.id == second })
        XCTAssertEqual(commands.map(\.order), Array(0..<19))

        let file = try JSONDecoder.vizio.decode(
            StoreFile.self,
            from: Data(contentsOf: directory.appendingPathComponent("viziocontrol.json"))
        )
        XCTAssertEqual(file.commands.count, 19)
        XCTAssertEqual(file.commands.map(\.order), Array(0..<19))
    }

    func testSettingsAndDevicePersistWithoutAnyTokenField() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        _ = try await store.load()
        _ = try await store.updateSettings(AppSettings(
            manualAddress: "192.168.1.20",
            manualMACAddress: "A8:C9:6B:12:34:56"
        ))
        try await store.setDevice(PairedDevice(
            id: "tv",
            name: "Family Room",
            endpoint: DeviceEndpoint(host: "192.168.1.21", resolvedAddresses: ["192.168.1.21"]),
            model: "M55",
            serial: "SERIAL",
            fingerprint: String(repeating: "AA", count: 32),
            macAddress: "A8:C9:6B:12:34:56",
            deviceID: "client-account",
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let json = try String(
            contentsOf: directory.appendingPathComponent("viziocontrol.json"),
            encoding: .utf8
        )
        XCTAssertTrue(json.contains("client-account"))
        XCTAssertFalse(json.lowercased().contains("token"))
        XCTAssertFalse(json.contains("secret-token-value"))
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.device?.serial, "SERIAL")
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("VizioControlTests-\(UUID().uuidString)", isDirectory: true)
}

private func savedCommand(
    id: UUID = UUID(),
    label: String,
    normalized: String,
    order: Int,
    usage: Int,
    date: Date,
    actions: [TVAction]
) -> SavedCommand {
    SavedCommand(
        id: id,
        label: label,
        systemImage: "circle",
        normalizedRequest: normalized,
        order: order,
        usageCount: usage,
        createdAt: date,
        updatedAt: date,
        actions: actions
    )
}

private extension JSONDecoder {
    static var vizio: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
