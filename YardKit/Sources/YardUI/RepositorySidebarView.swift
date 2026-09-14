// RepositorySidebarView.swift
//
// #0081: the Sidebar pane's real content -- local branches, remote-tracking
// branches, tags, worktrees, and a stash count. Replaces the #0339
// placeholder in `ContentView.swift`.
//
// Re-scoped 2026-08-18 for the MVP (see issue 0081's "Re-scoped" section):
// selection does not switch tab context (no tabs yet, #0079), there is no
// live reload on external ref changes (#0217), and per-worktree ahead/behind
// and attached agent sessions are not shown.
//
// #0371: the ref sections collapse again -- the MVP dropped collapsing and
// used plain `Section`s throughout. Branches, Remotes and Tags now use
// `Section(_:isExpanded:)` (Branches expanded, Remotes and Tags collapsed by
// default); Worktrees, Rerere and Stashes stay plain. Whether the disclosure
// renders correctly on macOS 26 is spike #0386's question, whose failure
// branch is `DisclosureGroup`. Expansion state is per window and
// deliberately not persisted.
//
// #0372: local branch rows carry a trailing status -- the branch's
// ahead/behind and its merged state, as guide §11 decision 27 defines them
// (A3: against the upstream when set, else the default branch, the baseline
// named; M6: merged by ancestry, else upstream-gone, else content, with
// *unknown* for conflicts). The status read is one `for-each-ref` process
// run when the opened worktree path changes (`BranchStatus.read`, the
// decision's synchronous-load budget); the content pass is a background
// `.task` (`BranchStatus.contentPass`) that fills the merged answers after
// the rows appear -- content-dependent rows read *unknown* until it lands.

import SwiftUI
import YardGit

/// Branches, remotes, tags, worktrees, and a stash count for one repository.
///
/// A `List` whose three ref sections -- Branches, Remotes, Tags -- collapse
/// via `Section(_:isExpanded:)` (#0371); every other section stays a plain
/// `Section`. `List` already gives scrolling and row selection for free.
/// Expansion state is per window and not persisted across launches,
/// deliberately (#0371).
public struct RepositorySidebarView: View {
    private let summary: RepositorySidebarSummary
    private let stashCount: Int

    /// #0065: the selected recorded resolution's conflict id, routed to the
    /// Detail pane. `nil` when nothing is selected; the Detail pane's
    /// rerere branch observes it the way it observes the History pane's
    /// commit selection.
    @Binding private var selectedResolution: String?

    /// #0371: the ref sections' initial expansion state. Branches opens so
    /// the current branch is visible without a click; Remotes and Tags start
    /// collapsed -- Switchyard measures 309 local and 294 remote-tracking
    /// refs, so a fully open sidebar is effectively unreachable. Per window;
    /// deliberately not persisted across launches. `nonisolated` on purpose:
    /// inert constants, asserted by tests running off the main actor.
    public nonisolated static let branchesStartExpanded = true
    public nonisolated static let remotesStartExpanded = false
    public nonisolated static let tagsStartExpanded = false

    /// The three ref sections' live expansion state, seeded from the
    /// `*StartExpanded` constants above.
    @State private var branchesExpanded = RepositorySidebarView.branchesStartExpanded
    @State private var remotesExpanded = RepositorySidebarView.remotesStartExpanded
    @State private var tagsExpanded = RepositorySidebarView.tagsStartExpanded

    /// #0372: the per-branch ahead/behind + upstream state behind the local
    /// branch rows' trailing status -- the one-process `for-each-ref` read
    /// (`BranchStatus.read`, decision 27's sidebar-load budget). `nil` until
    /// it lands, and whenever the read fails: rows then carry no numbers.
    /// Reloaded whenever the opened worktree path changes.
    @State private var branchStatus: BranchStatus.Report?

    /// #0372: the background `merge-tree --write-tree` content pass's
    /// answers, keyed by full ref name (`BranchStatus.contentPass`). `nil`
    /// until the pass lands after the sidebar appears -- content-dependent
    /// merged answers read *unknown* until then, never blocking the rows.
    @State private var contentStates: [String: BranchStatus.MergedState]?

