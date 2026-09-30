// CommitHistoryView.swift

import SwiftUI
import YardGit

/// The History pane's content: #0410's branch map (`BranchMapView`). Every
/// labelled lane's tip sits on the top row under its slanted label, each
/// branch's own commits run down its lane, and fork and merge edges join
/// them. Until #0410 this was a `List` of commits in topological order with
/// a lane gutter (#0052, #0399).
///
/// `selection` is keyed on `oid` rather than an index or a wrapper type so
/// #0082's detail pane can observe it without this view owning navigation.
///
/// The map is laid out from `graphRows` (only each commit's oid and parents
/// matter); `entries` supply what each commit's accessibility label and the
/// filter read. `graphRows` defaults to `[]`, and then the map is laid out
/// from `entries`, so the `#Preview` below still shows a commit.
public struct CommitHistoryView: View {
    private let entries: [CommitLogEntry]
    /// #0554: `entries` indexed against `refs` by the caller, once per load
    /// (guide §11 decision 44): the chips, the commits by oid and the
    /// filter's matches. `body` reads it and builds none of it.
    private let index: HistoryIndex
    private let graphRows: [GraphRow]
    private let headOid: String?
    /// The repository's refs (#0366): tips derived from this claim history,
    /// colouring each row's gutter by the owning branch, and (#0368) the
    /// local tips whose reachability dims and dashes remote-only history.
    /// `nil` -- previews and callers that have not loaded the sidebar yet --
    /// leaves every node and edge unowned, drawing `.secondary` as before,
    /// every edge solid and every row at full opacity.
    private let refs: RefSnapshot?
    /// #0428: the default branch (the map's root lane) and each branch tip's
    /// commit date (#0429's recency filter). `nil` roots the map at `main`,
    /// else `HEAD`'s branch.
    private let branchTips: BranchTipDates.Report?
    /// #0430: the repository, for the merged read. `nil` (previews) dims
    /// nothing.
    private let repositoryPath: String?
    /// #0359: the commit action menu's states for the clicked row's oid,
    /// built by `ContentView` from that row's shape. `nil` — previews and
    /// callers that offer no menu — leaves only Copy Commit ID.
    private let menuStates: ((String) -> [CommitActionState])?
    /// #0359: runs the chosen action against the clicked row's oid. `nil`
    /// alongside `menuStates`.
    private let perform: ((CommitAction, String) -> Void)?
    /// #0359: the current branch, for the branch-aware item titles.
    private let branchName: String?
    /// #0401: scrolls the list when it changes; `nil` means no request.
    private let scrollRequest: HistoryScrollRequest?
    /// #0406: double-clicking a row opens that commit's changes window.
    private let onOpenChanges: ((String) -> Void)?
    /// #0402: the filter field's text; non-matching rows dim.
    private let highlightQuery: String
    /// #0402: which match the previous/next buttons are on.
    @State private var matchIndex = 0
    /// #0556: the last previous/next press. The buttons only record it and
    /// `onChange(of: matchStep)` steps, so the step reads this render's
    /// matches: ⌘G ran the button's action from the render that first
    /// showed the match bar, with that render's matches (measured in the VM).
    @State private var matchStep: MatchStepRequest?
    /// #0524: what the filter text is matched against (guide §11 decision
    /// 40). Per window, not persisted.
    @State private var searchScope: HistorySearchScope = .commits
    /// #0524: the `.paths`/`.content` matches git returned, in History's order.
    @State private var engineMatches: [String] = []
    /// #0524: true while git runs a `.paths`/`.content` search.
    @State private var searching = false
    /// #0410: the commit the map should scroll to -- set from
    /// `scrollRequest`, the first match and match stepping.
    @State private var focusRequest: HistoryScrollRequest?
    /// #0427: the folds opened in this window, by `Fold.key`. Not persisted.
    @State private var expandedFolds: Set<String> = []
    /// #0429: the map's recency window, app-wide (guide §11 decision 29).
    @AppStorage("branchMapRecency") private var recency: BranchRecency = .standard
    /// #0429: commits the sidebar asked for; a hidden lane whose tip is one
    /// of them shows. Per window, not persisted.
    @State private var revealedTips: Set<String> = []
    /// #0430: short names of the shown branches decision 27 calls merged.
    @State private var mergedBranches: Set<String> = []
    @Binding private var selection: String?

