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

    /// #0401: the sidebar ref last clicked (full ref name), highlighted
    /// there until a commit is picked in the History list.
    @State private var selectedRef: String?
    /// #0401: asks the History list to scroll a commit into view.
    @State private var historyScrollRequest: HistoryScrollRequest?

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

    /// #0375: the commit the Split sheet is open for — `nil` when it is
    /// not. The subject and message are resolved from `history` at menu
    /// time and carried by the request, so a refresh while the sheet is
    /// open cannot change them.
    @State private var splitRequest: SplitCommitRequest?

    /// #0359: the action running right now, `nil` when none. Feeds the
    /// menu's `isBusy` — every item disables with "Another operation is
    /// still running" — and the header's progress line. `defer` clears it
    /// on every exit; there is no Cancel button, because the engine calls
    /// are synchronous and cannot be cancelled, and signing may raise a
    /// prompt the user must be able to reach.
    @State private var runningAction: CommitAction?

    /// #0394: one of the header's conflict actions (Resolve Conflicts…,
    /// Continue, Abort) is running. Folded into `isBusy` so the row menu's
    /// items disable with it — a second engine write is dropped rather than
    /// queued, the same guard `runningAction` gives the commit actions.
    @State private var conflictActionRunning = false

    /// #0359: set when a commit action's engine call throws — shown as the
    /// failure alert. #0375's split failure alert folded into this.
    @State private var actionFailure: CommitActionFailure?

    /// #0359: the pending prompt from the commit action menu — the sheet
    /// for Edit Message, Squash with Parent, Add Tag, Create Branch and
    /// Edit Local Branch. Delete Commit… presents through `pendingDelete`
    /// below; Split… presents through `splitRequest` above (#0375).
    @State private var actionPrompt: CommitActionPrompt?

    /// #0359: the acted-on commit's chain index, captured when a prompt
    /// opens so the post-run selection lands on it at its new position.
    @State private var actionPromptIndex: Int?

    /// #0359: the pending Delete Commit… confirmation.
    @State private var pendingDelete: PendingDelete?

    /// #0081's Sidebar pane content: refs and worktrees, loaded alongside
    /// the summary. `nil` while loading -- `sidebarPane` shows a spinner
    /// rather than an empty list in that window.
    @State private var sidebar: RepositorySidebarSummary?

    /// #0393: the journal listing for the open repository — the chain state
    /// the Edit menu's Undo and Redo titles and enabled flags read. `nil`
    /// while loading or with no repository open, which leaves both items
    /// disabled with their plain titles.
    @State private var journalListing: JournalList.Listing?

    /// #0393: true while a journal traversal (undo or redo) runs. Both menu
    /// items disable with it, the same guard `runningAction` gives the
    /// commit actions.
    @State private var journalRunning = false

    /// #0393: set when a journal traversal throws — presented as the
    /// failure alert, with the engine's message.
    @State private var journalFailure: CommitActionFailure?

    /// #0393: the not-clean traversal report's note — a branch a sibling
    /// worktree has checked out was left as it is — presented as an
    /// informational alert. Nil for the ordinary, clean case.
    @State private var journalNotice: String?

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

    /// #0394: registers the app-side pending resolve behind the header's
    /// Resolve Conflicts… button, injected by the app target. The await
    /// returns when the human decides (the pane's resolution path), the
    /// request times out, or the request is superseded; the pane itself
    /// opens through the `resolves.activePane` sheet binding above when
    /// `pendingDidRegister` fires. `nil` when nothing is injected (tests,
    /// previews) — `beginResolve` below then only refreshes.
    public var onBeginInAppResolve: ((String) async -> Void)?

    /// The transport pane's disclosure state. Local UI state, so `@State`
    /// is the right home; nothing else reads it.
    @State private var transportExpanded = false

    /// A `public struct`'s memberwise initialiser is **internal**. Without this,
    /// `ContentView()` is unreachable from the app target — the same defect
    /// #0116 found on `WorktreeStatusEntry`, and one `@testable import` hides it
    /// because `@testable` grants internal access.
    ///
    /// #0395 round 2: `initialRepositoryPath` seeds `repositoryPath` at
    /// construction — the seam the `-uiTestRealSurfaces` launch hook uses so a
    /// UI-test launch renders the REAL panes against a fixture repository
    /// without an `NSOpenPanel`. `nil` (every existing caller) initialises
    /// `repositoryPath` exactly as before, so no existing call site changes
    /// behaviour.
    public init(
        transportStatus: TransportStatusModel? = nil,
        reviews: ReviewCenter? = nil,
        asks: AskCenter? = nil,
        resolves: ResolveCenter? = nil,
        onBeginInAppResolve: ((String) async -> Void)? = nil,
        initialRepositoryPath: String? = nil
    ) {
        self.transportStatus = transportStatus
        self.reviews = reviews
        self.asks = asks
        self.resolves = resolves
        self.onBeginInAppResolve = onBeginInAppResolve
        if let initialRepositoryPath {
            _repositoryPath = State(initialValue: initialRepositoryPath)
        }
    }

    /// #0370: the window title — the open repository's folder name, so two
    /// open windows are told apart in the Window menu, Mission Control and
    /// ⌘\` cycling — or "Switchyard" when nothing is open. A pure static so
    /// the string SwiftUI will install as the title can be unit-tested
    /// without instantiating scene machinery.
    public static func windowTitle(repositoryPath: String?) -> String {
        repositoryPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Switchyard"
    }

    /// #0370: the window subtitle — the current branch, "detached HEAD"
    /// when HEAD points at no branch, empty while nothing is loaded. Pure
    /// for the same reason as `windowTitle(repositoryPath:)`.
    public static func windowSubtitle(summary: RepositorySummary?) -> String {
        summary.map { $0.whereAmI.branch ?? "detached HEAD" } ?? ""
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
        // #0370: the window title names the open repository — the folder
        // name, so two open windows are told apart in Mission Control, the
        // Window menu and ⌘` cycling — with the current branch as the
        // subtitle, "detached HEAD" when HEAD points at no branch. With
        // nothing open the title falls back to "Switchyard". The strings are
        // derived by the public pure helpers below so they can be tested at
        // the access level the app target sees.
        .navigationTitle(Self.windowTitle(repositoryPath: repositoryPath))
        .navigationSubtitle(Self.windowSubtitle(summary: summary))
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
        .modifier(CommitActionOverlays(
            splitRequest: $splitRequest,
            actionPrompt: $actionPrompt,
            actionPromptIndex: $actionPromptIndex,
            pendingDelete: $pendingDelete,
            actionFailure: $actionFailure,
            commitMenuTarget: commitMenuTarget,
            repositoryPath: repositoryPath,
            branchName: summary?.whereAmI.branch,
            existingBranches: (sidebar?.refs.refs ?? []).compactMap { entry in
                entry.name.hasPrefix("refs/heads/")
                    ? String(entry.name.dropFirst("refs/heads/".count)) : nil
            },
            existingTags: (sidebar?.refs.refs ?? []).compactMap { entry in
                entry.name.hasPrefix("refs/tags/")
                    ? String(entry.name.dropFirst("refs/tags/".count)) : nil
            },
            onPromptRequest: { request in
                actionPrompt = nil
                let index = actionPromptIndex ?? 0
                actionPromptIndex = nil
                run(request, CommitAction.action(of: request), fromIndex: index)
            },
            onPromptCancel: {
                actionPrompt = nil
                actionPromptIndex = nil
            },
            onDeleteConfirmed: { delete in
                pendingDelete = nil
                let index = chainIndex(of: delete.commit) ?? 0
                run(.delete(commit: delete.commit), .delete, fromIndex: index)
            },
            onSplit: { arguments in
                splitRequest = nil
                Task { await runSplit(arguments) }
            }))
        // #0393: the menu bar's Edit menu acts on the focused window's
        // journal — titles, enabled flags and the traversal to run — the
        // same focused-scene pattern the Commit menu's target uses.
        .focusedSceneValue(\.journalMenuTarget, journalMenuTarget)
        // #0393: a not-clean traversal report. Informational — the undo or
        // redo itself succeeded; a branch a sibling worktree has checked
        // out was left as it is (guide §11 decisions 16 and 23).
        .alert(
            journalNotice ?? "",
            isPresented: Binding(
                get: { journalNotice != nil },
                set: { if !$0 { journalNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        }
        // #0393: a failed traversal — a lock timeout, a cross-tool refusal —
        // names the engine's message.
        .alert(
            journalFailure?.title ?? "",
            isPresented: Binding(
                get: { journalFailure != nil },
                set: { if !$0 { journalFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(journalFailure?.message ?? "")
        }
    }

    private func repositoryView(summary: RepositorySummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // #0394: the header's conflict hand-off. The view gates the
            // buttons on `WhereAmI` fields itself; the closures below re-
            // derive the kind at click time from the summary that rendered
            // them, so a refresh between render and click cannot act on a
            // state that has already moved.
            RepositoryHeaderView(
                whereAmI: summary.whereAmI,
                onResolveConflicts: { beginResolve() },
                onContinue: {
                    guard let kind = ConflictHandoff.continuableKind(for: summary.whereAmI)
                    else { return }
                    runContinue(kind: kind)
                },
                onAbort: { runAbort() })
                .padding()
            Divider()
            // #0359: the running action's progress line. No modal and no
            // Cancel button — signing can take seconds and may raise a
            // pinentry or agent prompt the user must be able to reach.
            if let runningAction {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(runningAction.progressLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                Divider()
            }
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
                        }),
                    selectedRef: selectedRef,
                    onSelectRef: { entry in
                        selectedRef = entry.name
                        selectedResolution = nil
                        selectedCommit = entry.oid
                        historyScrollRequest = HistoryScrollRequest(oid: entry.oid)
                    })
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// #0340's commit list with #0052's lane gutter beside it. The
    /// selection binding mirrors `selectedResolution`'s: picking a commit
    /// clears the rerere selection, so the Detail pane always shows
    /// whichever selection was made last. #0359: the row context menu's
    /// states and actions come from `menuStates`/`perform` below, built
    /// from this pane's own graph rows and the summary's `WhereAmI`.
    private func historyPane(summary: RepositorySummary) -> some View {
        CommitHistoryView(
            entries: history, graphRows: graphRows,
            headOid: summary.whereAmI.rawHead.isEmpty ? nil : summary.whereAmI.rawHead,
            refs: sidebar?.refs,
            branchName: summary.whereAmI.branch,
            menuStates: { oid in menuStates(for: oid, summary: summary) },
            perform: { action, oid in perform(action, oid, summary: summary) },
            scrollRequest: historyScrollRequest,
            selection: Binding(
                get: { selectedCommit },
                set: { newValue in
                    selectedCommit = newValue
                    if newValue != nil {
                        selectedResolution = nil
                        selectedRef = nil
                    }
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
        journalListing = nil
        journalFailure = nil
        journalNotice = nil
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
            // #0393: the journal listing rides along with the other loads —
            // a listing that fails (or a repository that never checkpointed)
            // leaves the menu disabled with its plain titles, not an error.
            journalListing = try? await loadJournalListing(at: repositoryPath)
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

    // MARK: - #0359: commit actions

    /// #0359: an action is running, or #0375's split is. Feeds the menu's
    /// `isBusy` — every item disables with "Another operation is still
    /// running" — so a second action is dropped rather than queued. #0394:
    /// the header's conflict actions take the same guard through
    /// `conflictActionRunning`.
    private var isBusy: Bool { runningAction != nil || conflictActionRunning }

    /// The owners map the row gutter colours with, which the Merge into
    /// Current Branch and Edit Local Branch rules read: the branch that
    /// owns a node is the branch Merge merges; a local branch whose tip
    /// names the node is the one Edit Local Branch edits.
    private var owners: [String: BranchTip] {
        guard let refs = sidebar?.refs else { return [:] }
        return BranchOwnership.owners(in: graphRows, tips: BranchOwnership.tips(from: refs))
    }

    /// #0359: the menu states for one node — its shape from this pane's
    /// graph rows, the branch context from the summary's `WhereAmI`, the
    /// in-progress-operation guards from `TrackingSummary`.
    private func menuStates(for oid: String, summary: RepositorySummary) -> [CommitActionState] {
        guard let context = CommitActionContext.make(
            oid: oid, rows: graphRows, whereAmI: summary.whereAmI,
            owners: owners, isBusy: isBusy)
        else {
            return CommitActionRules.allDisabled(reason: "This commit is no longer in the loaded history")
        }
        return CommitActionRules.states(for: context)
    }

    /// The menu bar's Commit menu target: the selected commit's states and
    /// the same `perform` the context menu calls, so both menus act
    /// identically. `nil` — nothing selected, nothing loaded — leaves every
    /// item disabled with "Select a commit first".
    private var commitMenuTarget: CommitMenuTarget? {
        guard let summary, let selectedCommit else { return nil }
        return CommitMenuTarget(
            states: menuStates(for: selectedCommit, summary: summary),
            perform: { action in perform(action, selectedCommit, summary: summary) })
    }

    /// #0393: the menu bar's Edit menu target — the journal's chain state
    /// and the traversal to run. `nil` with no repository open, which
    /// leaves both items disabled with their plain titles. Both items also
    /// disable while a commit action or a traversal is running, so a second
    /// engine write is dropped rather than queued behind the journal's lock
    /// timeout.
    private var journalMenuTarget: JournalMenuTarget? {
        guard repositoryPath != nil else { return nil }
        let busy = runningAction != nil || journalRunning
        return JournalMenuTarget(
            undoTitle: JournalMenuTitles.undo(
                operation: JournalMenu.undoOperation(in: journalListing)),
            redoTitle: JournalMenuTitles.redo(
                operation: JournalMenu.redoOperation(in: journalListing)),
            undoEnabled: journalListing?.state.undoTarget != nil && !busy,
            redoEnabled: journalListing?.state.redoTarget != nil && !busy,
            perform: { runJournal($0) })
    }

    /// The acted-on commit's index on `HEAD`'s first-parent chain, captured
    /// at dispatch time so the post-rewrite selection lands on the acted-on
    /// commit at its new position.
    private func chainIndex(of oid: String) -> Int? {
        guard let summary, !summary.whereAmI.rawHead.isEmpty else { return nil }
        return FirstParentChain.oids(in: graphRows, from: summary.whereAmI.rawHead)
            .firstIndex(of: oid)
    }

    /// #0359: dispatches one menu action for `oid`. The input-free actions
    /// run at once; the sheet- and confirmation-composed ones open their
    /// prompts, which call back into `run` with the composed request.
    private func perform(_ action: CommitAction, _ oid: String, summary: RepositorySummary) {
        guard !isBusy else { return }
        let entry = history.first(where: { $0.oid == oid })
        let subject = entry?.subject ?? oid
        let chain = summary.whereAmI.rawHead.isEmpty
            ? [] : FirstParentChain.oids(in: graphRows, from: summary.whereAmI.rawHead)
        switch action {
        case .editMessage:
            actionPromptIndex = chain.firstIndex(of: oid) ?? 0
            actionPrompt = .editMessage(
                commit: oid, subject: subject, message: entry?.message ?? "")
        case .squashIntoParent:
            // #0374: the engine's pre-fill — the parent's message and this
            // commit's, combined. The parent is the next commit on the
            // chain; outside the loaded window it contributes nothing.
            let parentMessage = chain.count > 1
                ? history.first(where: { $0.oid == chain[1] })?.message ?? "" : ""
            actionPromptIndex = chain.firstIndex(of: oid) ?? 0
            actionPrompt = .squash(
                commit: oid, subject: subject,
                message: Squash.combinedMessage(
                    parent: parentMessage, child: entry?.message ?? ""))
        case .split:
            beginSplit(of: oid)
        case .delete:
            pendingDelete = PendingDelete(commit: oid, subject: subject)
        case .addTag:
            actionPromptIndex = chain.firstIndex(of: oid) ?? 0
            actionPrompt = .addTag(commit: oid, subject: subject)
        case .createBranch:
            actionPromptIndex = chain.firstIndex(of: oid) ?? 0
            actionPrompt = .createBranch(commit: oid, subject: subject)
        case .editLocalBranch:
            guard let branch = owners[oid], !branch.isRemote, branch.oid == oid else { return }
            actionPromptIndex = chain.firstIndex(of: oid) ?? 0
            actionPrompt = .renameBranch(old: branch.name, commit: oid, subject: subject)
        case .fixupIntoParent, .swapWithParent, .swapWithChild, .revert, .cherryPick,
             .merge, .rebaseOnto, .setBranchTip:
            guard let request = CommitActionRequest.make(
                for: action, oid: oid, chain: chain, owners: owners)
            else { return }
            run(request, action, fromIndex: chain.firstIndex(of: oid) ?? 0)
        }
    }

    /// #0359: runs one engine-backed commit action and refreshes the panes
    /// in place. The engine call runs inside its own journal checkpoint —
    /// one undo step, as the CLI verbs are — so this adds no checkpoint of
    /// its own. On failure the alert names the typed refusal; the refresh
    /// happens after a failure too, because a conflicted replay leaves the
    /// repository mid-cherry-pick and only a refresh makes the header say
    /// so — and the refreshed `WhereAmI` then disables every item with that
    /// same sentence.
    private func run(_ request: CommitActionRequest, _ action: CommitAction, fromIndex index: Int) {
        guard let repositoryPath else { return }
        runningAction = action
        Task {
            defer { runningAction = nil }
            var succeeded = true
            do {
                try await performCommitAction(request, at: repositoryPath)
            } catch {
                succeeded = false
                actionFailure = CommitActionFailure.make(for: action, error: error)
            }
            await refreshAfterMutation { rows, newHead in
                succeeded
                    ? RewriteSelection.oid(after: action, from: index, rows: rows, newHead: newHead)
                    : selectedCommit
            }
        }
    }

    /// #0375: opens the Split sheet for the commit the context menu named.
    /// The subject and full message are resolved from `history` now and
    /// carried by the request; a commit no longer in `history` still opens
    /// the sheet — it falls back to the oid as its subject and lets the
    /// diff load answer whether anything is there to split.
    private func beginSplit(of oid: String) {
        guard !isBusy else { return }
        let entry = history.first(where: { $0.oid == oid })
        splitRequest = SplitCommitRequest(
            commit: oid,
            subject: entry?.subject ?? oid,
            message: entry?.message ?? "")
    }

    /// #0375: runs the split the sheet composed, after the sheet has
    /// dismissed, through the same `performCommitAction` path every other
    /// action takes. `Split.run` performs the whole rewrite inside one
    /// journal checkpoint, so `yard undo` reverses it as a single step.
    /// On failure the alert names the typed error; on success the selection
    /// moves to the second half — the remaining changes, which sit at the
    /// acted-on commit's old chain index — and the panes refresh in place.
    private func runSplit(_ arguments: SplitArguments) async {
        guard let repositoryPath else { return }
        let index = chainIndex(of: arguments.commit) ?? 0
        runningAction = .split
        defer { runningAction = nil }
        do {
            try await performCommitAction(
                .split(
                    commit: arguments.commit, hunkID: arguments.hunkID,
                    first: arguments.firstMessage, second: arguments.secondMessage),
                at: repositoryPath)
            await refreshAfterMutation { rows, newHead in
                RewriteSelection.oid(
                    after: .split, from: index, rows: rows, newHead: newHead)
            }
        } catch {
            actionFailure = CommitActionFailure.make(for: .split, error: error)
            await refreshAfterMutation { _, _ in selectedCommit }
        }
    }

    /// #0393: runs one journal traversal for the Edit menu and refreshes
    /// the panes through #0359's in-place refresh — never `reload()`,
    /// which blanks the window. The selection survives when its commit is
    /// still loaded and moves to `HEAD` otherwise, which a traversal that
    /// moved branches may have changed. A not-clean report presents its
    /// note; a throw presents the engine's message; the listing is re-read
    /// on every path through `refreshAfterMutation`, so the titles stay
    /// current after the chain moves.
    private func runJournal(_ kind: JournalMenuTarget.Kind) {
        guard let repositoryPath, runningAction == nil, !journalRunning else { return }
        journalRunning = true
        Task {
            defer { journalRunning = false }
            do {
                let reports = kind == .undo
                    ? try await undoJournal(at: repositoryPath)
                    : try await redoJournal(at: repositoryPath)
                if let branch = reports.first(where: { $0.detachedFrom != nil })?.detachedFrom
                    ?? reports.flatMap(\.leftAlone).first {
                    journalNotice =
                        "Undone, but “\(branch)” is checked out in another worktree and was left as it is."
                }
                await refreshAfterMutation { rows, newHead in
                    if let selected = selectedCommit,
                       rows.contains(where: { $0.oid == selected }) {
                        return selected
                    }
                    return newHead.isEmpty ? nil : newHead
                }
            } catch {
                journalFailure = CommitActionFailure(
                    title: kind == .undo ? "Couldn’t Undo" : "Couldn’t Redo",
                    message: String(describing: error))
                // The traversal refused, so the chain is where it was — but
                // the listing is cheap, and re-reading it keeps the titles
                // honest if the journal moved while the menu was open.
                journalListing = try? await loadJournalListing(at: repositoryPath)
            }
        }
    }

    // MARK: - #0394: the header's conflict hand-off

    /// #0394: the header's Resolve Conflicts… — registers the app-side
    /// pending resolve through the injected closure, whose await returns
    /// when the human decides in the pane (the pane itself opens through
    /// the `resolves.activePane` sheet binding when `pendingDidRegister`
    /// fires), then refreshes in place so the header shows the resolved
    /// state. With nothing injected (tests, previews) this only refreshes.
    private func beginResolve() {
        guard let repositoryPath, !isBusy else { return }
        conflictActionRunning = true
        Task {
            defer { conflictActionRunning = false }
            await onBeginInAppResolve?(repositoryPath)
            await refreshAfterMutation { _, _ in selectedCommit }
        }
    }

    /// #0394: the header's Continue — completes the in-flight operation the
    /// way git does from a terminal, through the `@concurrent` wrapper on
    /// `ConflictHandoff.runContinue`. Never called for the `Rewrite`
    /// family's detached replay (the header's gate is
    /// `ConflictHandoff.continuableKind`); the refresh uses `runJournal`'s
    /// selection rule — keep the selected commit when it is still loaded,
    /// else HEAD's new oid. A failure presents as the failure alert, and
    /// the refresh happens anyway, because only a refresh makes the header
    /// say what the repository actually shows.
    private func runContinue(kind: ConflictHandoff.Kind) {
        guard let repositoryPath, !isBusy else { return }
        conflictActionRunning = true
        Task {
            defer { conflictActionRunning = false }
            do {
                _ = try await continueInAppOperation(kind: kind, at: repositoryPath)
            } catch {
                actionFailure = CommitActionFailure(
                    title: "Couldn’t Continue \(ConflictHandoff.name(of: kind))",
                    message: String(describing: error))
            }
            await refreshAfterMutation { rows, newHead in
                if let selected = selectedCommit,
                   rows.contains(where: { $0.oid == selected }) {
                    return selected
                }
                return newHead.isEmpty ? nil : newHead
            }
        }
    }

    /// #0394: the header's Abort, already confirmed by the dialog — one
    /// journal undo restores the pre-operation entry and the operation's
    /// own `--abort` clears the conflict state files the restore leaves
    /// (`ConflictHandoff.runAbort`). A failure presents as the failure
    /// alert, and the refresh happens anyway, the same as `runContinue`.
    private func runAbort() {
        guard let repositoryPath, !isBusy else { return }
        conflictActionRunning = true
        Task {
            defer { conflictActionRunning = false }
            do {
                try await abortInAppOperation(at: repositoryPath)
            } catch {
                actionFailure = CommitActionFailure(
                    title: "Couldn’t Abort",
                    message: String(describing: error))
            }
            await refreshAfterMutation { rows, newHead in
                if let selected = selectedCommit,
                   rows.contains(where: { $0.oid == selected }) {
                    return selected
                }
                return newHead.isEmpty ? nil : newHead
            }
        }
    }

    /// #0359: re-reads after an in-app mutation without blanking the
    /// window: every value loads into a local, then all assignments happen
    /// together on one main-actor turn. `reload()` stays the
    /// open-a-repository path — it clears every selection and drops the
    /// window to the Loading spinner, the exact flicker a history rewrite
    /// must not cause.
    private func refreshAfterMutation(select: ([GraphRow], String) -> String?) async {
        guard let repositoryPath else { return }
        do {
            let newSummary = try await loadRepositorySummary(at: repositoryPath)
            let newHistory = (try? await loadCommitHistory(at: repositoryPath)) ?? []
            let newRows = (try? await loadCommitGraph(at: repositoryPath)) ?? []
            let newSidebar = try? await loadRepositorySidebar(at: repositoryPath)
            // #0393: every in-app mutation re-reads the journal listing too,
            // so the Edit menu's titles and enabled flags track the chain —
            // a commit action wrote a checkpoint the menu must now see.
            let newJournal = try? await loadJournalListing(at: repositoryPath)
            summary = newSummary
            history = newHistory
            graphRows = newRows
            sidebar = newSidebar
            journalListing = newJournal
            if let newSelection = select(newRows, newSummary.whereAmI.rawHead) {
                selectedResolution = nil
                selectedCommit = newSelection
            }
        } catch {
            errorMessage = String(describing: error)
            summary = nil
        }
    }
}

/// #0359: the commit action's presentations — the #0375 Split sheet, the
/// prompt sheets, the Delete Commit… confirmation, the failure alert and
/// the menu bar's focused target — as one modifier, so `body` stays inside
/// the type-checker's budget. A `ViewModifier` rather than chained
/// closures: the same shape, one level of indentation up.
private struct CommitActionOverlays: ViewModifier {
    @Binding var splitRequest: SplitCommitRequest?
    @Binding var actionPrompt: CommitActionPrompt?
    @Binding var actionPromptIndex: Int?
    @Binding var pendingDelete: PendingDelete?
    @Binding var actionFailure: CommitActionFailure?
    let commitMenuTarget: CommitMenuTarget?
    let repositoryPath: String?
    let branchName: String?
    /// #0397: short branch and tag names from the sidebar's ref snapshot —
    /// the names the prompt sheets refuse to collide with. Entries carry
    /// full refnames (`refs/heads/x`); the caller strips the namespace.
    let existingBranches: [String]
    let existingTags: [String]
    let onPromptRequest: (CommitActionRequest) -> Void
    let onPromptCancel: () -> Void
    let onDeleteConfirmed: (PendingDelete) -> Void
    let onSplit: (SplitArguments) -> Void

    func body(content: Content) -> some View {
        content
            // #0359: the menu bar's Commit menu acts on the focused
            // window's selected commit — the same states and the same
            // `perform` the row context menu uses, which is what makes the
            // shortcuts real (#0382's spike covers whether the context
            // menu's own equivalents fire while it is closed).
            .focusedSceneValue(\.commitMenuTarget, commitMenuTarget)
            // #0375: the Split sheet, for the commit the History context
            // menu's Split… item named. Choosing Split dismisses the sheet
            // first, then runs `Split.run` — one journal checkpoint,
            // undoable — through `performCommitAction`; a failure shows the
            // alert, a success refreshes the panes and selects the second
            // half.
            .sheet(item: $splitRequest) { request in
                SplitCommitSheet(
                    commit: request.commit,
                    subject: request.subject,
                    repositoryPath: repositoryPath ?? "",
                    originalMessage: request.message,
                    onSplit: onSplit,
                    onCancel: { splitRequest = nil })
            }
            // #0359: the prompt sheets the commit action menu opens.
            .sheet(item: $actionPrompt) { prompt in
                CommitActionPromptSheet(
                    prompt: prompt,
                    existingBranches: existingBranches,
                    existingTags: existingTags,
                    onRequest: onPromptRequest,
                    onCancel: onPromptCancel)
            }
            // #0359: the Delete Commit… confirmation. Return does nothing —
            // there is deliberately no `.keyboardShortcut(.defaultAction)`
            // on the destructive button, which must never sit one accidental
            // Return away from deleting history.
            .confirmationDialog(
                pendingDelete?.dialogTitle ?? "",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { delete in
                Button("Delete Commit", role: .destructive) { onDeleteConfirmed(delete) }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { _ in
                Text(
                    "Its changes are removed from \(branchName ?? "HEAD"), and every newer commit is replayed without them."
                )
            }
            // #0359: a failed engine call names its typed refusal, with the
            // recovery sentence for the conflict and signing exit classes.
            .alert(
                actionFailure?.title ?? "",
                isPresented: Binding(
                    get: { actionFailure != nil },
                    set: { if !$0 { actionFailure = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionFailure?.message ?? "")
            }
    }
}

#Preview {
    ContentView()
}
