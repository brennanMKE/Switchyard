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

    public init(summary: RepositorySidebarSummary, stashCount: Int) {
        self.summary = summary
        self.stashCount = stashCount
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
}

#Preview {
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
            currentWorktreePath: "/tmp/repo"
        ),
        stashCount: 2
    )
}
