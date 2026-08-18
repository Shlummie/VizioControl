import Foundation
import XCTest
@testable import VizioControl

final class AppStoreTests: XCTestCase, @unchecked Sendable {
    func testCorruptAndUnsupportedStateAreQuarantinedAndDefaultsPersisted() async throws {
        let payloads = [
            Data("not-json".utf8),
            Data(#"{"version":99}"#.utf8),
        ]

        for payload in payloads {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stateURL = directory.appendingPathComponent("viziocontrol.json")
            try payload.write(to: stateURL)

            let store = AppStore(directory: directory)
            let snapshot = try await store.load()

            XCTAssertEqual(snapshot, StoreFile())
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertTrue(names.contains("viziocontrol.json"))
            XCTAssertEqual(names.filter { $0.hasPrefix("viziocontrol.json.corrupt-") }.count, 1)
            let persisted = try JSONDecoder.vizio.decode(StoreFile.self, from: Data(contentsOf: stateURL))
            XCTAssertEqual(persisted, StoreFile())
        }
    }

    func testMacroInsertUpdateRunDuplicateOrderDeleteUndoAndReload() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        _ = try await store.load()
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let first = savedMacro(
            id: firstID,
            name: "Movie night",
            order: 88,
            usage: 99,
            date: firstDate,
            actions: [.key(.mute, count: 1)]
        )

        var macros = try await store.insertMacro(first)
        XCTAssertEqual(macros.count, 1)
        XCTAssertEqual(macros[0].order, 0)
        XCTAssertEqual(macros[0].usageCount, 0)

        do {
            _ = try await store.insertMacro(first)
            XCTFail("Expected duplicate UUID rejection")
        } catch let error as VizioControlError {
            XCTAssertEqual(error.localizedDescription, "Macro already exists.")
        }
        let macrosAfterRejectedInsert = await store.macros()
        XCTAssertEqual(macrosAfterRejectedInsert, macros)

        let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let second = savedMacro(
            id: secondID,
            name: "Movie night",
            order: -4,
            usage: 12,
            date: Date(timeIntervalSince1970: 1_700_000_100),
            actions: [.key(.mute, count: 1)]
        )
        macros = try await store.insertMacro(second)
        XCTAssertEqual(macros.map(\.id), [firstID, secondID])
        XCTAssertEqual(macros.map(\.order), [0, 1])
        XCTAssertEqual(macros.map(\.usageCount), [0, 0])

        let updateDate = Date(timeIntervalSince1970: 1_700_000_200)
        let longName = String(repeating: "x", count: MacroConstraints.maximumNameLength)
        macros = try await store.updateMacro(
            id: firstID,
            name: longName,
            actions: [.key(.mute, count: 2), .wait(milliseconds: 500)],
            updatedAt: updateDate
        )
        XCTAssertEqual(macros[0].id, firstID)
        XCTAssertEqual(macros[0].name, longName)
        XCTAssertEqual(macros[0].actions, [.key(.mute, count: 2), .wait(milliseconds: 500)])
        XCTAssertEqual(macros[0].order, 0)
        XCTAssertEqual(macros[0].usageCount, 0)
        XCTAssertEqual(macros[0].createdAt, firstDate)
        XCTAssertEqual(macros[0].updatedAt, updateDate)

        let runDate = Date(timeIntervalSince1970: 1_700_000_300)
        macros = try await store.recordMacroRun(id: firstID, at: runDate)
        XCTAssertEqual(macros[0].usageCount, 1)
        XCTAssertEqual(macros[0].updatedAt, runDate)

        let duplicateDate = Date(timeIntervalSince1970: 1_700_000_400)
        macros = try await store.duplicateMacro(id: firstID, at: duplicateDate)
        let duplicate = try XCTUnwrap(macros.last)
        XCTAssertNotEqual(duplicate.id, firstID)
        XCTAssertEqual(
            duplicate.name,
            String(
                repeating: "x",
                count: MacroConstraints.maximumNameLength - " copy".count
            ) + " copy"
        )
        XCTAssertEqual(duplicate.actions, macros[0].actions)
        XCTAssertEqual(duplicate.usageCount, 0)
        XCTAssertEqual(duplicate.order, 2)
        XCTAssertEqual(duplicate.createdAt, duplicateDate)
        XCTAssertEqual(duplicate.updatedAt, duplicateDate)

        macros = try await store.reorderMacro(id: duplicate.id, direction: -1)
        XCTAssertEqual(macros.map(\.id), [firstID, duplicate.id, secondID])
        macros = try await store.deleteMacro(id: duplicate.id)
        XCTAssertEqual(macros.map(\.id), [firstID, secondID])
        macros = try await store.deleteMacro(id: UUID())
        XCTAssertEqual(macros.map(\.id), [firstID, secondID])
        macros = try await store.undoDeleteMacro()
        XCTAssertEqual(macros.map(\.id), [firstID, duplicate.id, secondID])
        macros = try await store.undoDeleteMacro()
        XCTAssertEqual(macros.map(\.id), [firstID, duplicate.id, secondID])

        let reloaded = AppStore(directory: directory)
        let persisted = try await reloaded.load()
        XCTAssertEqual(persisted.macros, macros)
    }

