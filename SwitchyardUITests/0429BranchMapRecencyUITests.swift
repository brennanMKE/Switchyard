import XCTest

/// #0429 (umbrella #0425): the branch map's recency filter. At the default
/// two weeks, a 40-day-old branch is hidden and a 40-day-old parent of a
/// recent branch stays as context; "All branches" shows the stale branch,
/// and a sidebar click reveals it under the default filter.
final class Spike0429BranchMapRecencyUITests: XCTestCase {
    @MainActor
    func testTheRecencyFilterHidesStaleBranchesKeepsContextAndReveals() {
        let app = XCUIApplication()
        app.launchWithMapFixture()
        XCTAssertTrue(app.historyRows(containing: UITestMapFixture.mainTip).firstMatch.waitForExistence(timeout: 30),
                      "the map did not load")
        func lane(_ name: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(
                format: "label == %@ OR value == %@", "Lane \(name)", "Lane \(name)")).firstMatch
        }

        XCTAssertTrue(lane(UITestMapFixture.freshChild).waitForExistence(timeout: 10), "no lane for fresh-child")
        XCTAssertTrue(lane(UITestMapFixture.staleBase).exists, "fresh-child's stale parent is not drawn as context")
        XCTAssertFalse(lane(UITestMapFixture.staleOnly).exists, "the two-week filter did not hide stale-only")
        let recent = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        recent.name = "branch-map-recent"
        recent.lifetime = .keepAlways
        add(recent)

        let picker = app.descendants(matching: .any).matching(identifier: "branch-map-recency").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "no recency pop-up")
        picker.click()
        app.menuItems["All branches"].click()
        XCTAssertTrue(lane(UITestMapFixture.staleOnly).waitForExistence(timeout: 10), "All branches did not show stale-only")

        picker.click()
        app.menuItems["Last 2 weeks"].click()
        XCTAssertTrue(app.waitUntilDisappears(lane(UITestMapFixture.staleOnly), timeout: 10),
                      "Last 2 weeks did not hide stale-only again")

        // The sidebar lists every branch; narrowing it makes the row
        // reachable, and a click reveals the hidden lane.
        let filter = app.sidebarFilterField()
        XCTAssertTrue(filter.waitForExistence(timeout: 30), "no filter field")
        filter.click()
        filter.typeText(UITestMapFixture.staleOnly)
        app.sidebarRow(named: UITestMapFixture.staleOnly).tap()
        XCTAssertTrue(lane(UITestMapFixture.staleOnly).waitForExistence(timeout: 10),
                      "clicking stale-only in the sidebar did not reveal its lane")
        let revealed = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        revealed.name = "branch-map-revealed"
        revealed.lifetime = .keepAlways
        add(revealed)
    }
}
