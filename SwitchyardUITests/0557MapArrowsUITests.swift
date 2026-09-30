import XCTest

/// #0557: ↓ and ↑ step the History selection through its lane. A plain arrow
/// key carries `.function`, which the map's key handler read as a modifier,
/// so it ignored every arrow.
final class Spike0557MapArrowsUITests: XCTestCase {
    @MainActor
    func testArrowsStepThroughTheLane() {
        let app = XCUIApplication()
        app.launchWithFixtureRepository()
        app.selectHistoryRow(subject: UITestFixture.thirdSubject)
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(detailHeadline(app, UITestFixture.secondSubject).waitForExistence(timeout: 10),
                      "↓ did not select the commit below \"0382 third commit\"")
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(detailHeadline(app, UITestFixture.thirdSubject).waitForExistence(timeout: 10),
                      "↑ did not select the commit above \"0382 second commit\"")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "history-arrows"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The Detail pane's headline: the selected commit's subject on its own.
    @MainActor
    private func detailHeadline(_ app: XCUIApplication, _ subject: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", subject, subject)).firstMatch
    }
}
