import AppKit
import XCTest

/// #0417: repositories open as native macOS tabs of one window. Opening a
/// second repository adds a tab rather than a window, reopening one selects
/// its tab, and File ▸ New Tab (⌘T) adds an empty tab.
///
/// Opens are delivered with `NSWorkspace.shared.open(_:)`, for the reason
/// given in Spike0416OpenShowsRepositoryUITests: `XCUIApplication.open(_:)`
/// relaunches the app.
final class Spike0417RepositoryTabsUITests: XCTestCase {
    private func deliver(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        var components = URLComponents()
        components.scheme = "switchyard"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        XCTAssertTrue(NSWorkspace.shared.open(components.url!),
                      "LaunchServices refused switchyard:// for \(path)", file: file, line: line)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: "windows=\(app.windows.count) tabs=\(app.tabs.count)\n"
            + app.debugDescription)
        tree.name = name + "-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    @MainActor
    func testRepositoriesOpenAsTabsOfOneWindow() {
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60),
                      "the app launched but opened no window")

        deliver(UITestFixture.repositoryPath)
        XCTAssertTrue(app.historyRows(containing: UITestFixture.tipSubject).firstMatch
            .waitForExistence(timeout: 30), "the first repository never appeared")

        deliver(UITestMapFixture.repositoryPath)
        XCTAssertTrue(app.historyRows(containing: UITestMapFixture.mainTip).firstMatch
            .waitForExistence(timeout: 30), "the second repository never appeared")
        attach(app, "repository-tabs")
        XCTAssertEqual(app.windows.count, 1, "the second repository is a tab, not a window")
        // Measured in the guest: the AppKit tab bar is a TabGroup titled
        // "tab bar" whose tabs are `Tab` elements titled by window title,
        // with value 1 for the selected tab and 0 for the others.
        let fixtureTab = app.tabs["uitest-fixture-repo"]
        let mapTab = app.tabs["uitest-map-repo"]
        XCTAssertTrue(fixtureTab.waitForExistence(timeout: 10), "no tab for uitest-fixture-repo")
        XCTAssertTrue(mapTab.exists, "no tab for uitest-map-repo")

        // Reopening the first repository selects its tab; no third tab.
        deliver(UITestFixture.repositoryPath)
        XCTAssertTrue(app.historyRows(containing: UITestFixture.tipSubject).firstMatch
            .waitForExistence(timeout: 30), "reopening did not bring the first repository's tab forward")
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertEqual(app.tabs.count, 2, "reopening added a tab")
        XCTAssertEqual(fixtureTab.value as? Int, 1, "reopening selects the repository's tab")

        // File ▸ New Tab: an empty third tab, titled like an empty window.
        app.typeKey("t", modifierFlags: .command)
        let empty = app.staticTexts.matching(NSPredicate(
            format: "value == %@ OR label == %@", "No repository open", "No repository open")).firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 30), "⌘T did not show an empty tab")
        XCTAssertEqual(app.windows.count, 1, "⌘T opened a window instead of a tab")
        XCTAssertEqual(app.tabs.count, 3)
        XCTAssertTrue(app.tabs["Switchyard"].exists, "the empty tab is titled Switchyard")
        attach(app, "repository-tabs-new-tab")

        // The tab bar's own "+" (AppKit's `newWindowForTab:`, answered by
        // SwiftUI from the group's defaultValue) must also add an EMPTY tab.
        app.tabGroups["tab bar"].buttons["new tab"].click()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, app.tabs.count < 4 { usleep(200_000) }
        attach(app, "repository-tabs-plus-button")
        XCTAssertEqual(app.tabs.count, 4, "the tab bar's + did not add a tab")
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertEqual(app.tabs.matching(NSPredicate(format: "title == %@", "Switchyard")).count, 2,
                       "the + tab must be empty, not a second view of the launch window")
        XCTAssertEqual(app.tabs.matching(NSPredicate(format: "title == %@", "uitest-fixture-repo")).count, 1,
                       "the launch window's repository must not appear in two tabs")

        // AppKit's window-tab commands are present.
        app.menuBars.menuBarItems["Window"].click()
        XCTAssertTrue(app.menuItems["Merge All Windows"].waitForExistence(timeout: 10),
                      "Window ▸ Merge All Windows is missing")
        attach(app, "window-menu")
        app.typeKey(.escape, modifierFlags: [])
    }
}
