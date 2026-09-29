import XCTest

/// #0457: Fetch shows the new remote commit as "1 behind" in the header,
/// Pull fast-forwards the branch onto it, and Edit ▸ Undo Pull takes the
/// pull back to "1 behind" — the fetch stays, it is its own entry. The remote is a bare repository inside the guest (#0455).
final class Spike0457FetchPullUITests: XCTestCase {
    @MainActor
    func testFetchThenPullThenUndoPull() {
        let app = XCUIApplication()
        app.launchWithRemoteFixture(UITestRemoteFixture.pullRepository)
        let upToDate = "up to date with \(UITestRemoteFixture.upstream)"
        XCTAssertTrue(app.text(containing: upToDate).waitForExistence(timeout: 30),
                      "the header does not start up to date")

        let fetch = app.remoteButton("fetch")
        XCTAssertTrue(fetch.waitForExistence(timeout: 10), "no Fetch button in the toolbar")
        XCTAssertTrue(fetch.isEnabled, "Fetch is disabled with a remote configured")
        fetch.click()
        XCTAssertTrue(
            app.text(containing: "1 behind \(UITestRemoteFixture.upstream)").waitForExistence(timeout: 60),
            "after Fetch the header does not say 1 behind")

        let pull = app.remoteButton("pull")
        XCTAssertTrue(pull.isEnabled, "Pull is disabled on a branch with an upstream")
        pull.click()
        let pulled = app.historyRows(containing: UITestRemoteFixture.remoteSubject).firstMatch
        XCTAssertTrue(pulled.waitForExistence(timeout: 60), "Pull did not bring the remote commit into History")
        XCTAssertTrue(app.text(containing: upToDate).waitForExistence(timeout: 30),
                      "after Pull the header is not up to date")

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "remote-pulled"
        shot.lifetime = .keepAlways
        add(shot)

        // Select a commit so no text view is first responder (#0448).
        app.selectHistoryRow(subject: UITestRemoteFixture.remoteSubject)
        app.menuBars.menuBarItems["Edit"].click()
        let undo = app.menuBars.menuItems["Undo Pull"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the Edit menu offers no Undo Pull")
        undo.click()
        // Undo Pull restores the state before the pull, and that state
        // already had the fetch: the branch is 1 behind again, and the
        // remote commit stays in History as origin's.
        XCTAssertTrue(
            app.text(containing: "1 behind \(UITestRemoteFixture.upstream)").waitForExistence(timeout: 30),
            "after Undo Pull the header does not say 1 behind")
    }
}

/// #0457: a Pull that cannot fast-forward shows an alert with git's own
/// line and our advice, and changes nothing.
final class Spike0457PullRefusedUITests: XCTestCase {
    @MainActor
    func testDivergedPullShowsAnAlert() {
        let app = XCUIApplication()
        app.launchWithRemoteFixture(UITestRemoteFixture.divergedRepository)
        let pull = app.remoteButton("pull")
        XCTAssertTrue(pull.waitForExistence(timeout: 30), "no Pull button in the toolbar")
        pull.click()

        let title = app.text(containing: "Couldn’t Pull")
        XCTAssertTrue(title.waitForExistence(timeout: 60), "no Couldn’t Pull alert")
        XCTAssertTrue(app.text(containing: "Not possible to fast-forward").exists,
                      "the alert does not show git's fatal line")
        XCTAssertTrue(app.text(containing: "have diverged").exists, "the alert does not explain")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "remote-pull-refused"
        shot.lifetime = .keepAlways
        add(shot)
        // Return presses the alert's default OK (a `buttons["OK"]` query
        // also matches the Touch Bar's copy, which cannot be clicked).
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.text(containing: "1 ahead, 1 behind").waitForExistence(timeout: 30),
                      "after the refused Pull the header does not show the divergence it fetched")
    }
}
