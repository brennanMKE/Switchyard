import XCTest

/// #0466: the Amend checkbox fills the editor with HEAD's message and gives
/// the draft back when turned off; Amend replaces the fixture's one commit
/// with the staged change and the new message; Edit ▸ Undo Amend puts the
/// old commit and the staged change back.
final class Spike0466AmendUITests: XCTestCase {
    @MainActor
    func testAmendReplacesTheLastCommitAndUndoRestoresIt() {
        let app = XCUIApplication()
        app.launchWithChangesFixture()

        let staged = app.changesRow(UITestChangesFixture.staged, staged: true)
        XCTAssertTrue(staged.waitForExistence(timeout: 30), "staged.txt is not listed as staged")
        let message = app.textViews["commit-message"]
        let amend = app.checkBoxes["amend-checkbox"]
        let button = app.buttons["commit-button"]
        XCTAssertTrue(amend.waitForExistence(timeout: 30), "no Amend checkbox")
        // Disabled until the last commit has been read, then enabled.
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: amend)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 30), .completed,
                       "Amend stayed disabled on an unpushed commit")

        message.click()
        message.typeText("0466 draft")
        amend.click()
        XCTAssertEqual(message.value as? String, UITestChangesFixture.baseSubject,
                       "Amend did not fill the editor with HEAD's message")
        XCTAssertEqual(button.label, "Amend", "the button does not read Amend")
        amend.click()
        XCTAssertEqual(message.value as? String, "0466 draft", "turning Amend off lost the draft")
        XCTAssertEqual(button.label, "Commit")

        amend.click()
        message.click()
        message.typeKey("a", modifierFlags: .command)
        message.typeText("0466 amended base commit")
        button.click()

        let amended = app.historyRows(containing: "0466 amended base commit").firstMatch
        XCTAssertTrue(amended.waitForExistence(timeout: 30), "the amended commit is not in History")
        let base = app.historyRows(containing: UITestChangesFixture.baseSubject).firstMatch
        XCTAssertTrue(app.waitUntilDisappears(base, timeout: 30),
                      "the replaced commit is still in History: Amend added a commit")
        XCTAssertTrue(app.waitUntilDisappears(staged, timeout: 30), "staged.txt is still staged")
        XCTAssertEqual(button.label, "Commit", "the checkbox stayed on after the amend")

        let done = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        done.name = "changes-amend-done"
        done.lifetime = .keepAlways
        add(done)

        // Move focus off the message editor: the Edit menu's Undo forwards
        // to a first-responder text view (#0393).
        app.changesRow(UITestChangesFixture.untracked, staged: false).click()
        app.menuBars.menuBarItems["Edit"].click()
        let undo = app.menuBars.menuItems["Undo Amend"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the Edit menu offers no Undo Amend")
        undo.click()
        XCTAssertTrue(app.historyRows(containing: UITestChangesFixture.baseSubject).firstMatch
            .waitForExistence(timeout: 30), "Undo Amend did not bring the old commit back")
        XCTAssertTrue(app.waitUntilDisappears(amended, timeout: 30), "the amended commit is still in History")
        XCTAssertTrue(
            app.changesRow(UITestChangesFixture.staged, staged: true).waitForExistence(timeout: 30),
            "Undo Amend did not put staged.txt back in Staged Changes")

        let undone = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        undone.name = "changes-amend-undone"
        undone.lifetime = .keepAlways
        add(undone)
    }
}

/// #0466: on a branch whose last commit is already on its upstream, the
/// Amend checkbox is disabled.
final class Spike0466AmendPushedUITests: XCTestCase {
    @MainActor
    func testAmendIsDisabledWhenTheLastCommitIsPushed() {
        let app = XCUIApplication()
        app.launchWithRemoteFixture(UITestRemoteFixture.pullRepository)
        let amend = app.checkBoxes["amend-checkbox"]
        XCTAssertTrue(amend.waitForExistence(timeout: 30), "no Amend checkbox")
        XCTAssertFalse(amend.isEnabled, "Amend is enabled on a commit that is already on origin")
        // The checkbox is also disabled while the target loads, so the
        // check that counts is that it never turns enabled: a bounded wait
        // for "enabled" that must time out. On the unpushed changes fixture
        // the same checkbox turns enabled well inside this bound.
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: amend)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .timedOut,
                       "Amend became enabled on a commit that is already on origin")

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "changes-amend-pushed"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
