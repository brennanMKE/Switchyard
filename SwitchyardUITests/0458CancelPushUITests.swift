import XCTest

/// #0458: a Push blocked in a slow pre-push hook shows "Pushing…" with
/// Cancel; Cancel stops it with no alert and the branch is still ahead.
final class Spike0458CancelPushUITests: XCTestCase {
    @MainActor
    func testCancelStopsASlowPush() {
        let app = XCUIApplication()
        app.launchWithRemoteFixture(UITestRemoteFixture.slowPushRepository)
        let ahead = "1 ahead of \(UITestRemoteFixture.upstream)"
        XCTAssertTrue(app.text(containing: ahead).waitForExistence(timeout: 30), "the fixture is not 1 ahead")

        app.remoteButton("push").click()
        XCTAssertTrue(app.text(containing: "Pushing…").waitForExistence(timeout: 10), "no Pushing… progress line")
        let cancel = app.buttons.matching(identifier: "remote-cancel").firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "no Cancel button beside Pushing…")

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "remote-pushing-cancel"
        shot.lifetime = .keepAlways
        add(shot)

        cancel.click()
        XCTAssertTrue(app.waitUntilDisappears(app.text(containing: "Pushing…"), timeout: 30),
                      "Cancel did not end the push")
        XCTAssertFalse(app.text(containing: "Couldn’t Push").exists, "a cancelled push presented an alert")
        XCTAssertTrue(app.text(containing: ahead).exists, "after Cancel the branch is no longer 1 ahead")
        XCTAssertTrue(app.remoteButton("push").isEnabled, "Push stayed disabled after Cancel")
    }
}
