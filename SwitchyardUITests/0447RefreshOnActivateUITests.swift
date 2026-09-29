import XCTest

/// #0447: a file created while another app is active is listed when the
/// window becomes active again.
final class Spike0447RefreshOnActivateUITests: XCTestCase {
    @MainActor
    func testAFileWrittenElsewhereShowsOnReactivation() throws {
        let app = XCUIApplication()
        app.launchWithChangesFixture()
        XCTAssertTrue(
            app.changesRow(UITestChangesFixture.untracked, staged: false).waitForExistence(timeout: 30),
            "the Changes view is not shown at launch")

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        let file = URL(fileURLWithPath: UITestChangesFixture.repositoryPath)
            .appendingPathComponent("elsewhere.txt")
        try "written by another app\n".write(to: file, atomically: true, encoding: .utf8)
        app.activate()

        XCTAssertTrue(
            app.changesRow("elsewhere.txt", staged: false).waitForExistence(timeout: 30),
            "the file written while the app was inactive is not listed after activation")
    }
}
