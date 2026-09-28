import XCTest

/// #0448: Edit ▸ Undo reaches the journal. Revert the tip with ⌥⌘R, then
/// choose Edit ▸ Undo Revert: the revert commit must leave History.
final class Spike0448UndoReachesJournalUITests: XCTestCase {
    @MainActor
    func testEditUndoRevertTakesTheRevertBack() {
        let app = XCUIApplication()
        app.launchWithFixtureRepository()
        app.selectHistoryRow(subject: UITestFixture.tipSubject)

        app.typeKey("r", modifierFlags: [.command, .option])
        let revert = app.historyRows(containing: UITestFixture.revertSubject).firstMatch
        XCTAssertTrue(revert.waitForExistence(timeout: 30), "⌥⌘R wrote no revert commit")

        app.menuBars.menuBarItems["Edit"].click()
        let undo = app.menuBars.menuItems["Undo Revert"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the Edit menu offers no Undo Revert")
        undo.click()

        XCTAssertTrue(
            app.waitUntilDisappears(revert, timeout: 30),
            "Edit ▸ Undo Revert left the revert commit in History — the menu " +
            "forwarded undo: to the responder chain instead of the journal")
    }
}
