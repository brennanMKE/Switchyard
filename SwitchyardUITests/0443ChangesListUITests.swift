import XCTest

/// #0443: with no commit selected, the Detail pane lists the staged and
/// unstaged files, and each file's Stage / Unstage button moves it across.
final class Spike0443ChangesListUITests: XCTestCase {
    @MainActor
    func testFilesListByTheirSideAndMoveAcrossWithTheirButtons() {
        let app = XCUIApplication()
        app.launchWithChangesFixture()

        let untracked = app.changesRow(UITestChangesFixture.untracked, staged: false)
        XCTAssertTrue(untracked.waitForExistence(timeout: 30), "new.txt is not listed as unstaged")
        XCTAssertTrue(app.changesRow(UITestChangesFixture.gone, staged: false).exists, "gone.txt is not listed")
        XCTAssertTrue(app.changesRow(UITestChangesFixture.tracked, staged: false).exists, "tracked.txt is not listed")
        XCTAssertTrue(app.changesRow(UITestChangesFixture.staged, staged: true).exists, "staged.txt is not listed as staged")

        app.buttons["stage-file-\(UITestChangesFixture.untracked)"].click()
        XCTAssertTrue(
            app.changesRow(UITestChangesFixture.untracked, staged: true).waitForExistence(timeout: 30),
            "Stage did not move new.txt to Staged Changes")
        XCTAssertTrue(
            app.waitUntilDisappears(untracked, timeout: 30), "new.txt is still listed as unstaged")

        app.buttons["unstage-file-\(UITestChangesFixture.staged)"].click()
        XCTAssertTrue(
            app.changesRow(UITestChangesFixture.staged, staged: false).waitForExistence(timeout: 30),
            "Unstage did not move staged.txt to Changes")

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "changes-list"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
