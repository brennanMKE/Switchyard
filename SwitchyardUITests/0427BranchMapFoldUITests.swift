import XCTest

/// #0427 (umbrella #0425): on the map fixture, quiet runs of the root lane
/// fold into "⋯ N" rows. Clicking a fold shows its commits, and a filter
/// match inside a fold opens that fold.
final class Spike0427BranchMapFoldUITests: XCTestCase {
    @MainActor
    func testFoldsOpenOnClickAndForAFilterMatch() {
        let app = XCUIApplication()
        app.launchWithMapFixture()
        let main = app.historyRows(containing: UITestMapFixture.mainTip).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 30), "the map did not load")

        // "map main 06".."04" and the tail "map base 03".."01" fold into
        // threes; "map main 02".."map base 05" into 22.
        let threes = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "Folded 3 commits"))
        XCTAssertEqual(threes.count, 2, "expected two folds of three commits")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "Folded 22 commits")).firstMatch.exists, "no fold of 22 commits")
        let quiet = app.historyRows(containing: UITestMapFixture.foldedMain).firstMatch
        XCTAssertFalse(quiet.exists, "\(UITestMapFixture.foldedMain) is drawn although its run is folded")
        let folded = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        folded.name = "branch-map-folded"
        folded.lifetime = .keepAlways
        add(folded)

        let upper = threes.allElementsBoundByIndex.min { $0.frame.minY < $1.frame.minY }
        XCTAssertNotNil(upper, "no fold to click")
        upper?.click()
        XCTAssertTrue(quiet.waitForExistence(timeout: 10), "clicking the fold did not show its commits")

        let deepQuiet = app.historyRows(containing: UITestMapFixture.foldedBase).firstMatch
        XCTAssertFalse(deepQuiet.exists, "\(UITestMapFixture.foldedBase) is drawn although its run is folded")
        let filter = app.sidebarFilterField()
        XCTAssertTrue(filter.waitForExistence(timeout: 30), "no filter field")
        filter.click()
        filter.typeText(UITestMapFixture.foldedBase)
        XCTAssertTrue(deepQuiet.waitForExistence(timeout: 10), "a filter match inside a fold did not open it")
        let opened = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        opened.name = "branch-map-unfolded"
        opened.lifetime = .keepAlways
        add(opened)
    }
}