    public init(
        entries: [CommitLogEntry], index: HistoryIndex, graphRows: [GraphRow] = [], headOid: String? = nil,
        refs: RefSnapshot? = nil, branchTips: BranchTipDates.Report? = nil, repositoryPath: String? = nil,
        branchName: String? = nil,
        menuStates: ((String) -> [CommitActionState])? = nil,
        perform: ((CommitAction, String) -> Void)? = nil,
        scrollRequest: HistoryScrollRequest? = nil,
        onOpenChanges: ((String) -> Void)? = nil,
        highlightQuery: String = "",
        selection: Binding<String?>
    ) {
        self.entries = entries
        self.index = index
        self.graphRows = graphRows
        self.headOid = headOid
        self.refs = refs
        self.branchTips = branchTips
        self.repositoryPath = repositoryPath
        self.branchName = branchName
        self.menuStates = menuStates
        self.perform = perform
        self.scrollRequest = scrollRequest
        self.onOpenChanges = onOpenChanges
        self.highlightQuery = highlightQuery
        self._selection = selection
    }

    public var body: some View {
        let query = HistoryFilter.normalized(highlightQuery)
        let matchOids: [String] = if query.isEmpty {
            []
        } else if searchScope.engineKind == nil {
            index.matches(query: query)
        } else {
            engineMatches
        }
        // #0410: the map needs only each commit's oid and parents. Callers
        // that pass no graph rows (previews) get the map from `entries`.
        let mapRows = graphRows.isEmpty
            ? entries.map { GraphRow(oid: $0.oid, parents: $0.parents, lane: 0, parentLanes: $0.parents.map { _ in 0 }) }
            : graphRows
        let shownTips = recency.shownTips(
            refs: refs, dates: branchTips?.dates, now: Date(), revealed: revealedTips)
        let layout = BranchMapLayout.make(
            rows: mapRows, refs: refs, defaultBranch: branchTips?.defaultBranch, expandedFolds: expandedFolds,
            shownTips: shownTips)
        // #0430: the local branches on the map's lanes, which the merged
        // read is limited to -- and which restart it when they change.
        let laneBranches = layout.headers
            .flatMap { $0.chips.filter { $0.kind == .localBranch }.map { "refs/heads/" + $0.name } }
            .sorted()
        let localOids = refs.map {
            LocalReachability.oids(in: mapRows, from: LocalReachability.localTips(refs: $0, headOid: headOid))
        }

        VStack(spacing: 0) {
            recencyBar
            Divider()
            if !query.isEmpty {
                matchBar(matchOids: matchOids, layout: layout)
                Divider()
            }
            BranchMapView(
                layout: layout,
                entriesByOid: index.entriesByOid,
                chipsByOid: index.chipsByOid,
                headOid: headOid,
                localOids: localOids,
                matches: query.isEmpty ? nil : Set(matchOids),
                branchName: branchName,
                menuStates: menuStates,
                perform: perform,
                onOpenChanges: onOpenChanges,
                focusRequest: focusRequest,
                onExpandFold: { expandedFolds.insert($0) },
                dimmedLanes: layout.dimmedLanes(mergedBranches: mergedBranches),
                selection: $selection)
        }
        // #0430: guide §11 decision 27's composite, for the lanes shown:
        // ancestry and upstream-gone from one for-each-ref first, then the
        // merge-tree content pass for the rest.
        .task(id: [repositoryPath ?? ""] + laneBranches) {
            await reloadMerged(branches: Set(laneBranches))
        }
        // #0401: a sidebar click asks for its branch tip to be shown. Only a
        // new request scrolls; picking a commit in the map does not, so the
        // map never jumps under the user's cursor.
        .onChange(of: scrollRequest) { _, request in
            // #0429: a branch the recency filter hides shows once picked.
            if let request { revealedTips.insert(request.oid) }
            focus(request, in: layout)
        }
        // #0402: typing jumps to the first match. #0524: a `.paths` or
        // `.content` search jumps when git answers, in `runEngineSearch`.
        .onChange(of: query) { _, _ in
            matchIndex = 0
            if searchScope.engineKind == nil, let first = matchOids.first {
                focus(HistoryScrollRequest(oid: first), in: layout)
            }
        }
        // #0556: a previous/next press, stepped through this render's matches.
        .onChange(of: matchStep) { _, request in
            if let request { step(request.delta, in: matchOids, layout: layout) }
        }
        .onChange(of: searchScope) { _, scope in
            matchIndex = 0
            if scope.engineKind == nil, let first = matchOids.first {
                focus(HistoryScrollRequest(oid: first), in: layout)
            }
        }
        // #0524: a new query, scope or history restarts the git search;
        // the old task's cancellation terminates its `git`.
        .task(id: HistorySearchKey(
            query: query, scope: searchScope, repositoryPath: repositoryPath,
            firstOid: entries.first?.oid, count: entries.count)) {
            await runEngineSearch(query: query, layout: layout)
        }
    }

