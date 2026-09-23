import XCTest

/// #0402: typing in the filter acts on the graph -- the match bar counts
/// matches and ⌘G selects the match.
final class Spike0402FilterHighlightsGraphUITests: XCTestCase {
    @MainActor
    func testFilterCountsMatchesAndNextSelectsTheMatch() {
        let app = XCUIApplication()
        app.launchWithFixtureRepository()
        let filter = app.sidebarFilterField()
        XCTAssertTrue(filter.waitForExistence(timeout: 30), "no filter field")
        filter.click()
        filter.typeText("third commit")

        let count = app.staticTexts.matching(NSPredicate(
            format: "label == '1 match' OR value == '1 match'")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10), "the match bar does not say 1 match")

        app.typeKey("g", modifierFlags: .command)
        let headline = app.staticTexts.matching(NSPredicate(
            format: "value == %@ OR label == %@",
            UITestFixture.thirdSubject, UITestFixture.thirdSubject)).firstMatch
        XCTAssertTrue(headline.waitForExistence(timeout: 10),
                      "⌘G did not select the matching commit")
    }
}