    func testVersionOneRecordsMigrateInPlaceAsRepairableMacros() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("viziocontrol.json")
        let firstID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let secondID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let firstDate = Date(timeIntervalSince1970: 1_700_010_000)
        let secondDate = Date(timeIntervalSince1970: 1_700_020_000)
        let fixture = VersionOneStoreFixture(
            version: 1,
            settings: AppSettings(manualAddress: "192.0.2.10", manualMACAddress: ""),
            device: nil,
            legacyMacros: [
                VersionOneMacroFixture(
                    id: firstID,
                    label: "   ",
                    systemImage: "speaker.slash.fill",
                    normalizedRequest: "mute",
                    order: 7,
                    usageCount: 3,
                    createdAt: firstDate,
                    updatedAt: firstDate,
                    actions: []
                ),
                VersionOneMacroFixture(
                    id: secondID,
                    label: "  \(String(repeating: "A", count: MacroConstraints.maximumNameLength + 5))  ",
                    systemImage: "house.fill",
                    normalizedRequest: "home",
                    order: -2,
                    usageCount: 5,
                    createdAt: secondDate,
                    updatedAt: secondDate,
                    actions: [.key(.home, count: 1)]
                ),
            ]
        )
        try JSONEncoder.vizio.encode(fixture).write(to: stateURL)

        let migrated = try await AppStore(directory: directory).load()

        XCTAssertEqual(migrated.version, 2)
        XCTAssertEqual(migrated.settings.manualAddress, "192.0.2.10")
        XCTAssertEqual(migrated.macros.map(\.id), [secondID, firstID])
        XCTAssertEqual(migrated.macros.map(\.order), [0, 1])
        XCTAssertEqual(
            migrated.macros[0].name,
            String(repeating: "A", count: MacroConstraints.maximumNameLength)
        )
        XCTAssertEqual(migrated.macros[0].usageCount, 5)
        XCTAssertEqual(migrated.macros[0].createdAt, secondDate)
        XCTAssertEqual(migrated.macros[0].actions, [.key(.home, count: 1)])
        XCTAssertEqual(migrated.macros[1].name, "Saved macro")
        XCTAssertEqual(migrated.macros[1].usageCount, 3)
        XCTAssertTrue(migrated.macros[1].actions.isEmpty)

        let persistedJSON = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertTrue(persistedJSON.contains(#""version" : 2"#))
        XCTAssertTrue(persistedJSON.contains(#""macros""#))
        XCTAssertFalse(persistedJSON.contains(#""commands""#))
        XCTAssertFalse(persistedJSON.contains("normalizedRequest"))
        XCTAssertEqual(try JSONDecoder.vizio.decode(StoreFile.self, from: Data(contentsOf: stateURL)), migrated)
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
                    _ = try await store.insertMacro(savedMacro(
                        name: "Macro \(index)",
                        order: index,
                        usage: 0,
                        date: date,
                        actions: [.key(.right, count: 1)]
                    ))
                }
            }
            try await group.waitForAll()
        }
        var macros = await store.macros()
        XCTAssertEqual(macros.count, 20)
        XCTAssertEqual(macros.map(\.order), Array(0..<20))

        let first = macros[0].id
        let second = macros[1].id
        _ = try await store.deleteMacro(id: first)
        _ = try await store.deleteMacro(id: second)
        macros = try await store.undoDeleteMacro()
        XCTAssertFalse(macros.contains { $0.id == first })
        XCTAssertTrue(macros.contains { $0.id == second })
        XCTAssertEqual(macros.map(\.order), Array(0..<19))

        let file = try JSONDecoder.vizio.decode(
            StoreFile.self,
            from: Data(contentsOf: directory.appendingPathComponent("viziocontrol.json"))
        )
        XCTAssertEqual(file.macros.count, 19)
        XCTAssertEqual(file.macros.map(\.order), Array(0..<19))
    }

    func testFailedPersistenceRollsBackInMemoryMutation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("viziocontrol.json")
        let store = AppStore(directory: directory)
        _ = try await store.load()
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)

        do {
            _ = try await store.insertMacro(savedMacro(
                name: "Must roll back",
                order: 0,
                usage: 0,
                date: Date(timeIntervalSince1970: 1_700_030_000),
                actions: [.key(.ok, count: 1)]
            ))
            XCTFail("Expected persistence failure")
        } catch {
            let macrosAfterFailedInsert = await store.macros()
            XCTAssertTrue(macrosAfterFailedInsert.isEmpty)
        }
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

private func savedMacro(
    id: UUID = UUID(),
    name: String,
    order: Int,
    usage: Int,
    date: Date,
    actions: [TVAction]
) -> SavedMacro {
    SavedMacro(
        id: id,
        name: name,
        order: order,
        usageCount: usage,
        createdAt: date,
        updatedAt: date,
        actions: actions
    )
}

private struct VersionOneStoreFixture: Encodable {
    let version: Int
    let settings: AppSettings
    let device: PairedDevice?
    let legacyMacros: [VersionOneMacroFixture]

    private enum CodingKeys: String, CodingKey {
        case version
        case settings
        case device
        case legacyMacros = "commands"
    }
}

private struct VersionOneMacroFixture: Encodable {
    let id: UUID
    let label: String
    let systemImage: String
    let normalizedRequest: String
    let order: Int
    let usageCount: Int
    let createdAt: Date
    let updatedAt: Date
    let actions: [TVAction]
}

private extension JSONDecoder {
    static var vizio: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var vizio: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