    /// #0524: runs the `.paths`/`.content` search for `query` over the
    /// loaded commits, then jumps to the first match, as typing does for
    /// `.commits`. The short sleep lets typing settle: each keystroke
    /// restarts the task, and a cancelled task stops here or terminates its
    /// `git`.
    private func runEngineSearch(query: String, layout: BranchMapLayout) async {
        guard let kind = searchScope.engineKind, !query.isEmpty, let repositoryPath else {
            // Guarded: this runs on every Commits-scope keystroke.
            if !engineMatches.isEmpty { engineMatches = [] }
            if searching { searching = false }
            return
        }
        searching = true
        let found: [String]
        do {
            try await Task.sleep(for: .milliseconds(250))
            found = try await loadHistorySearch(
                at: repositoryPath, kind: kind, query: query, candidates: entries.map(\.oid))
        } catch {
            if Task.isCancelled { return }
            found = []
        }
        guard !Task.isCancelled else { return }
        engineMatches = found
        searching = false
        matchIndex = 0
        if let first = found.first {
            focus(HistoryScrollRequest(oid: first), in: layout)
        }
    }

    /// #0430: fills `mergedBranches` for `branches` (full ref names).
    private func reloadMerged(branches: Set<String>) async {
        guard let repositoryPath, !branches.isEmpty,
              let report = try? await BranchStatus.read(at: repositoryPath)
        else {
            mergedBranches = []
            return
        }
        let shown = BranchStatus.Report(
            defaultBranch: report.defaultBranch, rows: report.rows.filter { branches.contains($0.ref) })
        mergedBranches = BranchMapLayout.mergedBranches(in: shown, content: [:])
        let content = (try? await BranchStatus.contentPass(for: shown, at: repositoryPath)) ?? [:]
        mergedBranches = BranchMapLayout.mergedBranches(in: shown, content: content)
    }

