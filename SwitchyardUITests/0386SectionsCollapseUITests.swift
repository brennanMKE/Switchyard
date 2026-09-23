// 0386SectionsCollapseUITests.swift
//
// #0395 round 2 re-derivation of #0386 — "does Section(_:isExpanded:)
// collapse in the macOS 26 sidebar list, including with a .searchable filter
// on the same list?" — against the REAL sidebar (RepositorySidebarView,
// #0371/#0378 already shipped it).
//
// The filter half runs FIRST (it does not depend on the disclosure toggle),
// so one run records both halves even when the toggle half fails — which is
// the shape the guest measured (see below). Observables:
//   1. Defaults: Branches expanded, Remotes and Tags collapsed (#0371).
//   2. A filter query narrows non-matching rows away and surfaces matches
//      inside a COLLAPSED section (#0386's step 3 — #0378's specified
//      behaviour); clearing restores the stored collapsed state.
//   3. Hovering a section header and clicking its disclosure (or the
//      header) must toggle the rows. The control is the spike's question:
//      measured across three guest runs, macOS 26.6.2/Xcode 27.0 draws no
//      chevron in the sidebar (on screen or in the accessibility tree, even
//      hovered) and clicking the header does not toggle the section — so
//      the assertions below record the spike's fail branch (#0371 switches
//      to DisclosureGroup per section) unless a future run proves otherwise.
//
// The spike's step-2 side observation ("the right-hand status text") has no
// equivalent to assert here — the real sidebar carries per-branch status
// text (#0372), not a collapse state read-out — so the collapse signal is
// the rows themselves, which is the spike's primary question.

import XCTest

final class Spike0386SectionsCollapseUITests: XCTestCase {

    @MainActor
    func testSidebarSectionsCollapseExpandAndFilter() {
        let app = XCUIApplication()
        app.launchWithFixtureRepository()

        // #0371's defaults: Branches expanded (its rows visible), Remotes and
        // Tags collapsed (their rows absent).
        XCTAssertTrue(
            app.sidebarRow(named: UITestFixture.sideBranch).waitForExistence(timeout: 30),
            "the sidebar never rendered its Branches rows — the fixture did not load")
        let remoteRow = app.sidebarRow(named: UITestFixture.remoteBranch)
        let tagRow = app.sidebarRow(named: UITestFixture.tag)
        XCTAssertTrue(
            app.waitUntilDisappears(remoteRow, timeout: 10),
            "the Remotes section must start collapsed (its row is absent)")
        XCTAssertTrue(
            app.waitUntilDisappears(tagRow, timeout: 10),
            "the Tags section must start collapsed (its row is absent)")

        // The spike's step 3, on the real sidebar — FIRST, because it does
        // not depend on the disclosure toggle: with Remotes COLLAPSED, a
        // filter query must surface the matching rows (#0378's specified
        // behaviour — matches show inside a collapsed section while
        // filtering).
        let filter = app.sidebarFilterField()
        XCTAssertTrue(
            filter.waitForExistence(timeout: 10),
            "no sidebar filter field — #0378's .searchable field never rendered")
        filter.tap()
        filter.typeText("origin")
        XCTAssertTrue(
            remoteRow.waitForExistence(timeout: 10),
            "filtering did not surface the Remotes match inside the collapsed " +
            "section — #0378 must expand sections while filtering, as specified")
        XCTAssertTrue(
            app.waitUntilDisappears(app.sidebarRow(named: UITestFixture.sideBranch), timeout: 10),
            "non-matching branch rows must narrow away while filtering")

        // Clearing restores the stored (collapsed) layout.
        filter.tap()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(
            app.waitUntilDisappears(remoteRow, timeout: 10),
            "clearing the filter did not restore the Remotes section's stored " +
            "collapsed state — filtering mutated the expansion state")

        // Narrowing: only matching branch rows remain.
        filter.typeText("spike")
        XCTAssertTrue(
            app.sidebarRow(named: UITestFixture.sideBranch).waitForExistence(timeout: 10),
            "the matching branch row did not survive the filter")
        XCTAssertTrue(
            app.waitUntilDisappears(app.sidebarRow(named: UITestFixture.filterBranch), timeout: 10),
            "a non-matching branch row must narrow away while filtering")
        // Clear before the toggle attempts so the sidebar is unfiltered.
        filter.tap()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(
            app.waitUntilDisappears(remoteRow, timeout: 10),
            "clearing the filter must leave the Remotes section collapsed again")

        // The spike's step 2 on the real sidebar: hover the section header,
        // then click its disclosure control (or the header) — rows hide and
        // show. The guest's recording shows macOS 26 draws no chevron in the
        // sidebar (even hovered), and a click on the header's text center did
        // not toggle the section (measured twice), so the click targets the
        // header CELL's leading edge — where a Finder-sidebar disclosure
        // control sits. The control is no separate accessibility element in
        // the guest's tree.
        let sidebar = app.outlines.matching(
            NSPredicate(format: "label == 'Sidebar' OR identifier == 'Sidebar'")).firstMatch
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: 10),
            "the sidebar Outline never rendered")
        // For this fixture the outline's rows in order are: Branches header,
        // uitest-main, alpha-fork, spike-side, Remotes header, Tags header,
        // Worktrees header, the worktree row, Stashes header, the stash row.
        XCTAssertTrue(
            sidebar.cells.count >= 9,
            "the sidebar rendered \(sidebar.cells.count) rows — expected the " +
            "fixture's ten (three ref sections plus the four plain sections)")
        let remotesHeader = sidebar.cells.element(boundBy: 4)
        XCTAssertTrue(
            remotesHeader.waitForExistence(timeout: 10),
            "the Remotes section header row never rendered")
        let headerFrame = remotesHeader.frame
        XCTAssertFalse(
            headerFrame.isEmpty,
            "the Remotes header cell's frame did not resolve — the click below " +
            "would land nowhere")
        remotesHeader.hover()
        let appFrame = app.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(
                dx: headerFrame.minX - appFrame.minX + 6,
                dy: headerFrame.midY - appFrame.minY))
            .tap()
        XCTAssertTrue(
            remoteRow.waitForExistence(timeout: 10),
            "clicking the Remotes disclosure did not expand the section — " +
            "#0371's fail branch (DisclosureGroup) applies")
        remotesHeader.hover()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(
                dx: headerFrame.minX - appFrame.minX + 6,
                dy: headerFrame.midY - appFrame.minY))
            .tap()
        XCTAssertTrue(
            app.waitUntilDisappears(remoteRow, timeout: 10),
            "clicking the Remotes disclosure again did not collapse the section")
    }
}