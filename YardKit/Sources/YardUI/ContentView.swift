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

    /// #0065: the Sidebar pane's selected recorded resolution, keyed on
    /// conflict id. Selecting one clears the commit selection and the other
    /// way round — the Detail pane shows whichever was picked last — which
    /// the two selection bindings below do in their `set` closures.
    @State private var selectedResolution: String?

    /// The selected resolution's entry, resolved from `sidebar` at
    /// selection time and held as a value: after a forget the sidebar
    /// reloads, the entry leaves the recorded set, and this pane keeps
    /// showing what was selected until a new selection replaces it.
    @State private var selectedResolutionEntry: Rerere.Entry?

    /// `loadRerereResolution`'s result for `selectedResolution`, loaded by
    /// the `.task(id: selectedResolution)` below. `nil` while loading.
    @State private var selectedResolutionDiff: Rerere.Resolution?

    /// Set when `loadRerereResolution` throws.
    @State private var selectedResolutionDiffError: String?

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

    /// #0055's review centre, injected by the app target. While this view
    /// shows a repository, the pending review for THAT repository presents
    /// as this view's sheet — per-tab, never app-modal: a review on one
    /// repository does not block another's window. `nil` when nothing is
    /// injected (tests, previews) and no sheet is ever presented.
    public var reviews: ReviewCenter?

    /// #0056's ask centre, injected by the app target. The HEAD of a
    /// repository's pending-ask queue presents as this view's sheet — the
    /// first still-pending model for this repository, since registration
    /// order is queue order. Per-tab like reviews; asks on one repository
    /// never block another's window.
    public var asks: AskCenter?

    /// #0057's resolve centre, injected by the app target. The pending
    /// resolve for THIS repository presents as this view's sheet — one pane
    /// per repository, the review semantics. Per-tab like reviews; a resolve
    /// on one repository never blocks another's window. `nil` when nothing
    /// is injected (tests, previews) and no pane is ever presented.
    public var resolves: ResolveCenter?

    /// The transport pane's disclosure state. Local UI state, so `@State`
    /// is the right home; nothing else reads it.
    @State private var transportExpanded = false

    /// A `public struct`'s memberwise initialiser is **internal**. Without this,
    /// `ContentView()` is unreachable from the app target — the same defect
    /// #0116 found on `WorktreeStatusEntry`, and one `@testable import` hides it
    /// because `@testable` grants internal access.
    public init(
        transportStatus: TransportStatusModel? = nil,
        reviews: ReviewCenter? = nil,
        asks: AskCenter? = nil,
        resolves: ResolveCenter? = nil
    ) {
        self.transportStatus = transportStatus
        self.reviews = reviews
        self.asks = asks
        self.resolves = resolves
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
        .task(id: selectedResolution) {
            await reloadSelectedResolution()
        }
        // #0055: the pending review for the repository this view shows,
        // presented as a sheet. The centre removes a decided model — which
        // clears the binding and dismisses — and a timed-out or superseded
        // sheet stays until the human closes its banner.
        .sheet(item: Binding<ReviewSheetModel?>(
            get: {
                guard let reviews, let repositoryPath else { return nil }
                return reviews.activeSheet(forRepositoryPath: repositoryPath)
            },
            set: { newValue in
                guard newValue == nil,
                      let reviews, let repositoryPath,
                      let current = reviews.activeSheet(forRepositoryPath: repositoryPath)
                else { return }
                reviews.dismiss(current)
            }
        )) { sheetModel in
            ReviewSheet(model: sheetModel)
        }
        // #0056: the head of the pending-ask queue for the repository this
        // view shows, presented as a sheet. The centre removes a decided
        // model — which clears the binding and dismisses — and a timed-out
        // ask's banner stays until the human closes it.
        .sheet(item: Binding<AskSheetModel?>(
            get: {
                guard let asks, let repositoryPath else { return nil }
                return asks.activeSheet(forRepositoryPath: repositoryPath)
            },
            set: { newValue in
                guard newValue == nil,
                      let asks, let repositoryPath,
                      let current = asks.activeSheet(forRepositoryPath: repositoryPath)
                else { return }
                asks.dismiss(current)
            }
        )) { sheetModel in
            AskSheet(model: sheetModel)
        }
        // #0057: the pending resolve for the repository this view shows,
        // presented as a sheet. The centre removes a decided model — which
        // clears the binding and dismisses — and a timed-out or superseded
        // pane's banner stays until the human closes it.
        .sheet(item: Binding<ResolvePaneModel?>(
            get: {
                guard let resolves, let repositoryPath else { return nil }
                return resolves.activePane(forRepositoryPath: repositoryPath)
            },
            set: { newValue in
                guard newValue == nil,
                      let resolves, let repositoryPath,
                      let current = resolves.activePane(forRepositoryPath: repositoryPath)
                else { return }
                resolves.dismiss(current)
            }
        )) { paneModel in
            ResolvePane(model: paneModel)
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
                historyPane(summary: summary)
                    .frame(minWidth: PaneLayout.historyMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                detailPane(summary: summary)
                    .frame(minWidth: PaneLayout.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// #0081's real Sidebar content: branches, remotes, tags, worktrees,
    /// the stash count, and #0065's recorded rerere resolutions.
    /// `sidebar` loads alongside `summary` but off its own `@concurrent`
    /// call, so it can still be `nil` for a moment after `summary` first
    /// resolves -- a spinner covers that window rather than showing an
    /// empty list.
    private func sidebarPane(summary: RepositorySummary) -> some View {
        Group {
            if let sidebar {
                RepositorySidebarView(
                    summary: sidebar, stashCount: summary.whereAmI.stashCount,
                    selectedResolution: Binding(
                        get: { selectedResolution },
                        set: { newValue in
                            selectedResolution = newValue
                            // Picking a resolution last is what the Detail
                            // pane shows; a stale commit selection would
                            // only keep the pane's commit branch alive.
                            if newValue != nil { selectedCommit = nil }
                        }))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// #0340's commit list with #0052's lane gutter beside it. The
    /// selection binding mirrors `selectedResolution`'s: picking a commit
    /// clears the rerere selection, so the Detail pane always shows
    /// whichever selection was made last.
    private func historyPane(summary: RepositorySummary) -> some View {
        CommitHistoryView(
            entries: history, graphRows: graphRows,
            headOid: summary.whereAmI.rawHead.isEmpty ? nil : summary.whereAmI.rawHead,
            selection: Binding(
                get: { selectedCommit },
                set: { newValue in
                    selectedCommit = newValue
                    if newValue != nil { selectedResolution = nil }
                }))
    }

    /// #0082 shows the selected commit when `selectedCommit` names one
    /// found in `history`; #0065 adds the selected recorded resolution —
    /// checked first, because a rerere selection is held as a value and
    /// survives the sidebar reload a forget triggers. With nothing
    /// selected -- the #0339 behaviour -- it keeps showing today's
    /// working-tree status list unchanged.
    private func detailPane(summary: RepositorySummary) -> some View {
        Group {
            if let selectedResolutionEntry {
                RerereDetailView(
                    repositoryPath: repositoryPath ?? "",
                    entry: selectedResolutionEntry,
                    resolution: selectedResolutionDiff,
                    resolutionError: selectedResolutionDiffError,
                    onForgotten: {
                        Task { await reloadSidebarAfterForget() }
                    })
            } else if let selectedCommit, let entry = history.first(where: { $0.oid == selectedCommit }) {
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
        selectedResolution = nil
        selectedResolutionEntry = nil
        selectedResolutionDiff = nil
        selectedResolutionDiffError = nil
        selectedCommitDiff = nil
        selectedCommitDiffError = nil
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

    /// #0065: resolves the selected resolution's entry from the loaded
    /// sidebar and loads its recorded diff, keyed by `.task(id:)` the same
    /// way `reloadSelectedCommitDiff` is. The entry is held as a value (see
    /// `selectedResolutionEntry`) so a forget's sidebar reload — which
    /// removes the entry from the recorded set — does not blank the pane
    /// the user is looking at.
    private func reloadSelectedResolution() async {
        selectedResolutionDiffError = nil
        selectedResolutionDiff = nil
        guard let selectedResolution else {
            selectedResolutionEntry = nil
            return
        }
        selectedResolutionEntry = sidebar?.rerere.entries.first {
            $0.conflictID == selectedResolution
        }
        guard let repositoryPath else { return }
        do {
            selectedResolutionDiff = try await loadRerereResolution(
                at: repositoryPath, conflictID: selectedResolution)
        } catch {
            selectedResolutionDiffError = String(describing: error)
        }
    }

    /// #0065: after a successful forget, reload the sidebar so the
    /// forgotten entry leaves the Rerere section. The full reload is not
    /// needed — a forget touches the rr-cache only — and the detail pane
    /// keeps showing the forgotten resolution from its held entry.
    private func reloadSidebarAfterForget() async {
        guard let repositoryPath else { return }
        sidebar = try? await loadRepositorySidebar(at: repositoryPath)
    }
}

#Preview {
    ContentView()
}
