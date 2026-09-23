// 0385AlertLiveUpdateUITests.swift
//
// #0395 round 2 re-derivation of #0385 — "do a confirming button's disabled
// state and the message update LIVE as the user types into the creation
// dialog?" — against the REAL app.
//
// Surface mapping, recorded: #0363's New Branch alert with a
// `RefNameProblem` message does not exist yet — the real creation surface is
// the commit action menu's "Create Branch…" sheet (CommitActionPromptSheet),
// whose Create button is disabled while the composed request is nil (an
// empty name) and enabled otherwise. This test drives that surface and
// asserts the spike's hypothesis in three steps: disabled while empty,
// re-enabled live after the first keystroke, disabled again for a name that
// collides with the fixture's existing branch. The collision assertion is
// the hypothesis under test — today's sheet has no collision check (that is
// precisely the behaviour #0363 will add), so a FAIL there is the recorded
// spike answer, not a broken round. The message half of the spike ("A branch
// named …") has no observable in the real sheet: no problem text exists
// there at all — also recorded as part of the answer.

import XCTest

final class Spike0385AlertLiveUpdateUITests: XCTestCase {

    @MainActor
    func testCreateBranchButtonUpdatesLiveWhileTyping() {
        let app = XCUIApplication()
        app.launchWithFixtureRepository()

        // The Commit menu acts on the selected commit.
        app.selectHistoryRow(subject: UITestFixture.tipSubject)

        // Open the real creation surface through the Commit menu's own key
        // equivalent (⌘⇧B, the "Create Branch…" shortcut on the menu bar's
        // Commit menu — the same menu whose items the first guest run's
        // element tree showed). Tapping a menu bar item to open its menu
        // measured unreliable in the guest; the equivalent is deterministic
        // and reaches the same sheet.
        app.typeKey("b", modifierFlags: [.command, .shift])

        // The sheet: title, name field, Create button.
        XCTAssertTrue(
            app.staticTexts["Create Branch"].waitForExistence(timeout: 10),
            "the Create Branch sheet never appeared after the menu item")
        let create = app.buttons["Create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10), "no Create button in the sheet")
        XCTAssertFalse(
            create.isEnabled,
            "Create must start DISABLED while the name field is empty — the " +
            "spike's first live state")

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no branch-name field in the sheet")
        field.tap()
        field.typeText("u")
        XCTAssertTrue(
            create.isEnabled,
            "Create must re-enable LIVE as the user types — it did not after " +
            "the first keystroke (the spike's fail shape: neither state updates)")

        // Complete the colliding name "uitest-main" — a branch the fixture
        // already has. The spike ASSUMES this disables Create again.
        field.typeText("itest-main")
        XCTAssertFalse(
            create.isEnabled,
            "The spike's assumption: a name that collides with the existing " +
            "branch disables Create. Today's sheet has no RefNameProblem " +
            "check (that is #0363's planned work), so a FAIL here RECORDS " +
            "that the assumption does not yet hold on the real surface — " +
            "#0363 must add the collision disabling this spike was to inform.")

        // Leave the sheet dismissed and the fixture untouched.
        app.buttons["Cancel"].tap()
        XCTAssertTrue(
            app.waitUntilDisappears(app.staticTexts["Create Branch"], timeout: 10),
            "Cancel did not dismiss the Create Branch sheet")
    }
}