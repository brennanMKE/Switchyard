import XCTest

/// #0403: the Detail pane lists a commit's changed paths without its diff,
/// and Show Changes opens the changes window.
final class Spike0403DetailWithoutDiffUITests: XCTestCase {
    @MainActor
    func testDetailListsPathsWithoutDiffAndShowChangesOpensTheWindow() {
        let app = XCUIApplication()
        app.launchWithFixtureRepository()
        app.selectHistoryRow(subject: UITestFixture.thirdSubject)

        // The fixture's third commit adds c.txt containing "third".
        let main = app.windows.firstMatch
        XCTAssertTrue(
            main.staticTexts.matching(NSPredicate(format: "label CONTAINS 'c.txt' OR value CONTAINS 'c.txt'"))
                .firstMatch.waitForExistence(timeout: 30),
            "the Detail pane does not list c.txt")
        XCTAssertFalse(
            main.staticTexts.matching(NSPredicate(format: "label == '+third' OR value == '+third'"))
                .firstMatch.exists,
            "the Detail pane still renders the diff line +third")

        let button = main.buttons["Show Changes"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no Show Changes button")
        button.click()
        let window = app.windows.matching(NSPredicate(
            format: "title CONTAINS %@", UITestFixture.thirdSubject)).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "Show Changes opened no window")
    }
}
