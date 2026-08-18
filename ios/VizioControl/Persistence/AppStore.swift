import Foundation

public struct StoreFile: Codable, Equatable, Sendable {
    public var version: Int
    public var settings: AppSettings
    public var device: PairedDevice?
    public var macros: [SavedMacro]

    public init(
        version: Int = 2,
        settings: AppSettings = AppSettings(),
        device: PairedDevice? = nil,
        macros: [SavedMacro] = []
    ) {
        self.version = version
        self.settings = settings
        self.device = device
        self.macros = macros
    }
}

public protocol AppStoring: Actor {
    func load() throws -> StoreFile
    func snapshot() -> StoreFile
    func updateSettings(_ settings: AppSettings) throws -> AppSettings
    func updateSettingsAndDevice(settings: AppSettings, device: PairedDevice?) throws
    func setDevice(_ device: PairedDevice?) throws
    func macros() -> [SavedMacro]
    func insertMacro(_ macro: SavedMacro) throws -> [SavedMacro]
    func updateMacro(id: UUID, name: String, actions: [TVAction], updatedAt: Date) throws -> [SavedMacro]
    func recordMacroRun(id: UUID, at date: Date) throws -> [SavedMacro]
    func duplicateMacro(id: UUID, at date: Date) throws -> [SavedMacro]
    func deleteMacro(id: UUID) throws -> [SavedMacro]
    func undoDeleteMacro() throws -> [SavedMacro]
    func reorderMacro(id: UUID, direction: Int) throws -> [SavedMacro]
}

