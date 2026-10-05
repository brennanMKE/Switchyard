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

extension XCUIApplication {
    /// #0410: the map node for `subject` in the leftmost lane that has one.
    /// A rewrite leaves branches on the old commits, so after a reorder
    /// the same subject can sit in two lanes; `HEAD`'s lane is lane 0.
    @MainActor
    func headLaneNode(containing subject: String) -> XCUIElement? {
        historyRows(containing: subject).allElementsBoundByIndex
            .filter(\.exists)
            .min { $0.frame.minX < $1.frame.minX }
    }
}

/// #0410: the branch-map fixture scripts/uitest-fixtures/make-map-fixture.sh
/// generates inside the guest — keep the two in sync.
enum UITestMapFixture {
    static let repositoryPath = "/Users/admin/uitest-map-repo"
    /// Tip subjects of four lanes that must share the top row.
    static let mainTip = "map main 12"
    static let newestLaneTip = "lane-01 commit"
    static let nearTip = "near commit 2"
    static let midTip = "mid commit 3"
    /// #0426: feature-near's lowest commit, the commit it forks from, and a
    /// commit of the deleted topic no branch claims.
    static let nearLowest = "near commit 1"
    static let nearFork = "map main 11"
    static let goneTopic = "gone topic one"
    /// #0427: a commit in the root lane's first fold of three, and one in
    /// its fold of 22.
    static let foldedMain = "map main 05"
    static let foldedBase = "map base 12"
    /// #0429: a recent branch stacked on a 40-day-old one, and a 40-day-old
    /// branch with no child.
    static let freshChild = "fresh-child"
    static let staleBase = "stale-base"
    static let staleOnly = "stale-only"
    /// #0430: a squash landing (merged by content) beside the ancestry-merged
    /// merged-old; the root lane carries origin/map-main.
    static let squashLanded = "squash-landed"
    static let rootLaneLabel = "Lane map-main, origin/map-main"
    /// The rightmost branch with commits of its own, and its tip.
    static let deepBranch = "feature-deep"
    static let deepTip = "deep tip commit"
    /// A stub lane whose tip is row 33 of map-main (#0426).
    static let oldBranch = "merged-old"
    static let oldTip = "map base 04"
}

