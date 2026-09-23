import XCTest

/// #0401: clicking a sidebar branch selects its tip commit — the Detail
/// pane shows that commit's subject as its headline.
final class Spike0401SidebarBranchFocusUITests: XCTestCase {
    @MainActor
    func testClickingASidebarBranchShowsItsTipCommit() {
        let app = XCUIApplication()
        app.launchWithFixtureRepository()

        let row = app.sidebarRow(named: UITestFixture.olderBranch)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no sidebar row for beta-older")
        row.tap()

        let headline = app.staticTexts.matching(NSPredicate(
            format: "value == %@ OR label == %@",
            UITestFixture.secondSubject, UITestFixture.secondSubject)).firstMatch
        XCTAssertTrue(
            headline.waitForExistence(timeout: 30),
            "clicking beta-older did not show its tip commit (0382 second commit) in the Detail pane")
    }
}
