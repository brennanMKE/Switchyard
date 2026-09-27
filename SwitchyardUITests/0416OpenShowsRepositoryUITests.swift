import AppKit
import XCTest

/// #0416: a repository opened from outside any view -- a `switchyard://`
/// URL, delivered to the app delegate's `application(_:open:)`, the same
/// funnel as a Dock drop or `open -a Switchyard <folder>` -- is SHOWN: in
/// the current window while it is empty, in a new window otherwise, and by
/// focusing its own window when it is already open. A folder that is not a
/// repository is refused with an alert, and opens no window.
///
/// Delivery is `NSWorkspace.shared.open(_:)` from the test runner -- the
/// LaunchServices route a Dock drop or `open` takes -- NOT
/// `XCUIApplication.open(_:)`. Measured 2026-09-26 in the guest: `app.open`
/// RELAUNCHES the app (a new pid), which is the session's third launch, and
/// the launch-count quirk in UITestSupport.swift leaves that instance with
/// no window at all. `NSWorkspace.open` reached the running app (same pid).
final class Spike0416OpenShowsRepositoryUITests: XCTestCase {
    /// `switchyard://open?path=<percent-encoded path>`.
    private func openURL(_ path: String) -> URL {
        var components = URLComponents()
        components.scheme = "switchyard"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url!
    }

    /// Hands `path` to the running app the way the OS does.
    private func deliver(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(NSWorkspace.shared.open(openURL(path)),
                      "LaunchServices refused switchyard:// for \(path)", file: file, line: line)
    }

    @MainActor
    func testEveryOpenShowsTheRepositoryInAWindow() {
        let app = XCUIApplication()
        // An ordinary launch: no -uiTestRepository, so the production
        // ContentView renders and nothing is open.
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60),
                      "the app launched but opened no window")
        let empty = app.staticTexts.matching(NSPredicate(
            format: "value == %@ OR label == %@", "No repository open", "No repository open")).firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 30), "a plain launch should show the empty window")
        XCTAssertEqual(app.windows.count, 1)

        // 1. The current window is empty: the repository opens IN it.
        deliver(UITestFixture.repositoryPath)
        XCTAssertTrue(app.historyRows(containing: UITestFixture.tipSubject).firstMatch
            .waitForExistence(timeout: 30), "the opened repository never appeared")
        XCTAssertEqual(app.windows.count, 1, "an empty current window is reused")
        let first = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        first.name = "opened-in-empty-window"
        first.lifetime = .keepAlways
        add(first)

        // 2. The current window shows a repository: a second one gets a new window.
        deliver(UITestMapFixture.repositoryPath)
        XCTAssertTrue(app.historyRows(containing: UITestMapFixture.mainTip).firstMatch
            .waitForExistence(timeout: 30), "the second repository never appeared")
        XCTAssertEqual(app.windows.count, 2, "a second repository opens its own window")

        // 3. Reopening the first repository focuses its window; no third window.
        deliver(UITestFixture.repositoryPath)
        XCTAssertTrue(app.historyRows(containing: UITestFixture.tipSubject).firstMatch
            .waitForExistence(timeout: 30))
        XCTAssertEqual(app.windows.count, 2, "reopening an open repository adds no window")

        // 4. A folder that is not a repository: an alert, and no new window.
        deliver("/Users/admin")
        let alertTitle = app.staticTexts.matching(NSPredicate(
            format: "value == %@ OR label == %@",
            "Couldn't open repository", "Couldn't open repository")).firstMatch
        XCTAssertTrue(alertTitle.waitForExistence(timeout: 30), "a non-repository must be reported, not ignored")
        let refusal = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        refusal.name = "non-repository-refused"
        refusal.lifetime = .keepAlways
        add(refusal)
        app.buttons["OK"].firstMatch.click()
        XCTAssertTrue(app.waitUntilDisappears(alertTitle, timeout: 10))
        XCTAssertEqual(app.windows.count, 2, "a refused folder opens no window")

        // 5. Every window closed: an open still brings one back.
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("w", modifierFlags: .command)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, app.windows.count > 0 { usleep(200_000) }
        XCTAssertEqual(app.windows.count, 0, "Cmd-W twice should close both windows")
        deliver(UITestMapFixture.repositoryPath)
        XCTAssertTrue(app.historyRows(containing: UITestMapFixture.mainTip).firstMatch
            .waitForExistence(timeout: 30), "with no window open, an open must bring one back")
        XCTAssertEqual(app.windows.count, 1)
    }
}
