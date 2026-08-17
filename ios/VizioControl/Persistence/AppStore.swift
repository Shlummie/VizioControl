import Foundation

public struct StoreFile: Codable, Equatable, Sendable {
    public var version: Int
    public var settings: AppSettings
    public var device: PairedDevice?
    public var commands: [SavedCommand]

    public init(
        version: Int = 1,
        settings: AppSettings = AppSettings(),
        device: PairedDevice? = nil,
        commands: [SavedCommand] = []
    ) {
        self.version = version
        self.settings = settings
        self.device = device
        self.commands = commands
    }
}

public protocol AppStoring: Actor {
    func load() throws -> StoreFile
    func snapshot() -> StoreFile
    func updateSettings(_ settings: AppSettings) throws -> AppSettings
    func updateSettingsAndDevice(settings: AppSettings, device: PairedDevice?) throws
    func setDevice(_ device: PairedDevice?) throws
    func command(id: UUID) -> SavedCommand?
    func commands() -> [SavedCommand]
    func upsertCommand(_ command: SavedCommand) throws -> [SavedCommand]
    func editCommand(id: UUID, label: String, updatedAt: Date) throws -> [SavedCommand]
    func duplicateCommand(id: UUID, at date: Date) throws -> [SavedCommand]
    func deleteCommand(id: UUID) throws -> [SavedCommand]
    func undoDelete() throws -> [SavedCommand]
    func reorderCommand(id: UUID, direction: Int) throws -> [SavedCommand]
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
    private var deletedCommand: SavedCommand?

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
            deletedCommand = nil
            try persist()
            return snapshot()
        } catch {
            try recoverCorruptFile()
            return snapshot()
        }

        let decoded: StoreFile
        do {
            decoded = try decoder().decode(StoreFile.self, from: storedData)
            guard decoded.version == 1 else { throw StoreError.unsupportedVersion }
        } catch {
            try recoverCorruptFile()
            return snapshot()
        }
        data = decoded
        data.commands = normalizeOrder(data.commands)
        deletedCommand = nil
        if try encoder().encode(data) != storedData { try persist() }
        return snapshot()
    }

    public func snapshot() -> StoreFile {
        var snapshot = data
        snapshot.commands = sortedCommands(snapshot.commands)
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

    public func command(id: UUID) -> SavedCommand? {
        data.commands.first { $0.id == id }
    }

    public func commands() -> [SavedCommand] {
        sortedCommands(data.commands)
    }

    @discardableResult
    public func upsertCommand(_ command: SavedCommand) throws -> [SavedCommand] {
        try mutate {
            if let index = data.commands.firstIndex(where: {
                $0.id == command.id || $0.normalizedRequest == command.normalizedRequest
            }) {
                let existing = data.commands[index]
                var updated = command
                updated.id = existing.id
                updated.order = existing.order
                updated.createdAt = existing.createdAt
                updated.usageCount = existing.usageCount + 1
                data.commands[index] = updated
            } else {
                var inserted = command
                inserted.order = data.commands.count
                inserted.usageCount = 1
                data.commands.append(inserted)
            }
            data.commands = normalizeOrder(data.commands)
        }
        return commands()
    }

    @discardableResult
    public func editCommand(id: UUID, label: String, updatedAt: Date = Date()) throws -> [SavedCommand] {
        guard let index = data.commands.firstIndex(where: { $0.id == id }) else {
            throw VizioControlError.message("Saved command not found.")
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VizioControlError.message("Saved command label cannot be empty.")
        }
        try mutate {
            data.commands[index].label = String(trimmed.prefix(40))
            data.commands[index].updatedAt = updatedAt
        }
        return commands()
    }

    @discardableResult
    public func duplicateCommand(id: UUID, at date: Date = Date()) throws -> [SavedCommand] {
        guard let source = data.commands.first(where: { $0.id == id }) else {
            throw VizioControlError.message("Saved command not found.")
        }
        let duplicateID = UUID()
        let duplicate = SavedCommand(
            id: duplicateID,
            label: "\(source.label) copy",
            systemImage: source.systemImage,
            normalizedRequest: "\(source.normalizedRequest)-copy-\(duplicateID.uuidString.lowercased())",
            order: data.commands.count,
            usageCount: 0,
            createdAt: date,
            updatedAt: date,
            actions: source.actions
        )
        try mutate {
            data.commands.append(duplicate)
            data.commands = normalizeOrder(data.commands)
        }
        return commands()
    }

    @discardableResult
    public func deleteCommand(id: UUID) throws -> [SavedCommand] {
        guard let index = data.commands.firstIndex(where: { $0.id == id }) else { return commands() }
        try mutate {
            deletedCommand = data.commands.remove(at: index)
            data.commands = normalizeOrder(data.commands)
        }
        return commands()
    }

    @discardableResult
    public func undoDelete() throws -> [SavedCommand] {
        guard let deletedCommand else { return commands() }
        let insertionOrder = max(0, min(deletedCommand.order, data.commands.count))
        try mutate {
            for index in data.commands.indices where data.commands[index].order >= insertionOrder {
                data.commands[index].order += 1
            }
            var restored = deletedCommand
            restored.order = insertionOrder
            data.commands.append(restored)
            self.deletedCommand = nil
            data.commands = normalizeOrder(data.commands)
        }
        return commands()
    }

    @discardableResult
    public func reorderCommand(id: UUID, direction: Int) throws -> [SavedCommand] {
        guard direction == -1 || direction == 1 else { return commands() }
        var ordered = sortedCommands(data.commands)
        guard let index = ordered.firstIndex(where: { $0.id == id }) else {
            throw VizioControlError.message("Saved command not found.")
        }
        let target = index + direction
        guard ordered.indices.contains(target) else { return ordered }
        try mutate {
            ordered.swapAt(index, target)
            for position in ordered.indices { ordered[position].order = position }
            data.commands = ordered
        }
        return commands()
    }

    private func mutate(_ operation: () throws -> Void) throws {
        let previousData = data
        let previousDeletedCommand = deletedCommand
        do {
            try operation()
            try persist()
        } catch {
            data = previousData
            deletedCommand = previousDeletedCommand
            throw error
        }
    }

    private func persist() throws {
        data.version = 1
        data.commands = normalizeOrder(data.commands)
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
        deletedCommand = nil
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

    private func normalizeOrder(_ commands: [SavedCommand]) -> [SavedCommand] {
        sortedCommands(commands).enumerated().map { order, command in
            var command = command
            command.order = order
            return command
        }
    }

    private func sortedCommands(_ commands: [SavedCommand]) -> [SavedCommand] {
        commands.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

private enum StoreError: Error {
    case unsupportedVersion
}
