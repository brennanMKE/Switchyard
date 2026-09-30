// 0572StagedSelectionUITests.swift
//
// #0572: staging the selected file keeps it selected — on the staged side,
// with its diff still on screen — instead of blanking the diff pane.

import XCTest

final class Spike0572StagedSelectionUITests: XCTestCase {
    @MainActor
    func testStagingTheSelectedFileKeepsItsDiff() {
        let app = XCUIApplication()
        app.launchWithSwitchFixture()
        let unstaged = app.changesRow("notes.txt", staged: false)
        XCTAssertTrue(unstaged.waitForExistence(timeout: 30), "notes.txt is not listed as unstaged")
        unstaged.click()
        let added = app.staticTexts["+local edit"]
        XCTAssertTrue(added.waitForExistence(timeout: 30), "the diff does not show notes.txt's edit")

        app.buttons["stage-file-notes.txt"].click()
        XCTAssertTrue(app.changesRow("notes.txt", staged: true).waitForExistence(timeout: 30),
                      "notes.txt was not staged")
        XCTAssertTrue(added.waitForExistence(timeout: 30),
                      "staging the selected file blanked its diff")
        XCTAssertFalse(app.text(containing: "Select a file to see its changes").exists,
                       "the diff pane fell back to its placeholder")
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "title == 'Unstage Hunk' OR label == 'Unstage Hunk'")).firstMatch.exists,
                      "the diff shown is not the staged side's")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "0572-staged-diff-kept"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
