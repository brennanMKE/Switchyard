import XCTest

/// #0415 (umbrella #0410): on the multi-branch fixture, every branch tip
/// shares the top row, lanes carry their labels, and a sidebar click
/// scrolls a far branch's tip into view -- sideways and downward.
final class Spike0415BranchMapUITests: XCTestCase {
    @MainActor
    func testBranchMapAlignsTipsAndScrollsToFarBranches() {
        let app = XCUIApplication()
        app.launchWithMapFixture()

        let main = app.historyRows(containing: UITestMapFixture.mainTip).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 30), "the map did not load")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "branch-map"
        shot.lifetime = .keepAlways
        add(shot)

        for subject in [UITestMapFixture.newestLaneTip, UITestMapFixture.nearTip, UITestMapFixture.midTip] {
            let node = app.historyRows(containing: subject).firstMatch
            XCTAssertTrue(node.waitForExistence(timeout: 10), "no node for \(subject)")
            XCTAssertEqual(node.frame.midY, main.frame.midY, accuracy: 1,
                           "\(subject) is not on the top row with map-main's tip")
        }
        let label = app.staticTexts.matching(NSPredicate(
            format: "label == %@ OR value == %@", "Lane feature-near", "Lane feature-near")).firstMatch
        XCTAssertTrue(label.exists, "no lane label for feature-near")

        let deep = app.historyRows(containing: UITestMapFixture.deepTip).firstMatch
        XCTAssertTrue(deep.waitForExistence(timeout: 10), "no node for the deep tip")
        XCTAssertFalse(deep.isHittable, "the deep tip is already on screen -- the fixture is too narrow")
        app.sidebarRow(named: UITestMapFixture.deepBranch).tap()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !deep.isHittable { usleep(200_000) }
        XCTAssertTrue(deep.isHittable, "clicking feature-deep did not scroll its tip into view")

        app.sidebarRow(named: UITestMapFixture.oldBranch).tap()
        let old = app.historyRows(containing: UITestMapFixture.oldTip).firstMatch
        XCTAssertTrue(old.waitForExistence(timeout: 10), "merged-old's tip never appeared")
        let deadline2 = Date().addingTimeInterval(10)
        while Date() < deadline2, !old.isHittable { usleep(200_000) }
        XCTAssertTrue(old.isHittable, "clicking merged-old did not scroll its tip into view")
        let after = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        after.name = "branch-map-scrolled"
        after.lifetime = .keepAlways
        add(after)
    }
}
