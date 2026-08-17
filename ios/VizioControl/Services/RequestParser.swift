import Foundation

public struct ParsedCommand: Equatable, Sendable {
    public var normalizedRequest: String
    public var label: String
    public var systemImage: String
    public var actions: [TVAction]

    public init(normalizedRequest: String, label: String, systemImage: String, actions: [TVAction]) {
        self.normalizedRequest = normalizedRequest
        self.label = label
        self.systemImage = systemImage
        self.actions = actions
    }
}

public protocol RequestParsing: Sendable {
    func parse(_ request: String) throws -> ParsedCommand
}

public struct RequestParser: RequestParsing, Sendable {
    public static let localOnlyMessage = "This iPhone version runs local TV commands only. Try “mute”, “set volume to 20”, or “open Hulu”."

    private let catalog: any AppCataloging

    public init(catalog: any AppCataloging = AppCatalog()) {
        self.catalog = catalog
    }

    public func parse(_ request: String) throws -> ParsedCommand {
        let prompt = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizeRequest(prompt)
        guard !normalized.isEmpty else {
            throw VizioControlError.message("Type a request for TV.")
        }

        if ["mute", "toggle mute", "mute the tv"].contains(normalized) {
            return command(normalized, "Mute", "speaker.slash.fill", [.key(.mute, count: 1)])
        }
        if ["power on", "turn tv on", "turn the tv on", "turn on tv"].contains(normalized) {
            return command(normalized, "Power on", "power", [.key(.powerOn, count: 1)])
        }
        if ["power off", "turn tv off", "turn the tv off", "turn off tv"].contains(normalized) {
            return command(normalized, "Network standby", "power", [.key(.powerOff, count: 1)])
        }
        if ["home", "go home", "smartcast", "open smartcast"].contains(normalized) {
            return command(normalized, "SmartCast home", "house.fill", [.key(.home, count: 1)])
        }
        if ["back", "go back"].contains(normalized) {
            return command(normalized, "Back", "arrow.uturn.backward", [.key(.back, count: 1)])
        }
        if ["menu", "open menu"].contains(normalized) {
            return command(normalized, "Menu", "line.3.horizontal", [.key(.menu, count: 1)])
        }
        if ["input", "next input", "change input", "cycle input"].contains(normalized) {
            return command(normalized, "Next input", "cable.connector", [.key(.input, count: 1)])
        }

        let tokens = normalized.split(separator: " ").map(String.init)
        if let volume = exactVolume(tokens) {
            return command(
                normalized,
                "Volume \(volume)",
                "speaker.wave.2.fill",
                [.setVolume(volume)]
            )
        }
        if let direction = volumeDirection(tokens) {
            let label = "Volume \(direction.up ? "up" : "down")"
                + (direction.count > 1 ? " ×\(direction.count)" : "")
            return command(
                normalized,
                label,
                "speaker.wave.2.fill",
                [.key(direction.up ? .volumeUp : .volumeDown, count: direction.count)]
            )
        }
        if let app = exactQuickApp(tokens) {
            return command(
                normalized,
                "Open \(app.name)",
                "rectangle.on.rectangle",
                [.launchApp(app.name)]
            )
        }

        throw VizioControlError.message(Self.localOnlyMessage)
    }

    private func exactVolume(_ input: [String]) -> Int? {
        var tokens = input
        if tokens.first == "set" { tokens.removeFirst() }
        if tokens.first == "the" { tokens.removeFirst() }
        guard tokens.first == "volume" else { return nil }
        tokens.removeFirst()
        if tokens.first == "to" || tokens.first == "at" { tokens.removeFirst() }
        guard let raw = tokens.first, let value = Int(raw) else { return nil }
        tokens.removeFirst()
        if tokens.first == "percent" { tokens.removeFirst() }
        guard tokens.isEmpty else { return nil }
        return min(100, max(0, value))
    }

    private func volumeDirection(_ input: [String]) -> (up: Bool, count: Int)? {
        var tokens = input
        if tokens.first == "turn" { tokens.removeFirst() }
        if tokens.first == "the" { tokens.removeFirst() }
        guard tokens.count >= 2,
              tokens.removeFirst() == "volume",
              let direction = tokens.first,
              direction == "up" || direction == "down" else { return nil }
        tokens.removeFirst()
        guard tokens.count <= 1 else { return nil }
        return (direction == "up", parseCount(tokens.first))
    }

    private func exactQuickApp(_ input: [String]) -> AppLaunchConfiguration? {
        guard let verb = input.first, ["open", "launch", "start"].contains(verb) else { return nil }
        var name = Array(input.dropFirst())
        if name.first == "the" { name.removeFirst() }
        if name.last == "app" { name.removeLast() }
        guard !name.isEmpty else { return nil }
        let candidate = name.joined(separator: " ")
        return catalog.configurations.first { normalizeRequest($0.name) == candidate }
    }

    private func parseCount(_ value: String?) -> Int {
        guard let value else { return 1 }
        if let number = Int(value) { return min(10, max(1, number)) }
        return [
            "once": 1,
            "one": 1,
            "twice": 2,
            "two": 2,
            "three": 3,
            "four": 4,
            "five": 5,
            "six": 6,
            "seven": 7,
            "eight": 8,
            "nine": 9,
            "ten": 10,
        ][value] ?? 1
    }

    private func command(
        _ normalized: String,
        _ label: String,
        _ systemImage: String,
        _ actions: [TVAction]
    ) -> ParsedCommand {
        ParsedCommand(
            normalizedRequest: normalized,
            label: label,
            systemImage: systemImage,
            actions: actions
        )
    }
}

public func normalizeRequest(_ value: String) -> String {
    let mapped = value.lowercased().unicodeScalars.map { scalar -> Character in
        let code = scalar.value
        let isLetter = (97...122).contains(code)
        let isNumber = (48...57).contains(code)
        return isLetter || isNumber ? Character(String(scalar)) : " "
    }
    return String(mapped)
        .split(whereSeparator: \Character.isWhitespace)
        .joined(separator: " ")
}
