import XCTest

final class MacroBuilderUITests: XCTestCase {
    @MainActor
    func testCreateRelaunchAndEditThreeStepMacro() throws {
        let app = XCUIApplication()
        app.launchEnvironment["VIZIO_UI_TEST_ID"] = UUID().uuidString
        app.launchArguments = ["--ui-testing", "--ui-testing-reset"]
        app.launch()
        addTeardownBlock { app.terminate() }

        swipeToMacros(in: app)

        let createButton = app.buttons["macro.create"]
        reveal(createButton, in: app)
        createButton.tap()

        let nameField = app.textFields["macro.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Restart episode")
        dismissKeyboard(in: app)

        addStep("macro.step.navigation.up", in: app)
        addStep("macro.step.navigation.left", in: app)
        addStep("macro.step.navigation.ok", in: app)

        let saveButton = app.buttons["macro.save"]
        reveal(saveButton, in: app)
        saveButton.tap()

        let macroTitle = app.staticTexts["Restart episode"]
        XCTAssertTrue(macroTitle.waitForExistence(timeout: 5))
        reveal(macroTitle, in: app)
        XCTAssertTrue(app.staticTexts["Runs 0"].exists)

        let secondBuilder = app.buttons["macro.create"]
        reveal(secondBuilder, in: app)
        secondBuilder.tap()
        XCTAssertTrue(app.textFields["macro.name"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Restart episode saved."].exists)
        app.buttons["macro.editor.cancel"].tap()
        XCTAssertTrue(macroTitle.waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        swipeToMacros(in: app)

        let persistedTitle = app.staticTexts["Restart episode"]
        XCTAssertTrue(persistedTitle.waitForExistence(timeout: 5))
        reveal(persistedTitle, in: app)
        XCTAssertTrue(app.staticTexts["Runs 0"].exists)

        let editButton = app.buttons["Edit Restart episode"]
        XCTAssertTrue(editButton.isHittable)
        editButton.tap()

        let persistedNameField = app.textFields["macro.name"]
        XCTAssertTrue(persistedNameField.waitForExistence(timeout: 5))
        XCTAssertEqual(persistedNameField.value as? String, "Restart episode")
        XCTAssertTrue(app.staticTexts["Up → Left → OK"].exists)
        XCTAssertTrue(app.staticTexts["Up"].exists)
        XCTAssertTrue(app.staticTexts["Left"].exists)
        XCTAssertTrue(app.staticTexts["OK"].exists)
    }

    @MainActor
    private func swipeToMacros(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let remoteTab = app.buttons["remote.tab.remote"]
        let macrosTab = app.buttons["remote.tab.macros"]
        XCTAssertTrue(remoteTab.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(macrosTab.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(remoteTab.isSelected, file: file, line: line)

        app.swipeLeft()

        XCTAssertTrue(macrosTab.isSelected, file: file, line: line)
        XCTAssertFalse(remoteTab.isSelected, file: file, line: line)
        XCTAssertTrue(
            app.buttons["macro.create"].waitForExistence(timeout: 5),
            file: file,
            line: line
        )
    }

    @MainActor
    private func addStep(_ identifier: String, in app: XCUIApplication) {
        let addButton = app.buttons["macro.addStep"]
        reveal(addButton, in: app)
        addButton.tap()

        let option = app.buttons[identifier]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Missing step option \(identifier)")
        option.tap()
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
    }

    @MainActor
    private func reveal(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<12 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "Element did not become hittable", file: file, line: line)
    }

    @MainActor
    private func dismissKeyboard(in app: XCUIApplication) {
        guard app.keyboards.count > 0 else { return }
        let doneButton = app.keyboards.buttons["Done"]
        if doneButton.exists {
            doneButton.tap()
        } else {
            app.keyboards.buttons.element(boundBy: 0).tap()
        }
    }
}
