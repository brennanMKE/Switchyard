// 0382ContextKeysUITests.swift
//
// #0395 round 2 re-derivation of #0382 — "do context-menu key equivalents
// fire while the menu is closed, and does a shared equivalent fire once,
// not twice?" — against the REAL app.
//
// Key mapping, recorded because the spike's ⌥⌘K/⌥⌘J are the #0380 spike
// app's keys, which the real app does not carry: #0359 renders ONE
// `CommitActionMenuItems` body in both the History row's context menu and
// the menu bar's Commit menu, so every real equivalent
// (CommitActions.shortcut) is registered twice — there is no context-menu-
// only item to press. The spike's questions therefore collapse onto the
// shared equivalent, and the test answers them with:
//   ⌥⌘K — unbound in the app (the spike's context-only key): negative
//         control, nothing may fire.
//   ⌥⌘R — the real "Revert" Commit-menu equivalent, shared by the context
//         menu copy and the menu bar copy: with a row selected and NO menu
//         open, exactly one effect may appear.
// The observable is a revert row in the History pane (the engine call's
// effect). A double dispatch would lay a second revert row; the busy guard
// would instead drop the second firing — either way "two effects" cannot
// hide, which is the spike's pass criterion ("exactly one line").
//
// macOS 26.6.2 guest, Xcode 27.0 — recorded with the run that executes this.

import XCTest

final class Spike0382ContextKeysUITests: XCTestCase {

    /// Bounded wait until the History shows exactly `expected` revert rows.
    
    @MainActor
    private func assertRevertRowCount(
        _ app: XCUIApplication, _ expected: Int, timeout: TimeInterval, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.historyRows(containing: UITestFixture.revertSubject).count >= expected { break }
            usleep(200_000)
        }
        XCTAssertEqual(
            app.historyRows(containing: UITestFixture.revertSubject).count, expected,
            message, file: file, line: line)
    }

    /// The spike's steps 1–2 on the real app: with the History list focused,
    /// a row selected and NO menu open, an unbound key fires nothing, and the
    /// Commit menu's shared ⌥⌘R (Revert) fires exactly once.
    @MainActor
    func testSharedCommitEquivalentFiresOnceWithNoMenuOpen() {
        let app = XCUIApplication()
        app.launchWithFixtureRepository()
        app.selectHistoryRow(subject: UITestFixture.tipSubject)

        // No menu was ever opened; nothing has fired yet.
        assertRevertRowCount(app, 0, timeout: 5, "⌥⌘R must not fire before it is pressed")

        // Negative control: the spike's context-only key ⌥⌘K is registered
        // nowhere in the real app — it must produce no effect at all.
        app.typeKey("k", modifierFlags: [.command, .option])
        assertRevertRowCount(
            app, 0, timeout: 3,
            "⌥⌘K is bound to no menu item; an effect here would mean a stray " +
            "registration, not the spike's question")

        // The shared equivalent, pressed with no menu open. The menu-bar
        // Commit item is enabled (a row is selected); whether the context
        // menu's own registration also fires is exactly what this counts.
        app.typeKey("r", modifierFlags: [.command, .option])
        assertRevertRowCount(
            app, 1, timeout: 30,
            "⌥⌘R with no menu open: expected exactly one Revert row. Zero means " +
            "the equivalent did not fire (list ate it, or the engine call " +
            "failed); two mean the duplicate registration double-fired and " +
            "#0359 must stop registering shortcuts on the context-menu copy.")
        // Diagnostic, not the finding: an engine failure presents its alert
        // instead of the row — a red run must say which path broke.
        XCTAssertFalse(
            app.staticTexts["Couldn’t Revert Commit"].exists,
            "The revert engine call failed — the count above is measuring the " +
            "failure alert, not the spike's key dispatch.")

        // The settle window a second (double) dispatch would need.
        assertRevertRowCount(app, 1, timeout: 5, "a second firing landed late")
    }
}