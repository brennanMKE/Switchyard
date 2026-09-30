// 0570UndoAfterCommitUITests.swift
//
// #0570: ⌘Z straight after ⌘↩, with the focus still in the message editor,
// takes the commit back. No click elsewhere first — that is the workaround
// #0466's and #0448's spikes use, and what a person never does.

import XCTest

final class Spike0570UndoAfterCommitUITests: XCTestCase {
    @MainActor
    func testCommandZAfterCommandReturnUndoesTheCommit() {
        let app = XCUIApplication()
        app.launchWithChangesFixture()
        XCTAssertTrue(app.changesRow(UITestChangesFixture.staged, staged: true).waitForExistence(timeout: 30),
                      "staged.txt is not listed as staged")
        let editor = app.textViews["commit-message"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30), "no message editor")
        editor.click()
        editor.typeText("0570 commit to take back")
        editor.typeKey(.return, modifierFlags: .command)
        let row = app.historyRows(containing: "0570 commit to take back").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "⌘↩ did not commit")

        editor.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.waitUntilDisappears(row, timeout: 30),
                      "⌘Z after ⌘↩ left the commit in History: the editor swallowed Undo Commit")
        XCTAssertTrue(app.changesRow(UITestChangesFixture.staged, staged: true).waitForExistence(timeout: 30),
                      "Undo Commit did not put staged.txt back in Staged Changes")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "0570-undone"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
