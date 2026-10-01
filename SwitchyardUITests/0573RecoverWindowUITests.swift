// 0573RecoverWindowUITests.swift
//
// #0573: a window whose refresh failed — its repository moved away while
// the app was in the background — shows the repository again once the
// folder is back and the app is activated.

import XCTest

final class Spike0573RecoverWindowUITests: XCTestCase {
    /// Sends the app to the background and back: #0447's refresh trigger.
    @MainActor
    private func deactivateAndReturn(_ app: XCUIApplication) {
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        usleep(1_500_000)
        app.activate()
    }

    @MainActor
    func testTheWindowRecoversWhenTheRepositoryComesBack() throws {
        let app = XCUIApplication()
        app.launchWithFixtureRepository()
        let header = app.header(beginningWith: "On branch \(UITestFixture.branch)")
        XCTAssertTrue(header.waitForExistence(timeout: 30), "the fixture did not open")

        let repo = UITestFixture.repositoryPath
        let moved = repo + "-moved"
        try FileManager.default.moveItem(atPath: repo, toPath: moved)
        deactivateAndReturn(app)
        XCTAssertTrue(app.text(containing: "Couldn't open").waitForExistence(timeout: 30),
                      "the refresh did not notice the repository was gone")

        try FileManager.default.moveItem(atPath: moved, toPath: repo)
        deactivateAndReturn(app)
        XCTAssertTrue(header.waitForExistence(timeout: 30),
                      "the window stayed on Couldn't open after the repository came back")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "0573-recovered"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
