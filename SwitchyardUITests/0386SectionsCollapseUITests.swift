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
//      measured across three guest runs, macOS 26.6.2/Xcode 27.0 drew no
//      chevron in the sidebar (on screen or in the accessibility tree, even
//      hovered) and clicking the header did not toggle the section —
//      #0398 shipped the fail branch, moving each ref section onto a
//      DisclosureGroup inside a plain Section, and the guest now renders a
//      DisclosureTriangle per ref section (measured in the same pipeline),
//      so these assertions pin the working toggle.
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
        // then click its disclosure control — rows hide and show. #0398
        // moved the ref sections onto DisclosureGroup, and the guest
        // renders the control as a DisclosureTriangle at the header cell's
        // leading edge (identifier NSOutlineViewDisclosureButtonKey) — a
        // Finder-sidebar disclosure. The tap targets the control ELEMENT
        // itself: coordinate arithmetic through app.coordinate(_:)
        // measured unreliable in this guest (two runs recorded the press at
        // the hovered cell's centre x, ~40pt right of the intended
        // minX+6), and an element tap is the stronger assertion anyway —
        // the control must exist in the accessibility tree for the test to
        // proceed, which is #0386's original question.
        let sidebar = app.outlines.matching(
            NSPredicate(format: "label == 'Sidebar' OR identifier == 'Sidebar'")).firstMatch
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: 10),
            "the sidebar Outline never rendered")
        // #0398: each ref section is a DisclosureGroup inside a plain
        // Section now, and the outline renders a 0-height separator row
        // before each DisclosureGroup — so positional indices drift with
        // every row-shape change and the header is found by its label
        // instead. For this fixture the outline's rows in order are: a
        // separator, the Branches header, uitest-main, alpha-fork,
        // spike-side, a separator, the Remotes header, a separator, the
        // Tags header, the Worktrees header, the worktree row, the Stashes
        // header, the stash row — thirteen cells.
        XCTAssertTrue(
            sidebar.cells.count >= 9,
            "the sidebar rendered \(sidebar.cells.count) rows — expected the " +
            "fixture's thirteen (the ten content rows plus three section separators)")
        let remotesHeader = sidebar.cells.containing(
            NSPredicate(format: "label == 'Remotes'")).firstMatch
        XCTAssertTrue(
            remotesHeader.waitForExistence(timeout: 10),
            "the Remotes section header row never rendered")
        let remotesDisclosure = remotesHeader.disclosureTriangles.firstMatch
        XCTAssertTrue(
            remotesDisclosure.waitForExistence(timeout: 10),
            "the Remotes section's disclosure control never rendered — " +
            "#0386's no-chevron measurement would apply again")
        XCTAssertFalse(
            remotesDisclosure.frame.isEmpty,
            "the Remotes disclosure control's frame did not resolve — the " +
            "control is present but has no visible extent to click")
        remotesHeader.hover()
        remotesDisclosure.tap()
        XCTAssertTrue(
            remoteRow.waitForExistence(timeout: 10),
            "clicking the Remotes disclosure did not expand the section — " +
            "the DisclosureTriangle is not toggling the DisclosureGroup")
        remotesHeader.hover()
        remotesDisclosure.tap()
        XCTAssertTrue(
            app.waitUntilDisappears(remoteRow, timeout: 10),
            "clicking the Remotes disclosure again did not collapse the section")
    }
}