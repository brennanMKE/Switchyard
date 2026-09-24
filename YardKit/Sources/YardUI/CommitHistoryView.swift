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
    private let graphRows: [GraphRow]
    private let headOid: String?
    /// The repository's refs (#0366): tips derived from this claim history,
    /// colouring each row's gutter by the owning branch, and (#0368) the
    /// local tips whose reachability dims and dashes remote-only history.
    /// `nil` -- previews and callers that have not loaded the sidebar yet --
    /// leaves every node and edge unowned, drawing `.secondary` as before,
    /// every edge solid and every row at full opacity.
    private let refs: RefSnapshot?
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
    /// #0410: the commit the map should scroll to -- set from
    /// `scrollRequest`, the first match and match stepping.
    @State private var focusRequest: HistoryScrollRequest?
    @Binding private var selection: String?

    public init(
        entries: [CommitLogEntry], graphRows: [GraphRow] = [], headOid: String? = nil,
        refs: RefSnapshot? = nil, branchName: String? = nil,
        menuStates: ((String) -> [CommitActionState])? = nil,
        perform: ((CommitAction, String) -> Void)? = nil,
        scrollRequest: HistoryScrollRequest? = nil,
        onOpenChanges: ((String) -> Void)? = nil,
        highlightQuery: String = "",
        selection: Binding<String?>
    ) {
        self.entries = entries
        self.graphRows = graphRows
        self.headOid = headOid
        self.refs = refs
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
        let chipsByOid: [String: [RefChip]] = Dictionary(
            entries.map { entry in
                (entry.oid, refs.map { RefChips.make(oid: entry.oid, refs: $0, decoration: entry.refs) } ?? [])
            },
            uniquingKeysWith: { first, _ in first })
        let matchOids: [String] = query.isEmpty ? [] : entries.compactMap { entry in
            HistoryFilter.matches(entry, chips: chipsByOid[entry.oid] ?? [], query: query) ? entry.oid : nil
        }
        // #0410: the map needs only each commit's oid and parents. Callers
        // that pass no graph rows (previews) get the map from `entries`.
        let mapRows = graphRows.isEmpty
            ? entries.map { GraphRow(oid: $0.oid, parents: $0.parents, lane: 0, parentLanes: $0.parents.map { _ in 0 }) }
            : graphRows
        let localOids = refs.map {
            LocalReachability.oids(in: mapRows, from: LocalReachability.localTips(refs: $0, headOid: headOid))
        }

        VStack(spacing: 0) {
            if !query.isEmpty {
                matchBar(matchOids: matchOids)
                Divider()
            }
            BranchMapView(
                layout: BranchMapLayout.make(rows: mapRows, refs: refs),
                entriesByOid: Dictionary(entries.map { ($0.oid, $0) }, uniquingKeysWith: { first, _ in first }),
                chipsByOid: chipsByOid,
                headOid: headOid,
                localOids: localOids,
                matches: query.isEmpty ? nil : Set(matchOids),
                branchName: branchName,
                menuStates: menuStates,
                perform: perform,
                onOpenChanges: onOpenChanges,
                focusRequest: focusRequest,
                selection: $selection)
        }
        // #0401: a sidebar click asks for its branch tip to be shown. Only a
        // new request scrolls; picking a commit in the map does not, so the
        // map never jumps under the user's cursor.
        .onChange(of: scrollRequest) { _, request in
            focusRequest = request
        }
        // #0402: typing jumps to the first match.
        .onChange(of: query) { _, _ in
            matchIndex = 0
            if let first = matchOids.first {
                focusRequest = HistoryScrollRequest(oid: first)
            }
        }
    }

    /// #0402: "N matches" with previous/next. Stepping selects the match (so
    /// the Detail pane follows) and scrolls it to the centre.
    private func matchBar(matchOids: [String]) -> some View {
        HStack(spacing: 8) {
            Text(matchOids.count == 1 ? "1 match" : "\(matchOids.count) matches")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                step(-1, in: matchOids)
            } label: {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .help("Previous match (⇧⌘G)")
            .disabled(matchOids.isEmpty)
            Button {
                step(1, in: matchOids)
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

    private func step(_ delta: Int, in matchOids: [String]) {
        guard !matchOids.isEmpty else { return }
        matchIndex = (matchIndex + delta + matchOids.count) % matchOids.count
        let oid = matchOids[matchIndex]
        selection = oid
        focusRequest = HistoryScrollRequest(oid: oid)
    }
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
    CommitHistoryView(
        entries: [
            CommitLogEntry(
                oid: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
                parents: [],
                author: "Ada Lovelace",
                refs: "HEAD -> main",
                signatureStatus: .noSig,
                message: "Add the History pane",
                trailers: []
            ),
        ],
        selection: $selection
    )
}
