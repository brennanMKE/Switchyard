import XCTest

/// #0406: double-clicking a History row opens that commit's changes in a
/// second window listing its changed file.
final class Spike0406CommitChangesWindowUITests: XCTestCase {
    @MainActor
    func testDoubleClickingAHistoryRowOpensTheChangesWindow() {
        let app = XCUIApplication()
        app.launchWithFixtureRepository()

        let row = app.historyRows(containing: UITestFixture.thirdSubject).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no History row for the third commit")
        row.doubleClick()

        // The fixture's third commit adds c.txt (run-ui-tests-vm.sh).
        let window = app.windows.matching(NSPredicate(
            format: "title CONTAINS %@", UITestFixture.thirdSubject)).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30),
                      "double-clicking the row opened no changes window")
        XCTAssertTrue(
            window.staticTexts.matching(NSPredicate(format: "label CONTAINS 'c.txt' OR value CONTAINS 'c.txt'"))
                .firstMatch.waitForExistence(timeout: 30),
            "the changes window does not list c.txt")
    }
}