    /// #0429: the recency pop-up. It filters only the map (the sidebar
    /// lists every branch), so it sits at the top of this pane rather than
    /// in the window toolbar -- guide §11 decision 29.
    private var recencyBar: some View {
        HStack(spacing: 8) {
            Picker("Branches", selection: $recency) {
                ForEach(BranchRecency.allCases) { window in
                    Text(window.title).tag(window)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("branch-map-recency")
            .help("Show branches whose tip was committed this recently. The default branch, "
                + "the current branch and branches picked in the sidebar always show.")
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// #0402: "N matches" with previous/next. Stepping selects the match (so
    /// the Detail pane follows) and scrolls it to the centre.
    private func matchBar(matchOids: [String], layout: BranchMapLayout) -> some View {
        HStack(spacing: 8) {
            // #0524: what the text is matched against (guide §11 decision 40).
            Picker("Search", selection: $searchScope) {
                ForEach(HistorySearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("history-search-scope")
            .help(searchScope.help)
            Text(HistorySearchScope.summary(count: matchOids.count, searching: searching))
                // The segmented control leaves little room; the count wraps
                // to two lines without these (planning VM screenshot).
                .lineLimit(1)
                .fixedSize()
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                matchStep = MatchStepRequest(delta: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .help("Previous match (⇧⌘G)")
            .disabled(matchOids.isEmpty)
            Button {
                matchStep = MatchStepRequest(delta: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("g", modifiers: .command)
            .help("Next match (⌘G)")
            .disabled(matchOids.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func step(_ delta: Int, in matchOids: [String], layout: BranchMapLayout) {
        guard !matchOids.isEmpty else { return }
        matchIndex = (matchIndex + delta + matchOids.count) % matchOids.count
        let oid = matchOids[matchIndex]
        selection = oid
        focus(HistoryScrollRequest(oid: oid), in: layout)
    }

    /// #0427: scrolls the map to `request`'s commit, first opening the fold
    /// that hides it, so a sidebar click or a filter match inside a fold
    /// lands on a node.
    private func focus(_ request: HistoryScrollRequest?, in layout: BranchMapLayout) {
        if let oid = request?.oid, let fold = layout.folds.first(where: { $0.oids.contains(oid) }) {
            expandedFolds.insert(fold.key)
        }
        focusRequest = request
    }
}

/// #0556: one press of the match bar's previous (-1) or next (+1). The
/// fresh `serial` makes a second press in the same direction a change.
private nonisolated struct MatchStepRequest: Equatable {
    let delta: Int
    let serial = UUID()
}

/// #0524: what restarts a `.paths`/`.content` search: the text, the scope,
/// the repository, and the loaded history (a reload after a commit changes
/// its first oid or its count).
private nonisolated struct HistorySearchKey: Equatable {
    let query: String
    let scope: HistorySearchScope
    let repositoryPath: String?
    let firstOid: String?
    let count: Int
}

/// One ref chip: a capsule before the subject, tinted by #0366's colours and
/// marked with the same symbols the sidebar uses, so the two panes read as
/// one vocabulary.
struct RefChipView: View {
    let chip: RefChip
    let tint: Color

    var body: some View {
        Label(chip.name, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(chip.isHead ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background {
                switch chip.kind {
                case .localBranch:
                    Capsule().fill(tint.opacity(chip.isHead ? 0.35 : 0.18))
                case .remoteBranch:
                    Capsule().strokeBorder(tint, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                case .tag:
                    Capsule().fill(.quaternary)
                case .detachedHead:
                    Capsule().strokeBorder(.orange, lineWidth: 1.5)
                }
            }
            // #0400: chips can sit over lanes to their right; an opaque
            // capsule behind the tint keeps the name legible.
            .background(Capsule().fill(.background))
            .help(helpText)
    }

    private var symbol: String {
        switch chip.kind {
        case .localBranch: chip.isHead ? "checkmark.circle.fill" : "arrow.triangle.branch"
        case .remoteBranch: "network"
        case .tag: "tag"
        case .detachedHead: "exclamationmark.triangle"
        }
    }

    private var helpText: String {
        switch chip.kind {
        case .localBranch: chip.isHead ? "Current branch \(chip.name)" : "Branch \(chip.name)"
        case .remoteBranch: "Remote-tracking branch \(chip.name)"
        case .tag: "Tag \(chip.name)"
        case .detachedHead: "HEAD is detached at this commit"
        }
    }
}

#Preview {
    @Previewable @State var selection: String?
    let entries = [
        CommitLogEntry(
            oid: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
            parents: [],
            author: "Ada Lovelace",
            refs: "HEAD -> main",
            signatureStatus: .noSig,
            message: "Add the History pane",
            trailers: []
        ),
    ]
    CommitHistoryView(
        entries: entries,
        index: HistoryIndex(entries: entries, refs: nil),
        selection: $selection
    )
}
