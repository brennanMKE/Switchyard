// 0435OpenSecondRepositoryUITests.swift
//
// #0435: after File ▸ Open picks a second repository, THAT repository is
// what the new tab shows -- never the launch repository. Brennan hit the
// opposite on 2026-09-27: launched with `-uiTestRepository <Switchyard>
// -uiTestRealSurfaces`, opened Batty, and the new tab showed Switchyard.
//
// Two classes, one per launch style, because the launch-count quirk in
// UITestSupport.swift allows one real launch per clone: the run script
// gives each its own `run_spike_if_selected 0435 …` line.
//
// The open goes through the real File ▸ Open… panel (`NSOpenPanel`,
// `RepositoryOpener.chooseAndOpen`), driven by keyboard: ⌘⇧G, the path,
// Return, then the panel's Open button. Nothing here clicks near the top
// right of the screen, where the "App Background Activity" banner lands
// (#0432).

import XCTest

extension XCUIApplication {
    /// Opens `path` through File ▸ Open… -- the menu item and the toolbar's
    /// Open… button both call `RepositoryOpener.chooseAndOpen`. Keyboard
    /// only once the panel is up: measured in the guest, the panel's "Open"
    /// button query also matches a Touch Bar element that cannot be clicked,
    /// and Return presses the panel's default button, which is Open.
    @MainActor
    func openThroughFilePanel(
        _ path: String, test: XCTestCase, file: StaticString = #filePath, line: UInt = #line
    ) {
        menuBars.menuBarItems["File"].click()
        menuBars.menuItems["Open…"].click()
        let openButton = buttons["Open"].firstMatch
        XCTAssertTrue(openButton.waitForExistence(timeout: 30),
                      "File ▸ Open… showed no panel", file: file, line: line)
        typeKey("g", modifierFlags: [.command, .shift])
        usleep(1_000_000) // the Go to Folder sheet takes the keyboard focus
        typeText(path)
        typeKey(.return, modifierFlags: [])
        usleep(1_000_000) // the panel navigates to `path`
        attach(test, self, "0435-panel-at-\(URL(fileURLWithPath: path).lastPathComponent)")
        typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntilDisappears(openButton, timeout: 20),
                      "the open panel never closed", file: file, line: line)
    }
}

@MainActor
private func attach(_ test: XCTestCase, _ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    test.add(shot)
    let tree = XCTAttachment(string: "windows=\(app.windows.count) tabs=\(app.tabs.count)\n"
        + app.debugDescription)
    tree.name = name + "-tree"
    tree.lifetime = .keepAlways
    test.add(tree)
}

/// Brennan's launch: `-uiTestRepository <A> -uiTestRealSurfaces`, then
/// File ▸ Open… B.
final class Spike0435LaunchArgumentOpenUITests: XCTestCase {
    @MainActor
    func testOpeningASecondRepositoryShowsIt() {
        let app = XCUIApplication()
        app.launchWithFixtureRepository()
        XCTAssertTrue(app.historyRows(containing: UITestFixture.tipSubject).firstMatch
            .waitForExistence(timeout: 30), "the launch repository never appeared")

        app.openThroughFilePanel(UITestMapFixture.repositoryPath, test: self)
        let mapShown = app.historyRows(containing: UITestMapFixture.mainTip).firstMatch
            .waitForExistence(timeout: 30)
        attach(self, app, "0435-launch-argument-after-open")
        XCTAssertTrue(mapShown, "the opened repository never appeared -- the new tab showed something else")
        XCTAssertTrue(app.tabs["uitest-map-repo"].exists, "no tab titled for the opened repository")
        XCTAssertTrue(app.tabs["uitest-fixture-repo"].exists, "the launch repository's tab is gone")
        XCTAssertEqual(app.tabs.count, 2, "one tab per repository")
    }
}

/// A person's launch: no arguments, then File ▸ Open… A, then B.
final class Spike0435PlainLaunchOpenUITests: XCTestCase {
    @MainActor
    func testOpeningTwoRepositoriesShowsEach() {
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60),
                      "the app launched but opened no window")

        app.openThroughFilePanel(UITestFixture.repositoryPath, test: self)
        let firstShown = app.historyRows(containing: UITestFixture.tipSubject).firstMatch
            .waitForExistence(timeout: 30)
        attach(self, app, "0435-plain-after-first-open")
        XCTAssertTrue(firstShown, "the first repository never appeared")

        app.openThroughFilePanel(UITestMapFixture.repositoryPath, test: self)
        let secondShown = app.historyRows(containing: UITestMapFixture.mainTip).firstMatch
            .waitForExistence(timeout: 30)
        attach(self, app, "0435-plain-after-second-open")
        XCTAssertTrue(secondShown, "the second repository never appeared")
        XCTAssertTrue(app.tabs["uitest-map-repo"].exists, "no tab titled for the second repository")
        XCTAssertTrue(app.tabs["uitest-fixture-repo"].exists, "the first repository's tab is gone")
        XCTAssertEqual(app.tabs.count, 2, "one tab per repository")
    }
}
