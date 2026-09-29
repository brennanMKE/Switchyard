import XCTest

/// #0446: the History pane's Uncommitted Changes row brings the Changes
/// view back after a commit was selected.
final class Spike0446WorkingChangesRowUITests: XCTestCase {
    @MainActor
    func testTheRowReturnsTheDetailPaneToTheChangesView() {
        let app = XCUIApplication()
        app.launchWithChangesFixture()

        let untracked = app.changesRow(UITestChangesFixture.untracked, staged: false)
        XCTAssertTrue(untracked.waitForExistence(timeout: 30), "the Changes view is not shown at launch")

        app.selectHistoryRow(subject: UITestChangesFixture.baseSubject)
        XCTAssertTrue(app.waitUntilDisappears(untracked, timeout: 30),
                      "selecting a commit left the Changes view up")

        let row = app.buttons["working-changes-row"]
        XCTAssertTrue(row.exists, "no Uncommitted Changes row")
        row.click()
        XCTAssertTrue(untracked.waitForExistence(timeout: 30), "the row did not bring the Changes view back")

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "changes-row"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
