import XCTest

/// #0471: Discard Changes… on a row and Discard All… on the Changes header
/// each ask first; Cancel changes nothing, Discard throws the unstaged
/// changes away and leaves the staged file alone, and Edit ▸ Undo Discard
/// brings them back, one discard per Undo.
final class Spike0471DiscardFilesUITests: XCTestCase {
    @MainActor
    func testDiscardAsksFirstAndUndoDiscardBringsTheFilesBack() {
        let app = XCUIApplication()
        app.launchWithChangesFixture()

        let gone = app.changesRow(UITestChangesFixture.gone, staged: false)
        let tracked = app.changesRow(UITestChangesFixture.tracked, staged: false)
        let untracked = app.changesRow(UITestChangesFixture.untracked, staged: false)
        let staged = app.changesRow(UITestChangesFixture.staged, staged: true)
        XCTAssertTrue(gone.waitForExistence(timeout: 30), "gone.txt is not listed")
        XCTAssertTrue(tracked.exists && untracked.exists && staged.exists, "the fixture's rows are not all listed")
        // Scoped to the window: the dialog's buttons are mirrored on the
        // Touch Bar, and clicking that copy fails (measured in the VM).
        let discard = app.windows.firstMatch.buttons.matching(NSPredicate(format: "label == 'Discard' OR title == 'Discard'")).firstMatch
        let cancel = app.windows.firstMatch.buttons.matching(NSPredicate(format: "label == 'Cancel' OR title == 'Cancel'")).firstMatch

        // One file, cancelled: nothing changes.
        gone.rightClick()
        let item = app.menuItems["Discard Changes…"]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the row's context menu has no Discard Changes…")
        item.click()
        XCTAssertTrue(discard.waitForExistence(timeout: 10), "Discard Changes… asked nothing")
        let title = app.staticTexts["Discard changes to \(UITestChangesFixture.gone)?"]
        XCTAssertTrue(title.exists, "the dialog does not name gone.txt")
        let dialog = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        dialog.name = "changes-discard-dialog"
        dialog.lifetime = .keepAlways
        add(dialog)
        cancel.click()
        XCTAssertTrue(app.waitUntilDisappears(discard, timeout: 10), "Cancel left the dialog up")
        XCTAssertTrue(gone.exists, "Cancel discarded gone.txt")

        // One file, confirmed.
        gone.rightClick()
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.click()
        XCTAssertTrue(discard.waitForExistence(timeout: 10))
        discard.click()
        XCTAssertTrue(app.waitUntilDisappears(gone, timeout: 30), "Discard left gone.txt in Changes")

        // Everything left, confirmed: the staged file stays staged.
        app.buttons["discard-all"].click()
        XCTAssertTrue(discard.waitForExistence(timeout: 10), "Discard All… asked nothing")
        XCTAssertTrue(app.staticTexts["Discard changes to 2 files?"].exists,
                      "Discard All… does not name the two remaining files")
        discard.click()
        XCTAssertTrue(app.waitUntilDisappears(tracked, timeout: 30), "tracked.txt is still changed")
        XCTAssertTrue(app.waitUntilDisappears(untracked, timeout: 30), "new.txt is still listed")
        XCTAssertTrue(staged.exists, "Discard All… touched the staged file")

        let done = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        done.name = "changes-discard-done"
        done.lifetime = .keepAlways
        add(done)

        // Undo twice: first the two files, then gone.txt. Focus is on a
        // row, not the message editor (#0393).
        staged.click()
        app.menuBars.menuBarItems["Edit"].click()
        let undo = app.menuBars.menuItems["Undo Discard"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the Edit menu offers no Undo Discard")
        undo.click()
        XCTAssertTrue(tracked.waitForExistence(timeout: 30), "Undo Discard did not bring tracked.txt back")
        XCTAssertTrue(untracked.waitForExistence(timeout: 30), "Undo Discard did not bring new.txt back")
        XCTAssertFalse(gone.exists, "one Undo undid both discards")

        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        undo.click()
        XCTAssertTrue(gone.waitForExistence(timeout: 30), "the second Undo Discard did not bring gone.txt back")

        let undone = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        undone.name = "changes-discard-undone"
        undone.lifetime = .keepAlways
        add(undone)
    }
}
