import XCTest
@testable import VizioControl

final class MacroDefinitionTests: XCTestCase {
    private let validator = MacroDefinitionValidator()

    func testValidationTrimsNameAndCanonicalizesEverySupportedStepFamily() throws {
        let keyActions = TVKey.allCases.map { TVAction.key($0, count: 1) }
        let actions = keyActions + [
            .key(.left, count: 10),
            .setVolume(0),
            .setVolume(100),
            .launchApp("youtube"),
        ] + MacroDefinitionValidator.waitPresets.map { .wait(milliseconds: $0) }

        let definition = try validator.validate(name: "  Movie night\n", actions: actions)

        XCTAssertEqual(definition.name, "Movie night")
        XCTAssertEqual(
            definition.actions,
            keyActions + [
                .key(.left, count: 10),
                .setVolume(0),
                .setVolume(100),
                .launchApp("YouTube"),
            ] + MacroDefinitionValidator.waitPresets.map { .wait(milliseconds: $0) }
        )
    }

    func testNameAndStepRequirementsEnforceUserVisibleBoundaries() throws {
        let maximumLengthName = String(repeating: "a", count: MacroConstraints.maximumNameLength)
        XCTAssertEqual(
            try validator.validate(name: maximumLengthName, actions: [.key(.ok, count: 1)]).name,
            maximumLengthName
        )

        try assertValidationError(name: " \n ", actions: [.key(.ok, count: 1)], message: "Macro name cannot be empty.")
        try assertValidationError(
            name: String(repeating: "a", count: MacroConstraints.maximumNameLength + 1),
            actions: [.key(.ok, count: 1)],
            message: "Macro name must be 40 characters or fewer."
        )
        try assertValidationError(name: "Empty", actions: [], message: "Add at least one step to the macro.")

        let maximumSteps = Array(
            repeating: TVAction.key(.right, count: 1),
            count: MacroConstraints.maximumStepCount
        )
        XCTAssertEqual(
            try validator.validate(name: "Maximum", actions: maximumSteps).actions.count,
            MacroConstraints.maximumStepCount
        )
        try assertValidationError(
            name: "Too many",
            actions: maximumSteps + [.key(.left, count: 1)],
            message: "A macro can contain at most 50 steps."
        )
    }

    func testInvalidActionValuesAreRejectedRatherThanClamped() throws {
        for count in [0, 11] {
            try assertValidationError(
                name: "Bad repeat",
                actions: [.key(.up, count: count)],
                message: "Key repeat count must be between 1 and 10."
            )
        }
        for volume in [-1, 101] {
            try assertValidationError(
                name: "Bad volume",
                actions: [.setVolume(volume)],
                message: "Volume must be between 0 and 100."
            )
        }
        try assertValidationError(
            name: "Bad wait",
            actions: [.wait(milliseconds: 750)],
            message: "Choose a supported wait duration."
        )
        try assertValidationError(
            name: "Bad app",
            actions: [.launchApp("Disney+")],
            message: "The local quick launcher does not contain “Disney+”. Use SmartCast Home to open it manually."
        )
    }

    func testActionPresentationCoversEveryKeyAndNonKeyFamily() {
        let keyCases: [(TVKey, String, String)] = [
            (.powerOff, "Standby", "power"),
            (.powerOn, "Power On", "power"),
            (.powerToggle, "Toggle Power", "power"),
            (.volumeDown, "Volume Down", "speaker.minus.fill"),
            (.volumeUp, "Volume Up", "speaker.plus.fill"),
            (.mute, "Mute", "speaker.slash.fill"),
            (.input, "Input", "cable.connector"),
            (.down, "Down", "chevron.down"),
            (.left, "Left", "chevron.left"),
            (.ok, "OK", "circle.inset.filled"),
            (.right, "Right", "chevron.right"),
            (.up, "Up", "chevron.up"),
            (.back, "Back", "arrow.uturn.backward"),
            (.home, "Home", "house.fill"),
            (.menu, "Menu", "line.3.horizontal"),
            (.exit, "Exit", "rectangle.portrait.and.arrow.right"),
            (.fastForward, "Fast Forward", "forward.fill"),
            (.rewind, "Rewind", "backward.fill"),
            (.pause, "Pause", "pause.fill"),
            (.play, "Play", "play.fill"),
        ]

        XCTAssertEqual(keyCases.count, TVKey.allCases.count)
        for (key, title, image) in keyCases {
            XCTAssertEqual(macroActionTitle(.key(key, count: 1)), title, key.rawValue)
            XCTAssertEqual(macroActionSystemImage(.key(key, count: 1)), image, key.rawValue)
        }
        XCTAssertEqual(macroActionTitle(.key(.up, count: 3)), "Up ×3")
        XCTAssertEqual(macroActionTitle(.setVolume(20)), "Set volume to 20")
        XCTAssertEqual(macroActionSystemImage(.setVolume(20)), "speaker.wave.2.fill")
        XCTAssertEqual(macroActionTitle(.launchApp("Hulu")), "Open Hulu")
        XCTAssertEqual(macroActionSystemImage(.launchApp("Hulu")), "rectangle.stack.fill")
        XCTAssertEqual(macroActionSystemImage(.wait(milliseconds: 500)), "timer")
    }

    func testWaitTitlesAndSequenceSummaryRemainReadable() {
        let waits: [(Int, String)] = [
            (250, "Wait 250 milliseconds"),
            (500, "Wait 500 milliseconds"),
            (1_000, "Wait 1 second"),
            (2_000, "Wait 2 seconds"),
            (5_000, "Wait 5 seconds"),
        ]
        for (milliseconds, title) in waits {
            XCTAssertEqual(macroActionTitle(.wait(milliseconds: milliseconds)), title)
        }

        XCTAssertEqual(
            macroSequenceSummary([
                .key(.up, count: 1),
                .wait(milliseconds: 500),
                .launchApp("Netflix"),
            ]),
            "Up → Wait 500 milliseconds → Open Netflix"
        )
        XCTAssertEqual(
            macroSequencePreview([
                .key(.up, count: 1),
                .key(.left, count: 1),
                .key(.ok, count: 1),
            ]),
            "Up → Left → OK"
        )
        XCTAssertEqual(
            macroSequencePreview([
                .key(.up, count: 1),
                .key(.left, count: 1),
                .key(.ok, count: 1),
                .wait(milliseconds: 500),
                .launchApp("Netflix"),
                .key(.play, count: 1),
            ]),
            "Up → Left → OK → Wait 500 milliseconds → +2 more steps"
        )
    }

    private func assertValidationError(
        name: String,
        actions: [TVAction],
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        do {
            _ = try validator.validate(name: name, actions: actions)
            XCTFail("Expected validation to fail", file: file, line: line)
        } catch let error as VizioControlError {
            XCTAssertEqual(error.localizedDescription, message, file: file, line: line)
        }
    }
}
