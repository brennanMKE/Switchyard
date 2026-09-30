// 0571SidebarStatusUITests.swift
//
// #0571: the sidebar's branch status follows a commit — the switch
// fixture's switch-main reads "in sync" until a commit makes it ↑1.

import XCTest

final class Spike0571SidebarStatusUITests: XCTestCase {
    @MainActor
    func testTheBranchRowCountsACommit() {
        let app = XCUIApplication()
        app.launchWithSwitchFixture()
        XCTAssertTrue(app.text(containing: "in sync vs origin/switch-main").waitForExistence(timeout: 30),
                      "switch-main does not start in sync with origin")
        let stage = app.buttons["stage-file-notes.txt"]
        XCTAssertTrue(stage.waitForExistence(timeout: 30), "notes.txt has no Stage button")
        stage.click()
        XCTAssertTrue(app.changesRow("notes.txt", staged: true).waitForExistence(timeout: 30),
                      "notes.txt was not staged")
        let editor = app.textViews["commit-message"]
        editor.click()
        editor.typeText("0571 commit")
        app.buttons["commit-button"].click()
        XCTAssertTrue(app.header(beginningWith: "On branch switch-main · 1 ahead").waitForExistence(timeout: 30),
                      "the commit did not land")
        XCTAssertTrue(app.text(containing: "↑1 vs origin/switch-main").waitForExistence(timeout: 30),
                      "the sidebar row still does not count the commit")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "0571-sidebar-ahead"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
