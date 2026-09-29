import XCTest

/// #0472: an unstaged hunk's Discard Hunk… asks first, then throws that
/// hunk away and leaves the other; Edit ▸ Undo Discard brings it back.
final class Spike0472DiscardHunkUITests: XCTestCase {
    @MainActor
    func testDiscardHunkDiscardsOneHunkOfTwoAndUndoBringsItBack() {
        let app = XCUIApplication()
        app.launchWithChangesFixture()

        let row = app.changesRow(UITestChangesFixture.tracked, staged: false)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "tracked.txt is not listed")
        row.click()
        let discardHunk = app.buttons.matching(
            NSPredicate(format: "title == 'Discard Hunk…' OR label == 'Discard Hunk…'"))
        XCTAssertTrue(discardHunk.firstMatch.waitForExistence(timeout: 30), "the diff shows no Discard Hunk…")
        XCTAssertEqual(discardHunk.count, 2, "tracked.txt's diff should show two hunks")

        discardHunk.firstMatch.click()
        let discard = app.windows.firstMatch.buttons.matching(NSPredicate(format: "label == 'Discard' OR title == 'Discard'")).firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 10), "Discard Hunk… asked nothing")
        XCTAssertTrue(app.staticTexts["Discard this change to \(UITestChangesFixture.tracked)?"].exists,
                      "the dialog does not name tracked.txt")
        discard.click()

        let deadline = Date().addingTimeInterval(30)
        while discardHunk.count != 1, Date() < deadline { usleep(200_000) }
        XCTAssertEqual(discardHunk.count, 1, "one hunk should be left")
        XCTAssertTrue(row.exists, "the other hunk should leave tracked.txt changed")
        XCTAssertFalse(app.changesRow(UITestChangesFixture.tracked, staged: true).exists,
                       "Discard Hunk… staged something")

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "changes-discard-hunk"
        shot.lifetime = .keepAlways
        add(shot)

        // Focus is on the row, not the message editor (#0393).
        row.click()
        app.menuBars.menuBarItems["Edit"].click()
        let undo = app.menuBars.menuItems["Undo Discard"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the Edit menu offers no Undo Discard")
        undo.click()
        let back = Date().addingTimeInterval(30)
        while discardHunk.count != 2, Date() < back { usleep(200_000) }
        XCTAssertEqual(discardHunk.count, 2, "Undo Discard did not bring the hunk back")
    }
}