extension XCUIApplication {
    /// Launches the app on the branch-map fixture with the real panes.
    @MainActor
    func launchWithMapFixture() {
        launchArguments = [
            "-uiTestRepository", UITestMapFixture.repositoryPath,
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
}

/// #0442: the Changes-view fixture scripts/uitest-fixtures/make-changes-fixture.sh
/// generates inside the guest — keep the two in sync.
enum UITestChangesFixture {
    static let repositoryPath = "/Users/admin/uitest-changes-repo"
    /// The fixture's one commit.
    static let baseSubject = "changes base commit"
    /// Two unstaged hunks (lines 2 and 18 edited).
    static let tracked = "tracked.txt"
    /// Modified and staged.
    static let staged = "staged.txt"
    /// Deleted, unstaged.
    static let gone = "gone.txt"
    /// Untracked.
    static let untracked = "new.txt"
}

extension XCUIApplication {
    /// Launches the app on the Changes-view fixture with the real panes.
    @MainActor
    func launchWithChangesFixture() {
        launchArguments = [
            "-uiTestRepository", UITestChangesFixture.repositoryPath,
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

    /// A Changes-view file name on one side — the `Text` the view tags
    /// `changes-staged-<path>` / `changes-unstaged-<path>` (#0443).
    @MainActor
    func changesRow(_ path: String, staged: Bool) -> XCUIElement {
        staticTexts.matching(
            identifier: "changes-\(staged ? "staged" : "unstaged")-\(path)").firstMatch
    }
}

/// #0496: the stash fixture scripts/uitest-fixtures/make-stash-fixture.sh
/// generates inside the guest — keep the two in sync.
enum UITestStashFixture {
    static let repositoryPath = "/Users/admin/uitest-stash-repo"
    /// `stash@{0}`: notes.txt edited, and the untracked todo.txt.
    static let newer = "newer stash"
    /// `stash@{1}`: notes.txt edited.
    static let older = "older stash"
    /// The tracked file both stashes change.
    static let notes = "notes.txt"
    /// The untracked file `newer` holds.
    static let todo = "todo.txt"
}

extension XCUIApplication {
    /// Launches the app on the stash fixture with the real panes.
    @MainActor
    func launchWithStashFixture() {
        launchArguments = [
            "-uiTestRepository", UITestStashFixture.repositoryPath,
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
}

/// #0512: the switch fixture scripts/uitest-fixtures/make-switch-fixture.sh
/// generates inside the guest — keep the two in sync.
enum UITestSwitchFixture {
    static let repositoryPath = "/Users/admin/uitest-switch/repo"
    /// Checked out, with notes.txt edited in the working tree.
    static let main = "switch-main"
    /// Changes notes.txt, so switching to it over the edit is refused.
    static let feature = "switch-feature"
    /// One commit on no other branch.
    static let unmerged = "unmerged-topic"
    static let remoteBranch = "origin/remote-topic"
    static let remoteLocal = "remote-topic"
    static let tag = "v-delete-me"
    static let baseSubject = "switch base commit"
    /// The stash row Stash Changes and Switch leaves (git's `On <branch>: `
    /// prefix is dropped by the row).
    static let stashMessage = "Before checking out switch-feature"
}

extension XCUIApplication {
    /// Launches the app on the switch fixture with the real panes.
    @MainActor
    func launchWithSwitchFixture() {
        launchArguments = [
            "-uiTestRepository", UITestSwitchFixture.repositoryPath,
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

    /// #0512: the repository header's first line (`TrackingSummary.text`),
    /// matched by prefix — "On branch x · …" or "Detached HEAD at …".
    @MainActor
    func header(beginningWith prefix: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@ OR label BEGINSWITH %@", prefix, prefix)).firstMatch
    }
}

/// #0520: the file history and blame fixture
/// scripts/uitest-fixtures/make-blame-fixture.sh generates inside the guest —
/// keep the two in sync.
enum UITestBlameFixture {
    static let repositoryPath = "/Users/admin/uitest-blame-repo"
    /// Renamed from `oldName` in `renameSubject`, edited in the working tree.
    static let file = "notes.txt"
    static let oldName = "notes-old.txt"
    static let firstSubject = "blame first commit"
    static let renameSubject = "blame rename commit"
    static let editSubject = "blame edit commit"
    /// Touches only other.txt, so it is not in notes.txt's history.
    static let otherSubject = "blame other commit"
}

extension XCUIApplication {
    /// Launches the app on the blame fixture with the real panes.
    @MainActor
    func launchWithBlameFixture() {
        launchArguments = [
            "-uiTestRepository", UITestBlameFixture.repositoryPath,
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

    /// The file inspector's path line (#0517), when an inspector is open.
    @MainActor
    func fileInspectorPath() -> XCUIElement {
        staticTexts.matching(identifier: "file-inspector-path").firstMatch
    }
}

/// #0455: the Fetch/Pull/Push fixture scripts/uitest-fixtures/make-remote-fixture.sh
/// generates inside the guest — keep the two in sync. Every clone is on
/// `remote-main` tracking `origin/remote-main` except `pushRepository`.
enum UITestRemoteFixture {
    static let directory = "/Users/admin/uitest-remote"
    /// Up to date until Fetch, then 1 behind.
    static let pullRepository = directory + "/pull-repo"
    /// 1 ahead; 1 behind once fetched. Pull cannot fast-forward.
    static let divergedRepository = directory + "/diverged-repo"
    /// On `push-feature`, no upstream, one commit to push.
    static let pushRepository = directory + "/push-repo"
    /// 1 ahead, with a pre-push hook that sleeps 300 s.
    static let slowPushRepository = directory + "/slow-push-repo"
    static let branch = "remote-main"
    static let upstream = "origin/remote-main"
    static let pushBranch = "push-feature"
    /// The commit another writer pushed after the clones were made.
    static let remoteSubject = "0457 remote commit"
}

extension XCUIApplication {
    /// Launches the app on one of the remote fixture's clones with the real panes.
    @MainActor
    func launchWithRemoteFixture(_ repositoryPath: String) {
        launchArguments = ["-uiTestRepository", repositoryPath, "-uiTestRealSurfaces"]
        launch()
        let tree = debugDescription
        XCTAssertTrue(
            windows.firstMatch.waitForExistence(timeout: 60),
            "The app launched but opened no window within 60 s — its element " +
            "tree starts with: \(String(tree.prefix(1200)))",
            file: #filePath, line: #line)
    }

    /// A toolbar network button (#0457): `toolbar-fetch`, `toolbar-pull`, `toolbar-push`.
    @MainActor
    func remoteButton(_ name: String) -> XCUIElement {
        buttons.matching(identifier: "toolbar-\(name)").firstMatch
    }

    /// Any static text whose label or value contains `text`: the header's
    /// tracking line ("On branch … · 1 behind origin/…").
    @MainActor
    func text(containing text: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }
}

/// #0578: the merge fixture scripts/uitest-fixtures/make-merge-fixture.sh
/// generates inside the guest — keep the two in sync.
enum UITestMergeFixture {
    static let root = "/Users/admin/uitest-merge"
    static let mergedBranch = "docs2"
    static let docsSubject = "docs2 adds docs.md"
    static let mergeSubject = "Merge branch 'docs2' into merge-main"
    static let file = "docs.md"

    static func path(_ shape: String) -> String { "\(root)/\(shape)" }
}

/// #0578: runs `/usr/bin/git -C <repo> <args>` from the UI test runner, so a
/// spike asserts what git holds rather than what the window says. Measured
/// in the guest, 2026-10-05: the runner is unsandboxed and the call exits 0.
enum UITestGit {
    struct Result {
        let status: Int32
        let output: String
        /// `output` with the trailing newline removed.
        var trimmed: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
        var lines: [String] { output.split(separator: "\n").map(String.init) }
    }

    static func run(_ arguments: [String], in repository: String) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "could not launch git: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

extension XCUIApplication {
    /// #0578: launches the app on one shape of the merge fixture.
    @MainActor
    func launchWithMergeFixture(_ shape: String) {
        launchArguments = ["-uiTestRepository", UITestMergeFixture.path(shape), "-uiTestRealSurfaces"]
        launch()
        let tree = debugDescription
        XCTAssertTrue(
            windows.firstMatch.waitForExistence(timeout: 60),
            "The app launched but opened no window within 60 s — its element " +
            "tree starts with: \(String(tree.prefix(1200)))",
            file: #filePath, line: #line)
    }
}