public actor AppStore: AppStoring {
    public static let applicationSupportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("VizioControl", isDirectory: true)
    }()

    private let directory: URL
    private let storeURL: URL
    private var data = StoreFile()
    private var deletedMacro: SavedMacro?

    public init(directory: URL = AppStore.applicationSupportDirectory) {
        self.directory = directory
        storeURL = directory.appendingPathComponent("viziocontrol.json", isDirectory: false)
    }

    @discardableResult
    public func load() throws -> StoreFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storedData: Data
        do {
            storedData = try Data(contentsOf: storeURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            data = StoreFile()
            deletedMacro = nil
            try persist()
            return snapshot()
        } catch {
            try recoverCorruptFile()
            return snapshot()
        }

        let version: Int
        do {
            version = try decoder().decode(StoreVersion.self, from: storedData).version
        } catch {
            try recoverCorruptFile()
            return snapshot()
        }

        switch version {
        case 1:
            let legacy: LegacyStoreFile
            do {
                legacy = try decoder().decode(LegacyStoreFile.self, from: storedData)
            } catch {
                try recoverCorruptFile()
                return snapshot()
            }
            data = StoreFile(
                settings: legacy.settings,
                device: legacy.device,
                macros: normalizeOrder(legacy.legacyMacros.map(migrateLegacyRecord))
            )
            deletedMacro = nil
            try persist()
            return snapshot()
        case 2:
            let decoded: StoreFile
            do {
                decoded = try decoder().decode(StoreFile.self, from: storedData)
            } catch {
                try recoverCorruptFile()
                return snapshot()
            }
            data = decoded
            data.macros = normalizeOrder(data.macros)
            deletedMacro = nil
            if try encoder().encode(data) != storedData { try persist() }
            return snapshot()
        default:
            try recoverCorruptFile()
            return snapshot()
        }
    }

    public func snapshot() -> StoreFile {
        var snapshot = data
        snapshot.macros = sortedMacros(snapshot.macros)
        return snapshot
    }

    @discardableResult
    public func updateSettings(_ settings: AppSettings) throws -> AppSettings {
        try mutate { data.settings = settings }
        return data.settings
    }

    public func updateSettingsAndDevice(settings: AppSettings, device: PairedDevice?) throws {
        try mutate {
            data.settings = settings
            data.device = device
        }
    }

    public func setDevice(_ device: PairedDevice?) throws {
        try mutate { data.device = device }
    }

    public func macros() -> [SavedMacro] {
        sortedMacros(data.macros)
    }

    @discardableResult
    public func insertMacro(_ macro: SavedMacro) throws -> [SavedMacro] {
        guard !data.macros.contains(where: { $0.id == macro.id }) else {
            throw VizioControlError.message("Macro already exists.")
        }
        try mutate {
            var inserted = macro
            inserted.order = data.macros.count
            inserted.usageCount = 0
            data.macros.append(inserted)
            data.macros = normalizeOrder(data.macros)
        }
        return macros()
    }

    @discardableResult
    public func updateMacro(
        id: UUID,
        name: String,
        actions: [TVAction],
        updatedAt: Date
    ) throws -> [SavedMacro] {
        guard let index = data.macros.firstIndex(where: { $0.id == id }) else {
            throw VizioControlError.message("Saved macro not found.")
        }
        try mutate {
            data.macros[index].name = name
            data.macros[index].actions = actions
            data.macros[index].updatedAt = updatedAt
        }
        return macros()
    }

    @discardableResult
    public func recordMacroRun(id: UUID, at date: Date) throws -> [SavedMacro] {
        guard let index = data.macros.firstIndex(where: { $0.id == id }) else {
            throw VizioControlError.message("Saved macro not found.")
        }
        try mutate {
            data.macros[index].usageCount += 1
            data.macros[index].updatedAt = date
        }
        return macros()
    }

    @discardableResult
    public func duplicateMacro(id: UUID, at date: Date) throws -> [SavedMacro] {
        guard let source = data.macros.first(where: { $0.id == id }) else {
            throw VizioControlError.message("Saved macro not found.")
        }
        let suffix = " copy"
        let sourceLimit = MacroConstraints.maximumNameLength - suffix.count
        let duplicate = SavedMacro(
            name: String(source.name.prefix(sourceLimit)) + suffix,
            order: data.macros.count,
            usageCount: 0,
            createdAt: date,
            updatedAt: date,
            actions: source.actions
        )
        try mutate {
            data.macros.append(duplicate)
            data.macros = normalizeOrder(data.macros)
        }
        return macros()
    }

    @discardableResult
    public func deleteMacro(id: UUID) throws -> [SavedMacro] {
        guard let index = data.macros.firstIndex(where: { $0.id == id }) else { return macros() }
        try mutate {
            deletedMacro = data.macros.remove(at: index)
            data.macros = normalizeOrder(data.macros)
        }
        return macros()
    }

    @discardableResult
    public func undoDeleteMacro() throws -> [SavedMacro] {
        guard let deletedMacro else { return macros() }
        let insertionOrder = max(0, min(deletedMacro.order, data.macros.count))
        try mutate {
            for index in data.macros.indices where data.macros[index].order >= insertionOrder {
                data.macros[index].order += 1
            }
            var restored = deletedMacro
            restored.order = insertionOrder
            data.macros.append(restored)
            self.deletedMacro = nil
            data.macros = normalizeOrder(data.macros)
        }
        return macros()
    }

    @discardableResult
    public func reorderMacro(id: UUID, direction: Int) throws -> [SavedMacro] {
        guard direction == -1 || direction == 1 else { return macros() }
        var ordered = sortedMacros(data.macros)
        guard let index = ordered.firstIndex(where: { $0.id == id }) else {
            throw VizioControlError.message("Saved macro not found.")
        }
        let target = index + direction
        guard ordered.indices.contains(target) else { return ordered }
        try mutate {
            ordered.swapAt(index, target)
            for position in ordered.indices { ordered[position].order = position }
            data.macros = ordered
        }
        return macros()
    }

    private func mutate(_ operation: () throws -> Void) throws {
        let previousData = data
        let previousDeletedMacro = deletedMacro
        do {
            try operation()
            try persist()
        } catch {
            data = previousData
            deletedMacro = previousDeletedMacro
            throw error
        }
    }

    private func persist() throws {
        data.version = 2
        data.macros = normalizeOrder(data.macros)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder().encode(data).write(to: storeURL, options: .atomic)
    }

    private func recoverCorruptFile() throws {
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let epoch = Int(Date().timeIntervalSince1970 * 1_000)
            let corruptURL = directory.appendingPathComponent("viziocontrol.json.corrupt-\(epoch)")
            try FileManager.default.moveItem(at: storeURL, to: corruptURL)
        }
        data = StoreFile()
        deletedMacro = nil
        try persist()
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func migrateLegacyRecord(_ record: LegacyMacroRecord) -> SavedMacro {
        let trimmedName = record.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? "Saved macro" : String(
            trimmedName.prefix(MacroConstraints.maximumNameLength)
        )
        return SavedMacro(
            id: record.id,
            name: name,
            order: record.order,
            usageCount: record.usageCount,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            actions: record.actions
        )
    }

    private func normalizeOrder(_ macros: [SavedMacro]) -> [SavedMacro] {
        sortedMacros(macros).enumerated().map { order, macro in
            var macro = macro
            macro.order = order
            return macro
        }
    }

    private func sortedMacros(_ macros: [SavedMacro]) -> [SavedMacro] {
        macros.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

private struct StoreVersion: Decodable {
    let version: Int
}

private struct LegacyStoreFile: Decodable {
    let version: Int
    let settings: AppSettings
    let device: PairedDevice?
    let legacyMacros: [LegacyMacroRecord]

    private enum CodingKeys: String, CodingKey {
        case version
        case settings
        case device
        case legacyMacros = "commands"
    }
}

private struct LegacyMacroRecord: Decodable {
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