    public init(
        summary: RepositorySidebarSummary, stashCount: Int,
        selectedResolution: Binding<String?>
    ) {
        self.summary = summary
        self.stashCount = stashCount
        self._selectedResolution = selectedResolution
    }

    // `nonisolated`: inert String constants, read by the `nonisolated`
    // `sortedBranches` below -- under YardUI's default isolation an
    // unannotated static is MainActor-isolated, and a nonisolated reader of
    // a MainActor static traps at runtime (see RepositoryOpener.swift's
    // `nonisolated` statics for the same reasoning).
    private nonisolated static let headsPrefix = "refs/heads/"
    private nonisolated static let remotesPrefix = "refs/remotes/"
    private nonisolated static let tagsPrefix = "refs/tags/"

    /// `HEAD`'s current branch name, from `RefSnapshot.head`. `nil` on a
    /// detached `HEAD` -- `isDetached` below covers that case explicitly
    /// rather than this falling through to "no branch marked".
    private var currentBranchName: String? {
        guard case let .symbolic(target) = summary.refs.head,
              target.hasPrefix(Self.headsPrefix) else { return nil }
        return String(target.dropFirst(Self.headsPrefix.count))
    }

    private var isDetached: Bool {
        if case .detached = summary.refs.head { return true }
        return false
    }

    private var branches: [RefSnapshot.Entry] {
        Self.sortedBranches(
            summary.refs.refs.filter { $0.name.hasPrefix(Self.headsPrefix) },
            currentBranchName: currentBranchName
        )
    }

    /// #0371: branch order -- the current branch first, the rest by full ref
    /// name. `currentBranchName` is the short name from `RefSnapshot.head`;
    /// `nil` (a detached `HEAD`) or a name with no matching ref yields a
    /// plain name sort. The tuple comparison ranks the current branch's
    /// `(0, name)` ahead of every other branch's `(1, name)`.
    /// `nonisolated` on purpose: a pure function on inert value data, so
    /// tests and callers off the main actor can use it without an isolation
    /// trap (same reasoning as `RepositoryOpener`'s statics).
    public nonisolated static func sortedBranches(
        _ entries: [RefSnapshot.Entry], currentBranchName: String?
    ) -> [RefSnapshot.Entry] {
        let currentRef = currentBranchName.map { headsPrefix + $0 }
        return entries.sorted {
            ($0.name == currentRef ? 0 : 1, $0.name) < ($1.name == currentRef ? 0 : 1, $1.name)
        }
    }

    /// #0371: every ref row's help text is the entry's full ref name, so a
    /// row the sidebar truncates can be read in full on hover. The label
    /// shows the short name; the help shows `entry.name`. `nonisolated` on
    /// purpose, like `sortedBranches` above.
    public nonisolated static func helpText(for entry: RefSnapshot.Entry) -> String {
        entry.name
    }

    /// #0372: a local branch row's trailing status -- the A3 ahead/behind
    /// with the baseline named, then the M6 merged state, joined with a
    /// middle dot -- or `nil` when the status read has not landed or has no
    /// row for this ref. Merged answers the composite can reach without the
    /// content pass (ancestry, upstream-gone) show as soon as the read
    /// lands; content-dependent branches read *unknown* until the
    /// background pass fills `content`. `nonisolated` on purpose, like
    /// `helpText` above: pure text over inert value data, so tests and
    /// callers off the main actor can use it.
    public nonisolated static func branchStatusText(
        for entry: RefSnapshot.Entry,
        report: BranchStatus.Report?,
        content: [String: BranchStatus.MergedState]?
    ) -> String? {
        guard let report, let row = report.row(forBranchNamed: entry.name) else { return nil }
        var parts: [String] = []
        if let aheadBehind = aheadBehindText(for: row) { parts.append(aheadBehind) }
        parts.append(mergedText(BranchStatus.mergedState(for: row, content: content ?? [:])))
        return parts.joined(separator: " · ")
    }

