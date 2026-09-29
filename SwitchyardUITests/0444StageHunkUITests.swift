import XCTest

/// #0444: selecting a file shows its diff with a button per hunk; Stage
/// Hunk stages that hunk alone.
final class Spike0444StageHunkUITests: XCTestCase {
    @MainActor
    func testStageHunkStagesOneHunkOfTwo() {
        let app = XCUIApplication()
        app.launchWithChangesFixture()

        let row = app.changesRow(UITestChangesFixture.tracked, staged: false)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "tracked.txt is not listed")
        row.click()
        let stageHunk = app.buttons.matching(NSPredicate(format: "title == 'Stage Hunk' OR label == 'Stage Hunk'"))
        XCTAssertTrue(stageHunk.firstMatch.waitForExistence(timeout: 30), "the diff shows no Stage Hunk button")
        XCTAssertEqual(stageHunk.count, 2, "tracked.txt's diff should show two hunks")

        stageHunk.firstMatch.click()
        XCTAssertTrue(
            app.changesRow(UITestChangesFixture.tracked, staged: true).waitForExistence(timeout: 30),
            "the staged hunk did not list tracked.txt under Staged Changes")
        XCTAssertTrue(app.changesRow(UITestChangesFixture.tracked, staged: false).exists,
                      "the other hunk should leave tracked.txt listed as unstaged too")
        let deadline = Date().addingTimeInterval(30)
        while stageHunk.count != 1, Date() < deadline { usleep(200_000) }
        XCTAssertEqual(stageHunk.count, 1, "one hunk should be left to stage")

        app.changesRow(UITestChangesFixture.tracked, staged: true).click()
        let unstageHunk = app.buttons.matching(NSPredicate(format: "title == 'Unstage Hunk' OR label == 'Unstage Hunk'"))
        XCTAssertTrue(unstageHunk.firstMatch.waitForExistence(timeout: 30), "the staged side shows no Unstage Hunk")
        XCTAssertEqual(unstageHunk.count, 1)

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "changes-stage-hunk"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
