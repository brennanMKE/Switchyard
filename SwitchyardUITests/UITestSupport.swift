// UITestSupport.swift
//
// #0395 round 2: shared fixture constants and query helpers for the four
// spike re-derivations. The fixture repository's shape is generated per run
// by scripts/run-ui-tests-vm.sh inside the guest — keep the two in sync:
// four commits (root/second/third/tip, subjects below), local branches
// `spike-side` and `alpha-fork`, remote-tracking ref `origin/uitest-side`
// at the tip, tag `v0.1` at the tip.

import Darwin
import XCTest

/// The fixture `scripts/run-ui-tests-vm.sh` generates inside the guest.
enum UITestFixture {
    static let repositoryPath = "/Users/admin/uitest-fixture-repo"
    /// The fixture's checked-out branch.
    static let branch = "uitest-main"
    /// The fixture's git author (`user.name`) — every commit's by-line.
    static let author = "Switchyard UI Test"
    /// The four fixture commit subjects, oldest first.
    static let rootSubject = "0382 root commit"
    static let secondSubject = "0382 second commit"
    static let thirdSubject = "0382 third commit"
    static let tipSubject = "0382 tip commit"
    /// The sidebar's two non-current branches.
    static let sideBranch = "spike-side"
    static let filterBranch = "alpha-fork"
    static let olderBranch = "beta-older"
    /// The remote-tracking ref's short name and the tag (sidebar sections).
    static let remoteBranch = "origin/uitest-side"
    static let tag = "v0.1"
    /// The subject of the commit `git revert` writes for the tip.
    static let revertSubject = "Revert \"0382 tip commit\""
}

extension XCUIApplication {
    /// Launches the app with the fixture repository open and the REAL
    /// content view rendered — the `-uiTestRealSurfaces` opt-in the launch
    /// hook in SwitchyardApp.swift reads. Round 1's smoke test passes only
    /// `-uiTestRepository` and keeps its minimal branch view.
    ///
    /// Launch-count quirk, measured 2026-09-22 in the guest (five runs plus
    /// a four-launch manual probe): an app instance opens its window on a
    /// session's first two XCUITest launches and on NO later one — and a
    /// session whose first launch failed never opens one again. The run
    /// script therefore reboots the guest between invocations and runs the
    /// smoke test first in every invocation, so the real launch below is
    /// always the session's second, the shape measured to always open its
    /// window. Direct launches of the same binary never miss a window, so
    /// this is an automation-launch property, not an app defect. The wait
    /// below keeps its own bound and, on failure, puts the app's element
    /// tree into the message so a red run is self-describing.
    @MainActor
    func launchWithFixtureRepository() {
        launchArguments = [
            "-uiTestRepository", UITestFixture.repositoryPath,
            "-uiTestRealSurfaces",
        ]
        launch()
        let tree = debugDescription
        XCTAssertTrue(
            windows.firstMatch.waitForExistence(timeout: 60),
            "The app launched but opened no window within 60 s — its element " +
            "tree starts with: \(String(tree.prefix(1200)))",
            file: #filePath, line: #line)
    }

    /// One History row, found by its combined accessibility label
    /// ("subject, commit <oid>, by <author>[, chips…]"). Measured on the
    /// macOS 26.6 guest: the combined row renders as ONE StaticText whose
    /// full text rides in `value`, not `label`, so the predicate matches
    /// both attributes — and the query is rooted at `staticTexts` rather
    /// than all descendants: a whole-app `.any` snapshot measured past the
    /// UI-query timeout in the guest (three times in a row), while the
    /// static-text search returns promptly. The `by`-tail keeps rows apart
    /// from the Detail pane's standalone subject headline.
    @MainActor
    func historyRows(containing subject: String) -> XCUIElementQuery {
        let byLine = "by \(UITestFixture.author)"
        return staticTexts.matching(NSPredicate(
            format: "(label CONTAINS %@ AND label CONTAINS %@) OR " +
                "(value CONTAINS %@ AND value CONTAINS %@)",
            subject, byLine, subject, byLine))
    }

    /// A sidebar ref row by its exact short name — a bare `Label` in the
    /// sidebar list whose text rides in `value` (or `label`), so exact
    /// matching keeps it apart from substrings that also occur in history
    /// chips, the window subtitle, and the worktree row's branch line.
    @MainActor
    func sidebarRow(named name: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(
            format: "value == %@ OR label == %@", name, name)).firstMatch
    }

    /// The sidebar's filter field (#0378's `.searchable` field — it renders
    /// as a SearchField with the 'Filter' placeholder).
    @MainActor
    func sidebarFilterField() -> XCUIElement {
        searchFields.matching(NSPredicate(
            format: "placeholderValue == 'Filter' OR label == 'Filter'")).firstMatch
    }

    /// Bounded wait for an element to LEAVE the accessibility tree (a
    /// collapsed section's rows, a row narrowed away by the filter). A wait
    /// bound, not a timing assertion: nothing here compares elapsed time.
    @discardableResult
    
    @MainActor
    func waitUntilDisappears(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(100_000)
        }
        return !element.exists
    }

    /// Selects the History row whose subject is `subject` and asserts the
    /// selection took: the Detail pane renders the subject as a standalone
    /// headline only for the selected commit.
    
    @MainActor
    func selectHistoryRow(subject: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = historyRows(containing: subject).firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 30),
            "No History row for “\(subject)” — the fixture repository did not " +
            "load into the real panes (launch hook, engine load, or window).",
            file: file, line: line)
        row.tap()
        let detailHeadline = staticTexts.matching(NSPredicate(
            format: "value == %@ OR label == %@", subject, subject)).firstMatch
        XCTAssertTrue(
            detailHeadline.waitForExistence(timeout: 30),
            "Tapping the “\(subject)” row did not select it — the Detail pane " +
            "never showed the commit, so the menu target below is unbacked.",
            file: file, line: line)
    }
}