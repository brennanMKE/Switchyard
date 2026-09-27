import XCTest

/// #0430 (umbrella #0425): merged branches' lanes are dimmed, and their
/// labels say "(merged)" -- a squash landing (merge-tree content) and an
/// ancestor (merged-old) -- while an open branch and the root lane are not.
final class Spike0430BranchMapMergedUITests: XCTestCase {
    @MainActor
    func testMergedLanesAreDimmedAndSaySo() {
        let app = XCUIApplication()
        app.launchWithMapFixture()
        XCTAssertTrue(app.historyRows(containing: UITestMapFixture.mainTip).firstMatch.waitForExistence(timeout: 30),
                      "the map did not load")
        func label(_ text: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
        }

        // The content pass runs after the map appears; give it time.
        XCTAssertTrue(label("Lane \(UITestMapFixture.squashLanded) (merged)").waitForExistence(timeout: 60),
                      "the squash-landed lane is not marked merged")
        XCTAssertTrue(label("Lane \(UITestMapFixture.oldBranch) (merged)").exists,
                      "merged-old, an ancestor of map-main, is not marked merged")
        XCTAssertTrue(label("Lane feature-near").exists, "feature-near is not merged but its label changed")
        // The root lane's label is the bold HEAD lane's, whose text XCUI
        // does not expose as an exact label (measured in the VM,
        // 2026-09-26); assert the dimmed form is absent instead.
        XCTAssertFalse(label(UITestMapFixture.rootLaneLabel + " (merged)").exists, "the root lane was dimmed")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "branch-map-merged"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
