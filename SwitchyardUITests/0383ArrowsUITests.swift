// 0383ArrowsUITests.swift
//
// #0395 round 2 re-derivation of #0383 — "do ⌥⌘↑ and ⌥⌘↓ reach the menu bar
// while the History list has focus, or does the list consume them?" —
// against the REAL app.
//
// The spike's Move Up / Move Down keys are, in the real app (#0359), already
// allocated: ⌥⌘↑ is "Swap with Child" and ⌥⌘↓ is "Swap with Parent" in the
// menu bar's Commit menu. So the observation maps directly: select a row for
// which both actions are enabled (the chain's third commit — its parent is
// not the root and it is not the tip), leave the list focused, press each
// arrow once, and assert the swap each key names actually ran. A successful
// swap flips the two rows' vertical order — the observable; the selection
// then moves to the acted-on commit by design (RewriteSelection), which is
// the app's own post-action behaviour, NOT the list consuming the key.
// Order unchanged = the key never reached the menu (spike's fail shape).

import XCTest

final class Spike0383ArrowsUITests: XCTestCase {

    /// Bounded wait until the row `above` sits above the row `below` on
    /// screen (the order flip a swap produces). Frames, not elapsed time.
    
    @MainActor
    private func assertRowOrderFlipped(
        _ app: XCUIApplication, above: String, below: String,
        timeout: TimeInterval, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var flipped = false
        while Date() < deadline {
            // #0410: the reorder leaves spike-side and alpha-fork on the old
            // commits, so compare the nodes in HEAD's lane.
            if let upper = app.headLaneNode(containing: above),
               let lower = app.headLaneNode(containing: below),
               upper.frame.minY < lower.frame.minY {
                flipped = true
                break
            }
            usleep(200_000)
        }
        XCTAssertTrue(flipped, message, file: file, line: line)
    }

    @MainActor
    func testOptionCommandArrowsReachTheCommitMenuWhileHistoryListFocused() {
        let app = XCUIApplication()
        app.launchWithFixtureRepository()

        // The chain's third commit: Swap with Child is enabled (not the tip)
        // and Swap with Parent is enabled (its parent is not the root).
        app.selectHistoryRow(subject: UITestFixture.thirdSubject)

        // Sanity on the fixture before any key is pressed: tip on top.
        assertRowOrderFlipped(
            app, above: UITestFixture.tipSubject, below: UITestFixture.thirdSubject,
            timeout: 10, "the fixture's initial order is wrong — tip must sit above third")

        // ⌥⌘↑ — Swap with Child: third swaps with the tip and takes the top.
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        assertRowOrderFlipped(
            app, above: UITestFixture.thirdSubject, below: UITestFixture.tipSubject,
            timeout: 30,
            "⌥⌘↑ produced no Swap-with-Child effect while the History list was " +
            "focused: the list consumed the key (spike's fail shape — #0359 " +
            "would move these actions to ⌥⌘[ and ⌥⌘]) or the engine call failed.")

        // ⌥⌘↓ — Swap with Parent: third (now the tip) swaps back down.
        app.typeKey(.downArrow, modifierFlags: [.command, .option])
        assertRowOrderFlipped(
            app, above: UITestFixture.tipSubject, below: UITestFixture.thirdSubject,
            timeout: 30,
            "⌥⌘↓ produced no Swap-with-Parent effect while the History list was " +
            "focused: the list consumed it, or the second action was dropped.")

        // Diagnostic: an engine failure presents this alert instead of the
        // reorder — a red run must say which path broke.
        XCTAssertFalse(
            app.staticTexts["Couldn’t Move Commit"].exists,
            "A move engine call failed — the order above is measuring the " +
            "failure alert, not the spike's key dispatch.")
    }
}