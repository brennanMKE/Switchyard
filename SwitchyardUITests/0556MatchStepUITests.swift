import XCTest

/// #0556: ⌘G steps through the current query's matches. It used to step
/// through the matches of the render that first showed the match bar — here
/// "q", which matches nothing — so after "q" was replaced by "root" it
/// selected nothing.
final class Spike0556MatchStepUITests: XCTestCase {
    @MainActor
    func testCommandGStepsThroughTheCurrentMatches() {
        let app = XCUIApplication()
        app.launchWithFixtureRepository()
        let filter = app.sidebarFilterField()
        XCTAssertTrue(filter.waitForExistence(timeout: 30), "no filter field")
        filter.click()
        filter.typeText("q")
        XCTAssertTrue(app.matchCount("0 matches").waitForExistence(timeout: 10),
                      "the match bar does not say 0 matches for \"q\"")
        filter.typeKey("a", modifierFlags: .command)
        filter.typeText("root")
        XCTAssertTrue(app.matchCount("1 match").waitForExistence(timeout: 10),
                      "the match bar does not say 1 match for \"root\"")
        app.typeKey("g", modifierFlags: .command)
        let headline = app.staticTexts.matching(NSPredicate(
            format: "value == %@ OR label == %@",
            UITestFixture.rootSubject, UITestFixture.rootSubject)).firstMatch
        XCTAssertTrue(headline.waitForExistence(timeout: 10),
                      "⌘G did not select the one commit matching \"root\"")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "history-command-g"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
