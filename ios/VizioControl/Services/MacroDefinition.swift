import Foundation

public struct MacroDefinition: Equatable, Sendable {
    public let name: String
    public let actions: [TVAction]

    public init(name: String, actions: [TVAction]) {
        self.name = name
        self.actions = actions
    }
}

public enum MacroConstraints {
    public static let maximumNameLength = 40
    public static let maximumStepCount = 50
}

public struct MacroDefinitionValidator: Sendable {
    public static let waitPresets: [Int] = [250, 500, 1_000, 2_000, 5_000]

    private let catalog: any AppCataloging

    public init(catalog: any AppCataloging = AppCatalog()) {
        self.catalog = catalog
    }

    public func validate(name: String, actions: [TVAction]) throws -> MacroDefinition {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw VizioControlError.message("Macro name cannot be empty.")
        }
        guard trimmedName.count <= MacroConstraints.maximumNameLength else {
            throw VizioControlError.message(
                "Macro name must be \(MacroConstraints.maximumNameLength) characters or fewer."
            )
        }
        guard !actions.isEmpty else {
            throw VizioControlError.message("Add at least one step to the macro.")
        }
        guard actions.count <= MacroConstraints.maximumStepCount else {
            throw VizioControlError.message(
                "A macro can contain at most \(MacroConstraints.maximumStepCount) steps."
            )
        }

        var canonicalActions: [TVAction] = []
        canonicalActions.reserveCapacity(actions.count)
        for action in actions {
            switch action {
            case let .key(key, count):
                guard (1...10).contains(count) else {
                    throw VizioControlError.message("Key repeat count must be between 1 and 10.")
                }
                canonicalActions.append(.key(key, count: count))
            case let .setVolume(volume):
                guard (0...100).contains(volume) else {
                    throw VizioControlError.message("Volume must be between 0 and 100.")
                }
                canonicalActions.append(.setVolume(volume))
            case let .launchApp(name):
                let configuration = try catalog.resolve(name)
                canonicalActions.append(.launchApp(configuration.name))
            case let .wait(milliseconds):
                guard Self.waitPresets.contains(milliseconds) else {
                    throw VizioControlError.message("Choose a supported wait duration.")
                }
                canonicalActions.append(.wait(milliseconds: milliseconds))
            }
        }

        return MacroDefinition(name: trimmedName, actions: canonicalActions)
    }
}

public func macroActionTitle(_ action: TVAction) -> String {
    switch action {
    case let .key(key, count):
        let title = macroKeyTitle(key)
        return count > 1 ? "\(title) ×\(count)" : title
    case let .setVolume(volume):
        return "Set volume to \(volume)"
    case let .launchApp(name):
        return "Open \(name)"
    case let .wait(milliseconds):
        switch milliseconds {
        case 1_000:
            return "Wait 1 second"
        case 2_000:
            return "Wait 2 seconds"
        case 5_000:
            return "Wait 5 seconds"
        default:
            return "Wait \(milliseconds) milliseconds"
        }
    }
}

public func macroActionSystemImage(_ action: TVAction) -> String {
    switch action {
    case let .key(key, _):
        return macroKeySystemImage(key)
    case .setVolume:
        return "speaker.wave.2.fill"
    case .launchApp:
        return "rectangle.stack.fill"
    case .wait:
        return "timer"
    }
}

public func macroSequenceSummary(_ actions: [TVAction]) -> String {
    actions.map(macroActionTitle).joined(separator: " → ")
}

public func macroSequencePreview(
    _ actions: [TVAction],
    maximumVisibleSteps: Int = 4
) -> String {
    precondition(maximumVisibleSteps > 0)
    guard actions.count > maximumVisibleSteps else {
        return macroSequenceSummary(actions)
    }
    let visible = actions.prefix(maximumVisibleSteps).map(macroActionTitle).joined(separator: " → ")
    let remaining = actions.count - maximumVisibleSteps
    let suffix = remaining == 1 ? "+1 more step" : "+\(remaining) more steps"
    return "\(visible) → \(suffix)"
}

private func macroKeyTitle(_ key: TVKey) -> String {
    switch key {
    case .powerOff:
        return "Standby"
    case .powerOn:
        return "Power On"
    case .powerToggle:
        return "Toggle Power"
    case .volumeDown:
        return "Volume Down"
    case .volumeUp:
        return "Volume Up"
    case .mute:
        return "Mute"
    case .input:
        return "Input"
    case .down:
        return "Down"
    case .left:
        return "Left"
    case .ok:
        return "OK"
    case .right:
        return "Right"
    case .up:
        return "Up"
    case .back:
        return "Back"
    case .home:
        return "Home"
    case .menu:
        return "Menu"
    case .exit:
        return "Exit"
    case .fastForward:
        return "Fast Forward"
    case .rewind:
        return "Rewind"
    case .pause:
        return "Pause"
    case .play:
        return "Play"
    }
}

private func macroKeySystemImage(_ key: TVKey) -> String {
    switch key {
    case .powerOff, .powerOn, .powerToggle:
        return "power"
    case .volumeDown:
        return "speaker.minus.fill"
    case .volumeUp:
        return "speaker.plus.fill"
    case .mute:
        return "speaker.slash.fill"
    case .input:
        return "cable.connector"
    case .down:
        return "chevron.down"
    case .left:
        return "chevron.left"
    case .ok:
        return "circle.inset.filled"
    case .right:
        return "chevron.right"
    case .up:
        return "chevron.up"
    case .back:
        return "arrow.uturn.backward"
    case .home:
        return "house.fill"
    case .menu:
        return "line.3.horizontal"
    case .exit:
        return "rectangle.portrait.and.arrow.right"
    case .fastForward:
        return "forward.fill"
    case .rewind:
        return "backward.fill"
    case .pause:
        return "pause.fill"
    case .play:
        return "play.fill"
    }
}