    /// #0372: the A3 numbers with the baseline named -- decision 27 requires
    /// the row to say which branch the numbers are against, because ahead of
    /// the upstream returns to 0 on push while ahead of the default never
    /// returns to 0 after a squash landing. `nil` when the row has no
    /// resolvable numbers (no upstream set and no measurable default branch).
    public nonisolated static func aheadBehindText(for row: BranchStatus.Row) -> String? {
        guard let ahead = row.ahead, let behind = row.behind else { return nil }
        let baseline = row.baseline.displayName
        let counts: String
        switch (ahead, behind) {
        case (0, 0):
            counts = "in sync"
        case (0, let b):
            counts = "↓\(b)"
        case (let a, 0):
            counts = "↑\(a)"
        case (let a, let b):
            counts = "↑\(a)↓\(b)"
        }
        return "\(counts) vs \(baseline)"
    }

    /// #0372: the M6 merged-state word. `unknown` is honest, not a failure:
    /// a conflict answer and an unlanded content pass are both shown as
    /// unknown rather than guessed at (decision 27).
    public nonisolated static func mergedText(_ state: BranchStatus.MergedState) -> String {
        switch state {
        case .merged:
            return "merged"
        case .notMerged:
            return "not merged"
        case .unknown:
            return "unknown"
        }
    }

    private var remotes: [RefSnapshot.Entry] {
        summary.refs.refs
            .filter { $0.name.hasPrefix(Self.remotesPrefix) }
            .sorted { $0.name < $1.name }
    }

    private var tags: [RefSnapshot.Entry] {
        summary.refs.refs
            .filter { $0.name.hasPrefix(Self.tagsPrefix) }
            .sorted { $0.name < $1.name }
    }

    /// The rerere resolutions the Detail pane can show and forget: the
    /// entries with a recorded postimage, in `Rerere.status`'s id order.
    /// Merely-known entries (a live conflict git is tracking, preimage
    /// only) are not recorded resolutions and stay out of the section —
    /// the conflicts surface owns live-conflict reporting (#0065 round 1).
    private var recordedResolutions: [Rerere.Entry] {
        summary.rerere.entries.filter { $0.state == .recorded }
    }

