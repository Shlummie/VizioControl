import XCTest
@testable import VizioControl

final class AppCatalogTests: XCTestCase {
    func testExactOfflineCatalogValuesAndDeclarationOrder() {
        XCTAssertEqual(AppCatalog().configurations, [
            AppLaunchConfiguration(appID: "3", namespace: 2, message: "", name: "Hulu"),
            AppLaunchConfiguration(appID: "1", namespace: 5, message: "", name: "YouTube"),
            AppLaunchConfiguration(appID: "1", namespace: 3, message: "", name: "Netflix"),
        ])
    }

    func testExactNameWinsThenFirstDeclarationOrderPartial() throws {
        let catalog = AppCatalog()
        XCTAssertEqual(try catalog.resolve("  yOuTuBe  ").name, "YouTube")
        XCTAssertEqual(try catalog.resolve("u").name, "Hulu")
        XCTAssertEqual(try catalog.resolve("tube").name, "YouTube")
        XCTAssertEqual(try catalog.resolve("flix").name, "Netflix")
    }

    func testUnknownAndEmptyAppsHaveExactErrors() {
        let catalog = AppCatalog()
        do {
            _ = try catalog.resolve("")
            XCTFail("Expected empty app rejection")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Enter an app name.")
        }
        do {
            _ = try catalog.resolve("Disney+")
            XCTFail("Expected unknown app rejection")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The local quick launcher does not contain “Disney+”. Use SmartCast Home to open it manually."
            )
        }
        XCTAssertThrowsError(try catalog.resolve("1"))
    }
}
