import XCTest

/// #0445: a message and ⌘↩ commit the staged changes — the commit appears
/// in History — and Edit ▸ Undo Commit takes it back.
final class Spike0445CommitUITests: XCTestCase {
    @MainActor
    func testCommandReturnCommitsAndUndoRevertsIt() {
        let app = XCUIApplication()
        app.launchWithChangesFixture()

        let staged = app.changesRow(UITestChangesFixture.staged, staged: true)
        XCTAssertTrue(staged.waitForExistence(timeout: 30), "staged.txt is not listed as staged")
        let commit = app.buttons["commit-button"]
        XCTAssertTrue(commit.exists, "no Commit button")
        XCTAssertFalse(commit.isEnabled, "Commit is enabled with an empty message")

        let message = app.textViews["commit-message"]
        XCTAssertTrue(message.exists, "no commit message editor")
        message.click()
        message.typeText("0445 committed from the app")
        XCTAssertTrue(commit.isEnabled, "Commit stayed disabled with a message and a staged file")
        message.typeKey(.return, modifierFlags: .command)

        let row = app.historyRows(containing: "0445 committed from the app").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the new commit is not in History")
        XCTAssertTrue(app.waitUntilDisappears(staged, timeout: 30), "staged.txt is still staged")

        // Move focus off the message editor: the Edit menu's Undo forwards
        // to a first-responder text view (#0393).
        app.changesRow(UITestChangesFixture.untracked, staged: false).click()
        app.menuBars.menuBarItems["Edit"].click()
        let undo = app.menuBars.menuItems["Undo Commit"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the Edit menu offers no Undo Commit")
        undo.click()
        XCTAssertTrue(app.waitUntilDisappears(row, timeout: 30), "Undo Commit left the commit in History")
        XCTAssertTrue(
            app.changesRow(UITestChangesFixture.staged, staged: true).waitForExistence(timeout: 30),
            "Undo Commit did not put staged.txt back in Staged Changes")

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "changes-commit-undone"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
