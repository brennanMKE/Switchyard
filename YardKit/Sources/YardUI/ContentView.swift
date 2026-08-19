// ContentView.swift — moved from Switchyard/ by #0126.
//
// #0339: shows a real repository, picked by the user. No hardcoded path and
// no attempt to guess a repository at launch — a chosen folder that is not a
// repository shows the error, not an empty list (#0140, guide §9 M1
// criterion 3).
//
// #0080: splits the **loaded** state only into three panes -- Sidebar /
// History / Detail. The empty, loading and error states below stay exactly
// as #0339 left them: full-window, no panes.
//
// `HSplitView`, not `NavigationSplitView`: three fixed peer panes with plain
// drag-to-resize dividers is exactly what `HSplitView` gives for free, while
// `NavigationSplitView` bakes in a sidebar/detail *navigation* relationship
// (programmatic collapse, `columnVisibility`) this issue does not need and
// that would fight the "just three columns" shape #0080's planning settled
// on.
//
// #0082: the Detail pane now shows the commit selected in the History pane
// -- `CommitDetailView`, fed by `loadCommitDiff` (`RepositoryLoader.swift`).
// With nothing selected it keeps showing the #0339 status list unchanged;
// the commit view is an addition, not a replacement.

import AppKit
import SwiftUI
import YardGit

public struct ContentView: View {

    /// The chosen repository's folder path, or `nil` before anything is
    /// picked. `.task(id:)` reloads whenever this changes.
    @State private var repositoryPath: String?

    /// The most recent successful load. `nil` while loading or after an
    /// error, so the three states below are mutually exclusive.
    @State private var summary: RepositorySummary?

    /// Set when `loadRepositorySummary` throws — shown instead of an empty
    /// list (#0140).
    @State private var errorMessage: String?

    /// #0340's commit history for the History pane, loaded alongside the
    /// summary. Empty until the first successful load; a repository with no
    /// commits legitimately stays empty.
    @State private var history: [CommitLogEntry] = []

    /// The History pane's selection, keyed on `oid`. #0082's Detail pane
    /// observes it to show the selected commit.
    @State private var selectedCommit: String?

    /// `loadCommitDiff`'s result for `selectedCommit`, loaded by the
    /// `.task(id: selectedCommit)` below. `nil` while loading or when
    /// nothing is selected; `[]` for a genuinely empty diff once loaded.
    @State private var selectedCommitDiff: [FileDiff]?

    /// Set when `loadCommitDiff` throws — shown in the Detail pane instead
    /// of a blank diff.
    @State private var selectedCommitDiffError: String?

    /// A `public struct`'s memberwise initialiser is **internal**. Without this,
    /// `ContentView()` is unreachable from the app target — the same defect
    /// #0116 found on `WorktreeStatusEntry`, and one `@testable import` hides it
    /// because `@testable` grants internal access.
    public init() {}

    public var body: some View {
        Group {
            if let repositoryPath {
                if let summary {
                    repositoryView(summary: summary)
                } else if let errorMessage {
                    statusMessageView(
                        systemImage: "exclamationmark.triangle",
                        title: "Couldn't open \(repositoryPath)",
                        detail: errorMessage
                    )
                } else {
                    ProgressView("Loading \(repositoryPath)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                statusMessageView(
                    systemImage: "folder.badge.questionmark",
                    title: "No repository open",
                    detail: nil
                )
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .toolbar {
            ToolbarItem {
                Button {
                    chooseFolder()
                } label: {
                    Label("Open…", systemImage: "folder")
                }
            }
        }
        .task(id: repositoryPath) {
            await reload()
        }
        .task(id: selectedCommit) {
            await reloadSelectedCommitDiff()
        }
    }

    private func repositoryView(summary: RepositorySummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RepositoryHeaderView(whereAmI: summary.whereAmI)
                .padding()
            Divider()
            HSplitView {
                sidebarPane
                    .frame(minWidth: PaneLayout.sidebarMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                historyPane
                    .frame(minWidth: PaneLayout.historyMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                detailPane(summary: summary)
                    .frame(minWidth: PaneLayout.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Placeholder for #0081 -- branches, remotes, and stashes.
    private var sidebarPane: some View {
        placeholderPane(
            systemImage: "sidebar.left",
            title: "Sidebar",
            detail: "Branches, remotes, and stashes land here in #0081."
        )
    }

    /// #0340's commit list. The round that built this shell left a
    /// placeholder here because #0340 was dispatched concurrently and owned
    /// `CommitHistoryView.swift`; it landed first, so the wiring is done
    /// here at review rather than deferred to a third issue. #0052 replaces
    /// the flat list with lane rendering.
    private var historyPane: some View {
        CommitHistoryView(entries: history, selection: $selectedCommit)
    }

    /// #0082: shows the selected commit when `selectedCommit` names one
    /// found in `history`. With nothing selected -- the #0339 behaviour --
    /// it keeps showing today's working-tree status list unchanged.
    private func detailPane(summary: RepositorySummary) -> some View {
        Group {
            if let selectedCommit, let entry = history.first(where: { $0.oid == selectedCommit }) {
                CommitDetailView(
                    entry: entry,
                    files: selectedCommitDiff,
                    diffError: selectedCommitDiffError
                )
            } else if summary.status.entries.isEmpty {
                Text("Working tree clean")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(summary.status.entries, id: \.path) { entry in
                    StatusRow(entry: entry)
                }
            }
        }
    }

    private func placeholderPane(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("\(title) — placeholder")
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private func statusMessageView(systemImage: String, title: String, detail: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Choose Folder…") {
                chooseFolder()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `NSOpenPanel` limited to directories. No repository validation
    /// happens here — `whereAmI` is the single source of truth for whether
    /// a folder is a repository, run once via `reload()`.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        repositoryPath = url.path
    }

    private func reload() async {
        guard let repositoryPath else { return }
        errorMessage = nil
        summary = nil
        history = []
        selectedCommit = nil
        do {
            summary = try await loadRepositorySummary(at: repositoryPath)
            // Separate from the summary load on purpose: a repository whose
            // log cannot be read (an unborn branch has no HEAD) must still
            // show its header and status rather than falling into the error
            // state wholesale.
            history = (try? await loadCommitHistory(at: repositoryPath)) ?? []
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Loads the diff for `selectedCommit`, keyed by `.task(id:)` so a new
    /// selection cancels an in-flight load for the previous one. Nothing to
    /// load with no repository open or no commit selected -- that is the
    /// #0339 status-list branch in `detailPane`, not an error.
    private func reloadSelectedCommitDiff() async {
        selectedCommitDiffError = nil
        selectedCommitDiff = nil
        guard let repositoryPath, let selectedCommit else { return }
        do {
            selectedCommitDiff = try await loadCommitDiff(at: repositoryPath, revision: selectedCommit)
        } catch {
            selectedCommitDiffError = String(describing: error)
        }
    }
}

#Preview {
    ContentView()
}
