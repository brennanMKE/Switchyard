import XCTest

/// #0496: the sidebar lists both stashes; clicking one shows its files in
/// the Detail pane; Drop… asks first and Edit ▸ Undo Drop Stash brings the
/// stash back; Pop from the row's context menu applies it, removes it and
/// shows the Changes view, and Edit ▸ Undo Pop Stash puts both back.
final class Spike0496StashListUITests: XCTestCase {
    @MainActor
    func testTheStashListShowsDropsAndPops() {
        let app = XCUIApplication()
        app.launchWithStashFixture()

        let newer = app.sidebarRow(named: UITestStashFixture.newer)
        let older = app.sidebarRow(named: UITestStashFixture.older)
        XCTAssertTrue(newer.waitForExistence(timeout: 30), "the sidebar does not list the newer stash")
        XCTAssertTrue(older.exists, "the sidebar does not list the older stash")

        // Selecting a stash shows what it holds, untracked file included.
        newer.click()
        let drop = app.buttons["stash-drop"]
        XCTAssertTrue(drop.waitForExistence(timeout: 10), "selecting the stash showed no stash detail")
        XCTAssertTrue(app.staticTexts[UITestStashFixture.todo].waitForExistence(timeout: 30),
                      "the stash's untracked file is not shown")
        let detail = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        detail.name = "stash-detail"
        detail.lifetime = .keepAlways
        add(detail)

        // Drop… asks first; Drop removes it. Scoped to the window: the
        // dialog's buttons are mirrored on the Touch Bar (#0471).
        drop.click()
        let confirm = app.windows.firstMatch.buttons.matching(
            NSPredicate(format: "label == 'Drop' OR title == 'Drop'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Drop… asked nothing")
        XCTAssertTrue(app.staticTexts["Drop stash “\(UITestStashFixture.newer)”?"].exists,
                      "the dialog does not name the stash")
        confirm.click()
        XCTAssertTrue(app.waitUntilDisappears(newer, timeout: 30), "Drop left the stash in the list")

        app.menuBars.menuBarItems["Edit"].click()
        let undoDrop = app.menuBars.menuItems["Undo Drop Stash"]
        XCTAssertTrue(undoDrop.waitForExistence(timeout: 10), "the Edit menu offers no Undo Drop Stash")
        undoDrop.click()
        XCTAssertTrue(newer.waitForExistence(timeout: 30), "Undo Drop Stash did not bring the stash back")

        // Pop from the context menu: the stash goes, its change arrives.
        older.rightClick()
        let pop = app.menuItems["Pop"]
        XCTAssertTrue(pop.waitForExistence(timeout: 10), "the stash row's context menu has no Pop")
        pop.click()
        XCTAssertTrue(app.waitUntilDisappears(older, timeout: 30), "Pop left the stash in the list")
        let notes = app.changesRow(UITestStashFixture.notes, staged: false)
        XCTAssertTrue(notes.waitForExistence(timeout: 30), "the popped change is not in the Changes view")
        let popped = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        popped.name = "stash-popped"
        popped.lifetime = .keepAlways
        add(popped)

        notes.click()
        app.menuBars.menuBarItems["Edit"].click()
        let undoPop = app.menuBars.menuItems["Undo Pop Stash"]
        XCTAssertTrue(undoPop.waitForExistence(timeout: 10), "the Edit menu offers no Undo Pop Stash")
        undoPop.click()
        XCTAssertTrue(older.waitForExistence(timeout: 30), "Undo Pop Stash did not bring the stash back")
        XCTAssertTrue(app.waitUntilDisappears(notes, timeout: 30), "Undo Pop Stash left the change behind")
    }
}
