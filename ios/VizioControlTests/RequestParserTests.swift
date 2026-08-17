import XCTest
@testable import VizioControl

final class RequestParserTests: XCTestCase {
    private let parser = RequestParser()

    func testNormalizationAndEveryFixedKeyCommand() throws {
        XCTAssertEqual(normalizeRequest("  Turn—THE tv ON!! "), "turn the tv on")
        let cases: [(String, String, String, TVAction)] = [
            ("mute", "Mute", "speaker.slash.fill", .key(.mute, count: 1)),
            ("toggle mute", "Mute", "speaker.slash.fill", .key(.mute, count: 1)),
            ("mute the tv", "Mute", "speaker.slash.fill", .key(.mute, count: 1)),
            ("power on", "Power on", "power", .key(.powerOn, count: 1)),
            ("turn the tv on", "Power on", "power", .key(.powerOn, count: 1)),
            ("turn on tv", "Power on", "power", .key(.powerOn, count: 1)),
            ("power off", "Network standby", "power", .key(.powerOff, count: 1)),
            ("turn tv off", "Network standby", "power", .key(.powerOff, count: 1)),
            ("home", "SmartCast home", "house.fill", .key(.home, count: 1)),
            ("go home", "SmartCast home", "house.fill", .key(.home, count: 1)),
            ("smartcast", "SmartCast home", "house.fill", .key(.home, count: 1)),
            ("open smartcast", "SmartCast home", "house.fill", .key(.home, count: 1)),
            ("back", "Back", "arrow.uturn.backward", .key(.back, count: 1)),
            ("go back", "Back", "arrow.uturn.backward", .key(.back, count: 1)),
            ("menu", "Menu", "line.3.horizontal", .key(.menu, count: 1)),
            ("open menu", "Menu", "line.3.horizontal", .key(.menu, count: 1)),
            ("input", "Next input", "cable.connector", .key(.input, count: 1)),
            ("next input", "Next input", "cable.connector", .key(.input, count: 1)),
            ("change input", "Next input", "cable.connector", .key(.input, count: 1)),
            ("cycle input", "Next input", "cable.connector", .key(.input, count: 1)),
        ]
        for (request, label, symbol, action) in cases {
            let parsed = try parser.parse(request)
            XCTAssertEqual(parsed.normalizedRequest, normalizeRequest(request), request)
            XCTAssertEqual(parsed.label, label, request)
            XCTAssertEqual(parsed.systemImage, symbol, request)
            XCTAssertEqual(parsed.actions, [action], request)
        }
    }

    func testExactVolumeFormsClampToZeroThroughOneHundred() throws {
        let cases: [(String, Int)] = [
            ("volume 0", 0),
            ("set volume to 20", 20),
            ("set the volume at 47 percent", 47),
            ("the volume 100", 100),
            ("volume 999", 100),
        ]
        for (request, value) in cases {
            let parsed = try parser.parse(request)
            XCTAssertEqual(parsed.label, "Volume \(value)")
            XCTAssertEqual(parsed.systemImage, "speaker.wave.2.fill")
            XCTAssertEqual(parsed.actions, [.setVolume(value)])
        }
    }

    func testVolumeDirectionCountsNumericWordsAndUnknownSuffix() throws {
        let cases: [(String, TVKey, Int, String)] = [
            ("volume up", .volumeUp, 1, "Volume up"),
            ("turn the volume down twice", .volumeDown, 2, "Volume down ×2"),
            ("volume up once", .volumeUp, 1, "Volume up"),
            ("volume down one", .volumeDown, 1, "Volume down"),
            ("volume up three", .volumeUp, 3, "Volume up ×3"),
            ("volume down ten", .volumeDown, 10, "Volume down ×10"),
            ("volume up 99", .volumeUp, 10, "Volume up ×10"),
            ("volume down 0", .volumeDown, 1, "Volume down"),
            ("volume up several", .volumeUp, 1, "Volume up"),
        ]
        for (request, key, count, label) in cases {
            let parsed = try parser.parse(request)
            XCTAssertEqual(parsed.label, label, request)
            XCTAssertEqual(parsed.systemImage, "speaker.wave.2.fill", request)
            XCTAssertEqual(parsed.actions, [.key(key, count: count)], request)
        }
        let countWords = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        ]
        for (word, count) in countWords {
            XCTAssertEqual(
                try parser.parse("volume down \(word)").actions,
                [.key(.volumeDown, count: count)]
            )
        }
    }

    func testQuickLaunchRequiresExactAllowlistedNameAfterOptionalWords() throws {
        let cases: [(String, String)] = [
            ("open Hulu", "Hulu"),
            ("launch the youtube app", "YouTube"),
            ("START NETFLIX APP!!!", "Netflix"),
        ]
        for (request, name) in cases {
            let parsed = try parser.parse(request)
            XCTAssertEqual(parsed.label, "Open \(name)")
            XCTAssertEqual(parsed.systemImage, "rectangle.on.rectangle")
            XCTAssertEqual(parsed.actions, [.launchApp(name)])
        }
        try assertLocalOnly("open Hu")
        try assertLocalOnly("launch the YouTube channel")
        try assertLocalOnly("start Disney app")
    }

    func testEmptyAndUnmatchedContentFailWithoutProducingCommand() throws {
        do {
            _ = try parser.parse("   ")
            XCTFail("Expected empty-request rejection")
        } catch let error as VizioControlError {
            XCTAssertEqual(error.localizedDescription, "Type a request for TV.")
        }
        try assertLocalOnly("play the latest episode")
        try assertLocalOnly("search for nature documentaries")
        try assertLocalOnly("volume sideways")
        try assertLocalOnly("set volume to twenty")
    }

    private func assertLocalOnly(_ request: String) throws {
        do {
            _ = try parser.parse(request)
            XCTFail("Expected local-only rejection for \(request)")
        } catch let error as VizioControlError {
            XCTAssertEqual(error.localizedDescription, RequestParser.localOnlyMessage)
        }
    }
}
