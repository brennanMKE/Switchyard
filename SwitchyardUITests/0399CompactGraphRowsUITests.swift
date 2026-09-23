import XCTest

/// #0399: graph rows carry no commit text, so they are compact -- one
/// node and its chips, not a two-line subject/SHA/author row.
final class Spike0399CompactGraphRowsUITests: XCTestCase {
    @MainActor
    func testGraphRowsAreCompact() {
        let app = XCUIApplication()
        app.launchWithFixtureRepository()

        let row = app.historyRows(containing: UITestFixture.thirdSubject).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no History row for the third commit")
        XCTAssertLessThanOrEqual(
            row.frame.height, 26,
            "a History row is \(row.frame.height) pt tall -- it still lays out commit text")
    }
}
