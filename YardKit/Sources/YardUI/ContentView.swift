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

    /// #0052's lane-assigned commit graph, loaded alongside `history` from a
    /// separate engine call and joined to it by `oid` in
    /// `CommitHistoryView`. Empty until the first successful load, same as
    /// `history` above.
    @State private var graphRows: [GraphRow] = []

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

    /// #0081's Sidebar pane content: refs and worktrees, loaded alongside
    /// the summary. `nil` while loading -- `sidebarPane` shows a spinner
    /// rather than an empty list in that window.
    @State private var sidebar: RepositorySidebarSummary?

    /// #0216's transport pane model, injected by the app target from its own
    /// `AgentRegistrar`/`AppXPCServer` state. `nil` when nothing is injected
    /// (tests, previews) and the pane is not rendered at all.
    public var transportStatus: TransportStatusModel?

    /// The transport pane's disclosure state. Local UI state, so `@State`
    /// is the right home; nothing else reads it.
    @State private var transportExpanded = false

    /// A `public struct`'s memberwise initialiser is **internal**. Without this,
    /// `ContentView()` is unreachable from the app target — the same defect
    /// #0116 found on `WorktreeStatusEntry`, and one `@testable import` hides it
    /// because `@testable` grants internal access.
    public init(transportStatus: TransportStatusModel? = nil) {
        self.transportStatus = transportStatus
    }

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
        // #0216: the transport pane, pinned below whatever the window shows —
        // it is app-global, not per-repository, and the "the CLI can't
        // connect" diagnosis usually happens with no repository open. Only
        // rendered when the app target injected a model; tests and previews
        // pass nothing and see nothing.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let transportStatus {
                DisclosureGroup("Transport", isExpanded: $transportExpanded) {
                    TransportStatusPane(model: transportStatus)
                        .padding()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    chooseFolder()
                } label: {
                    Label("Open…", systemImage: "folder")
                }
            }
        }
        // #0084: dropping a folder on the window is one of the four
        // repository-open entry points, so it goes through the same
        // focus-or-open rule as File ▸ Open, the URL scheme, and XPC. The
        // Dock-icon half of drag-and-drop arrives at the app delegate's
        // `application(_:open:)` instead.
        .dropDestination(for: URL.self) { urls, _ in
            RepositoryOpener.openDropped(urls: urls) != nil
        } isTargeted: { _ in }
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
                sidebarPane(summary: summary)
                    .frame(minWidth: PaneLayout.sidebarMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                historyPane
                    .frame(minWidth: PaneLayout.historyMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                detailPane(summary: summary)
                    .frame(minWidth: PaneLayout.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// #0081's real Sidebar content: branches, remotes, tags, worktrees, and
    /// a stash count. `sidebar` loads alongside `summary` but off its own
    /// `@concurrent` call, so it can still be `nil` for a moment after
    /// `summary` first resolves -- a spinner covers that window rather than
    /// showing an empty list.
    private func sidebarPane(summary: RepositorySummary) -> some View {
        Group {
            if let sidebar {
                RepositorySidebarView(summary: sidebar, stashCount: summary.whereAmI.stashCount)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// #0340's commit list with #0052's lane gutter beside it.
    private var historyPane: some View {
        CommitHistoryView(entries: history, graphRows: graphRows, selection: $selectedCommit)
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

    /// `NSOpenPanel` limited to directories, routed through
    /// `RepositoryOpener.chooseAndOpen` (#0084) so the toolbar button and
    /// the empty-state button obey the same focus-or-open rule as every
    /// other entry point: an already-open repository is focused, not
    /// duplicated, and a non-repository shows the shared refusal message.
    /// No repository validation happens here — the resolver inside
    /// `open(path:)` is the single gate.
    private func chooseFolder() {
        guard let outcome = RepositoryOpener.chooseAndOpen(store: .shared) else { return }
        switch outcome {
        case .opened(let tab), .focusedExisting(let tab, _):
            // The pane follows the repository the open landed on.
            repositoryPath = tab.context.topLevel ?? tab.context.commonDir
        case .refused:
            break // RepositoryOpener already presented the refusal
        }
    }

    private func reload() async {
        guard let repositoryPath else { return }
        errorMessage = nil
        summary = nil
        history = []
        graphRows = []
        sidebar = nil
        selectedCommit = nil
        do {
            summary = try await loadRepositorySummary(at: repositoryPath)
            // Separate from the summary load on purpose: a repository whose
            // log cannot be read (an unborn branch has no HEAD) must still
            // show its header and status rather than falling into the error
            // state wholesale. Same reasoning for the graph and sidebar
            // loads below -- three independent engine calls, so one failing
            // does not blank the others.
            history = (try? await loadCommitHistory(at: repositoryPath)) ?? []
            graphRows = (try? await loadCommitGraph(at: repositoryPath)) ?? []
            sidebar = try? await loadRepositorySidebar(at: repositoryPath)
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
