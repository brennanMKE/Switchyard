// RepositorySidebarView.swift
//
// #0081: the Sidebar pane's real content -- local branches, remote-tracking
// branches, tags, worktrees, and a stash count. Replaces the #0339
// placeholder in `ContentView.swift`.
//
// Re-scoped 2026-08-18 for the MVP (see issue 0081's "Re-scoped" section):
// selection does not switch tab context (no tabs yet, #0079), there is no
// live reload on external ref changes (#0217), per-worktree ahead/behind and
// attached agent sessions are not shown, and sections are plain `Section`s
// rather than `DisclosureGroup` -- collapsing is dropped rather than costing
// a round.

import SwiftUI
import YardGit

/// Branches, remotes, tags, worktrees, and a stash count for one repository.
///
/// A `List` of plain `Section`s, not `DisclosureGroup`: `List` already gives
/// scrolling and row selection for free, and per-issue scoping, a
/// collapse/expand model was dropped rather than costing a round.
public struct RepositorySidebarView: View {
    private let summary: RepositorySidebarSummary
    private let stashCount: Int

    /// #0065: the selected recorded resolution's conflict id, routed to the
    /// Detail pane. `nil` when nothing is selected; the Detail pane's
    /// rerere branch observes it the way it observes the History pane's
    /// commit selection.
    @Binding private var selectedResolution: String?

    public init(
        summary: RepositorySidebarSummary, stashCount: Int,
        selectedResolution: Binding<String?>
    ) {
        self.summary = summary
        self.stashCount = stashCount
        self._selectedResolution = selectedResolution
    }

    private static let headsPrefix = "refs/heads/"
    private static let remotesPrefix = "refs/remotes/"
    private static let tagsPrefix = "refs/tags/"

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
        summary.refs.refs
            .filter { $0.name.hasPrefix(Self.headsPrefix) }
            .sorted { $0.name < $1.name }
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
                Section("Branches") {
                    ForEach(branches, id: \.name) { entry in
                        branchRow(entry)
                    }
                }
            }
            if !remotes.isEmpty {
                Section("Remotes") {
                    ForEach(remotes, id: \.name) { entry in
                        refRow(name: String(entry.name.dropFirst(Self.remotesPrefix.count)),
                               systemImage: "network")
                    }
                }
            }
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.name) { entry in
                        refRow(name: String(entry.name.dropFirst(Self.tagsPrefix.count)),
                               systemImage: "tag")
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
    /// uses.
    private func branchRow(_ entry: RefSnapshot.Entry) -> some View {
        let name = String(entry.name.dropFirst(Self.headsPrefix.count))
        let isCurrent = !isDetached && name == currentBranchName
        return Label(name, systemImage: isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
            .fontWeight(isCurrent ? .semibold : .regular)
    }

    private func refRow(name: String, systemImage: String) -> some View {
        Label(name, systemImage: systemImage)
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
