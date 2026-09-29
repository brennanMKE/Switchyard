import XCTest

/// #0480: changed lines in the Changes view's diff are selectable by drag,
/// click, ⌘-click and shift-click; while a hunk has a selection its buttons read
/// Stage Lines and Discard Lines…, and Stage Lines stages only the
/// selected line.
final class Spike0480StageLinesUITests: XCTestCase {
    @MainActor
    func testSelectingLinesRetitlesTheHunkAndStageLinesStagesOnlyThem() {
        let app = XCUIApplication()
        app.launchWithChangesFixture()

        let row = app.changesRow(UITestChangesFixture.tracked, staged: false)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "tracked.txt is not listed")
        row.click()
        // Only the first hunk is on screen in the fixture window; the second
        // (line 18) is below the diff pane's fold, where a click lands
        // elsewhere (measured). Every interaction uses line 2's pair.
        let removed2 = app.staticTexts["-line 02"]
        let added2 = app.staticTexts["+line 02 edited"]
        XCTAssertTrue(added2.waitForExistence(timeout: 30), "the diff does not show line 2's edit")
        let stageHunk = app.buttons.matching(NSPredicate(format: "title == 'Stage Hunk' OR label == 'Stage Hunk'"))
        let stageLines = app.buttons.matching(NSPredicate(format: "title == 'Stage Lines' OR label == 'Stage Lines'"))
        let discardLines = app.buttons.matching(NSPredicate(format: "title == 'Discard Lines…' OR label == 'Discard Lines…'"))
        XCTAssertEqual(stageHunk.count, 2, "tracked.txt's diff should show two hunks")
        XCTAssertEqual(stageLines.count, 0)

        // A drag across the pair selects both lines and retitles only that hunk.
        removed2.click(forDuration: 0.3, thenDragTo: added2, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(stageLines.firstMatch.waitForExistence(timeout: 10), "a drag selected nothing")
        XCTAssertTrue(removed2.isSelected && added2.isSelected, "the drag did not select both lines")
        XCTAssertEqual(stageHunk.count, 1, "only the dragged hunk should be retitled")
        XCTAssertEqual(discardLines.count, 1, "the unstaged side offers Discard Lines…")

        // A click selects one line alone; ⌘-click adds and removes a line.
        removed2.click()
        XCTAssertTrue(removed2.isSelected)
        XCTAssertFalse(added2.isSelected, "a plain click did not select the line alone")
        XCUIElement.perform(withKeyModifiers: .command) { added2.click() }
        XCTAssertTrue(removed2.isSelected && added2.isSelected, "⌘-click did not add the line")
        XCUIElement.perform(withKeyModifiers: .command) { removed2.click() }
        XCTAssertFalse(removed2.isSelected, "⌘-click did not remove the line")
        XCTAssertTrue(added2.isSelected)
        // Clicking the only selected line clears; shift-click extends from
        // the last click.
        added2.click()
        XCTAssertFalse(added2.isSelected, "clicking the only selected line did not clear it")
        XCTAssertEqual(stageLines.count, 0)
        removed2.click()
        XCUIElement.perform(withKeyModifiers: .shift) { added2.click() }
        XCTAssertTrue(removed2.isSelected && added2.isSelected, "shift-click did not extend from the anchor")

        // A plain click on the added line leaves it selected alone.
        added2.click()
        XCTAssertFalse(removed2.isSelected)
        XCTAssertTrue(added2.isSelected)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "changes-stage-lines"
        shot.lifetime = .keepAlways
        add(shot)

        stageLines.firstMatch.click()
        let stagedRow = app.changesRow(UITestChangesFixture.tracked, staged: true)
        XCTAssertTrue(stagedRow.waitForExistence(timeout: 30), "Stage Lines staged nothing")
        // Staging only the added line leaves line 2's removal unstaged, so
        // the unstaged side still has two hunks and the selection is gone.
        let deadline = Date().addingTimeInterval(30)
        while stageLines.count != 0, Date() < deadline { usleep(200_000) }
        XCTAssertEqual(stageLines.count, 0, "the selection should clear after staging")
        XCTAssertEqual(stageHunk.count, 2, "line 2's removal should still be unstaged")

        // The staged side holds the added line, and no removal.
        stagedRow.click()
        XCTAssertTrue(app.staticTexts["+line 02 edited"].waitForExistence(timeout: 30),
                      "the staged diff does not show the added line")
        XCTAssertFalse(app.staticTexts["-line 02"].exists, "Stage Lines staged the unselected removal")
        let staged = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        staged.name = "changes-stage-lines-staged"
        staged.lifetime = .keepAlways
        add(staged)
    }
}
