import XCTest

/// #0459: the first Push of a branch with no upstream sets one — the header
/// reads "up to date with origin/push-feature" — and Edit ▸ Undo then
/// reads "Can’t Undo Push", disabled.
final class Spike0459PushUITests: XCTestCase {
    @MainActor
    func testFirstPushSetsUpstreamAndCannotBeUndone() {
        let app = XCUIApplication()
        app.launchWithRemoteFixture(UITestRemoteFixture.pushRepository)
        XCTAssertTrue(app.text(containing: "no upstream").waitForExistence(timeout: 30),
                      "the fixture branch already has an upstream")

        let push = app.remoteButton("push")
        XCTAssertTrue(push.isEnabled, "Push is disabled for a branch with no upstream")
        push.click()
        let tracking = "up to date with origin/\(UITestRemoteFixture.pushBranch)"
        XCTAssertTrue(app.text(containing: tracking).waitForExistence(timeout: 60),
                      "after Push the header does not show the new upstream")
        XCTAssertFalse(app.remoteButton("push").isEnabled, "Push is still enabled with nothing to push")

        app.selectHistoryRow(subject: "0459 pushed commit")
        app.menuBars.menuBarItems["Edit"].click()
        let undo = app.menuBars.menuItems["Can’t Undo Push"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the Edit menu does not say Can’t Undo Push")
        XCTAssertFalse(undo.isEnabled, "Can’t Undo Push is enabled")

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "remote-cant-undo-push"
        shot.lifetime = .keepAlways
        add(shot)
        app.typeKey(.escape, modifierFlags: [])
    }
}
