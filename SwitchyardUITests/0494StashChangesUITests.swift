import XCTest

/// #0494: Stash Changes… in the Changes view opens a sheet; Stash with a
/// message and Include untracked files (on by default) empties the Changes
/// list and the header's stash count reads 1; Edit ▸ Undo Stash Changes
/// brings every row back and the count back to 0.
final class Spike0494StashChangesUITests: XCTestCase {
    @MainActor
    func testStashChangesEmptiesTheListAndUndoBringsItBack() {
        let app = XCUIApplication()
        app.launchWithChangesFixture()

        let tracked = app.changesRow(UITestChangesFixture.tracked, staged: false)
        let untracked = app.changesRow(UITestChangesFixture.untracked, staged: false)
        let staged = app.changesRow(UITestChangesFixture.staged, staged: true)
        XCTAssertTrue(tracked.waitForExistence(timeout: 30), "tracked.txt is not listed")
        XCTAssertTrue(app.staticTexts["Stash: 0"].exists, "the header does not read Stash: 0")

        let button = app.buttons["stash-changes"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the Changes view has no Stash Changes…")
        button.click()
        let message = app.textFields["stash-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10), "Stash Changes… opened no sheet")
        XCTAssertEqual(app.checkBoxes["stash-include-untracked"].value as? Int, 1,
                       "Include untracked files is not on by default")
        message.click()
        message.typeText("uitest stash")
        let sheet = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        sheet.name = "stash-changes-sheet"
        sheet.lifetime = .keepAlways
        add(sheet)
        app.buttons["stash-confirm"].click()

        XCTAssertTrue(app.staticTexts["Working tree clean"].waitForExistence(timeout: 30),
                      "Stash left changes in the list")
        XCTAssertFalse(untracked.exists, "the untracked file was not stashed")
        XCTAssertTrue(app.staticTexts["Stash: 1"].waitForExistence(timeout: 10),
                      "the header's stash count did not become 1")
        let done = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        done.name = "stash-changes-done"
        done.lifetime = .keepAlways
        add(done)

        app.menuBars.menuBarItems["Edit"].click()
        let undo = app.menuBars.menuItems["Undo Stash Changes"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the Edit menu offers no Undo Stash Changes")
        undo.click()
        XCTAssertTrue(tracked.waitForExistence(timeout: 30), "Undo did not bring tracked.txt back")
        XCTAssertTrue(untracked.waitForExistence(timeout: 30), "Undo did not bring new.txt back")
        XCTAssertTrue(staged.waitForExistence(timeout: 30), "Undo did not bring staged.txt back staged")
        XCTAssertTrue(app.staticTexts["Stash: 0"].waitForExistence(timeout: 10),
                      "Undo Stash Changes left the stash in the list")
    }
}
