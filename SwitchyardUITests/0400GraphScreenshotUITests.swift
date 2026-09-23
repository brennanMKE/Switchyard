import XCTest

/// #0400: attaches a screenshot of the main window with the fixture loaded,
/// kept even when the test passes, so a graph change can be looked at
/// without opening the app on the host.
final class Spike0400GraphScreenshotUITests: XCTestCase {
    @MainActor
    func testAttachAGraphScreenshot() {
        let app = XCUIApplication()
        app.launchWithFixtureRepository()
        let row = app.historyRows(containing: UITestFixture.tipSubject).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the graph did not load")

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "graph"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