    public var body: some View {
        List {
            if isDetached {
                Section("HEAD") {
                    Label("Detached HEAD", systemImage: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                }
            }
            if !branches.isEmpty {
                Section("Branches", isExpanded: $branchesExpanded) {
                    ForEach(branches, id: \.name) { entry in
                        branchRow(entry)
                    }
                }
            }
            if !remotes.isEmpty {
                Section("Remotes", isExpanded: $remotesExpanded) {
                    ForEach(remotes, id: \.name) { entry in
                        refRow(entry, prefix: Self.remotesPrefix, systemImage: "network")
                    }
                }
            }
            if !tags.isEmpty {
                Section("Tags", isExpanded: $tagsExpanded) {
                    ForEach(tags, id: \.name) { entry in
                        refRow(entry, prefix: Self.tagsPrefix, systemImage: "tag")
                    }
                }
            }
            if !summary.worktrees.isEmpty {
                Section("Worktrees") {
                    ForEach(Array(summary.worktrees.enumerated()), id: \.offset) { _, entry in
                        worktreeRow(entry)
                    }
                }
            }
            if !recordedResolutions.isEmpty {
                Section("Rerere") {
                    ForEach(recordedResolutions, id: \.conflictID) { entry in
                        rerereRow(entry)
                    }
                }
            }
            Section("Stashes") {
                Text(stashCount == 1 ? "1 stash" : "\(stashCount) stashes")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .task(id: summary.currentWorktreePath) {
            // #0372: the synchronous-load read is one `for-each-ref` process
            // (decision 27's budget); the content pass is the background
            // fill that lands after the rows appear. Both reset on a path
            // change -- a repository switch must not show the previous
            // repository's numbers for a moment.
            guard let path = summary.currentWorktreePath else { return }
            branchStatus = nil
            contentStates = nil
            guard let report = try? await BranchStatus.read(at: path) else { return }
            branchStatus = report
            contentStates = try? await BranchStatus.contentPass(for: report, at: path)
        }
    }

    /// A branch row: the branch glyph (a filled checkmark for the current
    /// branch), the short name, and -- #0372 -- the trailing status text
    /// (`branchStatusText`): ahead/behind with the baseline named, then the
    /// merged state. The full ref name stays the help text (#0371).
    private func branchRow(_ entry: RefSnapshot.Entry) -> some View {
        let name = String(entry.name.dropFirst(Self.headsPrefix.count))
        let isCurrent = !isDetached && name == currentBranchName
        let status = Self.branchStatusText(
            for: entry, report: branchStatus, content: contentStates)
        return HStack(spacing: 8) {
            Label(name, systemImage: isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .fontWeight(isCurrent ? .semibold : .regular)
            if let status {
                Spacer(minLength: 8)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(Self.helpText(for: entry))
    }

    /// A remote or tag row: the ref name minus its prefix as the label, the
    /// full ref name as help text (#0371).
    private func refRow(_ entry: RefSnapshot.Entry, prefix: String, systemImage: String) -> some View {
        Label(String(entry.name.dropFirst(prefix.count)), systemImage: systemImage)
            .help(Self.helpText(for: entry))
    }

    /// A worktree row. The current worktree -- the one `ContentView` opened
    /// -- is marked by comparing `entry.path` against
    /// `summary.currentWorktreePath`, both canonicalized by git itself
    /// (`RepositoryLoader.swift`'s `loadRepositorySidebar` doc comment).
    /// `isMainWorktree` marks the *main* worktree, which is the wrong
    /// question here: opening a linked worktree's folder must mark that
    /// worktree, not always the main one.
    private func worktreeRow(_ entry: WorktreeEntry) -> some View {
        let isCurrent = entry.path != nil && entry.path == summary.currentWorktreePath
        let displayName = entry.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "(bare)"
        return VStack(alignment: .leading, spacing: 2) {
            Label(displayName, systemImage: isCurrent ? "checkmark.circle.fill" : "folder")
                .fontWeight(isCurrent ? .semibold : .regular)
            if let branch = entry.branch {
                Text(branch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if entry.detached {
                Text("detached")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A recorded rerere resolution row (#0065): the attributed path when
    /// one is live, else "Recorded resolution", with the short conflict id
    /// beneath — the worktree row's two-line shape. Tapping routes the
    /// conflict id to `selectedResolution` through a plain
    /// `.buttonStyle(.plain)` button (the review sheet's comment-remove
    /// affordance) rather than a `List(selection:)` binding: the sidebar's
    /// other sections are plain rows, and a list-wide selection binding
    /// would make every `ForEach` row selectable. The selected row marks
    /// itself semibold — the same marking `branchRow` uses for the current
    /// branch.
    private func rerereRow(_ entry: Rerere.Entry) -> some View {
        let isSelected = selectedResolution == entry.conflictID
        let displayName = entry.paths.isEmpty
            ? "Recorded resolution"
            : entry.paths.joined(separator: ", ")
        return Button {
            selectedResolution = entry.conflictID
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label(displayName, systemImage: "arrow.triangle.merge")
                    .fontWeight(isSelected ? .semibold : .regular)
                Text(String(entry.conflictID.prefix(12)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    @Previewable @State var selectedResolution: String?
    RepositorySidebarView(
        summary: RepositorySidebarSummary(
            refs: RefSnapshot(
                head: .symbolic(target: "refs/heads/main"),
                refs: [
                    RefSnapshot.Entry(name: "refs/heads/main", oid: "a1b2c3d"),
                    RefSnapshot.Entry(name: "refs/heads/feature", oid: "b2c3d4e"),
                    RefSnapshot.Entry(name: "refs/remotes/origin/main", oid: "a1b2c3d"),
                    RefSnapshot.Entry(name: "refs/tags/v1.0", oid: "c3d4e5f"),
                ]
            ),
            worktrees: [
                WorktreeEntry(path: "/tmp/repo", head: "a1b2c3d", branch: "main", isMainWorktree: true),
                WorktreeEntry(path: "/tmp/repo-wt", head: "b2c3d4e", branch: "feature"),
            ],
            currentWorktreePath: "/tmp/repo",
            rerere: Rerere.Status(
                enabled: true,
                entries: [
                    Rerere.Entry(
                        conflictID: "650b3bb115602e8f349398d8d6c560baaef932e3",
                        state: .recorded,
                        paths: ["f.txt"],
                        replayedPaths: [])
                ]
            )
        ),
        stashCount: 2,
        selectedResolution: $selectedResolution
    )
}
