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
    }

    /// A branch row, with the current branch (`currentBranchName`) marked by
    /// a filled checkmark instead of the plain branch glyph every other row
    /// uses, and the full ref name as help text (#0371).
    private func branchRow(_ entry: RefSnapshot.Entry) -> some View {
        let name = String(entry.name.dropFirst(Self.headsPrefix.count))
        let isCurrent = !isDetached && name == currentBranchName
        return Label(name, systemImage: isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
            .fontWeight(isCurrent ? .semibold : .regular)
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
