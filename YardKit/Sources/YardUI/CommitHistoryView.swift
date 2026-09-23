// CommitHistoryView.swift

import SwiftUI
import YardGit

/// The History pane's content: one selectable row per commit, newest first
/// as `CommitLog.run` returns them (#0340), each with a lane-gutter graph
/// beside it (#0052).
///
/// `selection` is keyed on `oid` rather than an index or a wrapper type so
/// #0082's detail pane can observe it without this view owning navigation.
/// This view takes no action on selection beyond changing the binding —
/// checkout, revert, and the rest are MVP gaps, not omissions.
///
/// `graphRows` and `entries` are two separate engine calls
/// (`loadCommitGraph`/`loadCommitHistory`, `RepositoryLoader.swift`) joined
/// here by `oid`. A commit with no matching `GraphRow` -- the two calls are
/// independent reads of a repository that can in principle change between
/// them -- renders through `LaneGutterView(row: nil, ...)`, which draws
/// nothing but still reserves the shared gutter width, so that row's text
/// does not shift relative to a matched row's. `graphRows` defaults to `[]`
/// so every existing call site (this file's `#Preview` included) still
/// compiles unchanged.
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
    @Binding private var selection: String?

    public init(
        entries: [CommitLogEntry], graphRows: [GraphRow] = [], headOid: String? = nil,
        refs: RefSnapshot? = nil, branchName: String? = nil,
        menuStates: ((String) -> [CommitActionState])? = nil,
        perform: ((CommitAction, String) -> Void)? = nil,
        scrollRequest: HistoryScrollRequest? = nil,
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
        self._selection = selection
    }

    public var body: some View {
        let rowsByOid = Dictionary(graphRows.map { ($0.oid, $0) }, uniquingKeysWith: { first, _ in first })
        let segmentsByOid = Dictionary(
            zip(graphRows.map(\.oid), LaneSegments.make(graphRows)),
            uniquingKeysWith: { first, _ in first })
        let owners = refs.map { BranchOwnership.owners(in: graphRows, tips: BranchOwnership.tips(from: $0)) } ?? [:]
        let localOids = refs.map {
            LocalReachability.oids(in: graphRows, from: LocalReachability.localTips(refs: $0, headOid: headOid))
        }
        let gutterWidth = LaneGeometry.laneGutterWidth(maxLane: LaneGeometry.maxLane(in: graphRows))

        ScrollViewReader { proxy in
            List(entries, id: \.oid, selection: $selection) { entry in
                CommitHistoryRow(
                    entry: entry,
                    graphRow: rowsByOid[entry.oid],
                    segments: segmentsByOid[entry.oid],
                    owners: owners,
                    localOids: localOids,
                    isHead: entry.oid == headOid,
                    chips: refs.map { RefChips.make(oid: entry.oid, refs: $0, decoration: entry.refs) } ?? [],
                    gutterWidth: gutterWidth)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                    .listRowSeparator(.hidden)
            }
            // #0377: with a row selected, Edit ▸ Copy (⌘C) puts that commit's
            // full oid on the pasteboard. The context menu copies the *clicked*
            // row's oid even when another row is selected.
            .copyable(selection.map { [$0] } ?? [])
            // #0359: one `CommitActionMenuItems` for the clicked row — the same
            // body the menu bar's Commit menu renders, so items, order,
            // shortcuts and disabled states cannot drift apart. Right-clicking
            // an unselected row targets that row, not the selection.
            .contextMenu(forSelectionType: String.self) { clicked in
                if clicked.count == 1, let oid = clicked.first {
                    Button("Copy Commit ID") {
                        CommitIDPasteboard.copy(oid)
                    }
                    if let menuStates, let perform {
                        Divider()
                        CommitActionMenuItems(
                            states: menuStates(oid), branchName: branchName,
                            perform: { perform($0, oid) })
                    }
                }
            }
            // #0401: a sidebar click asks for its branch tip to be shown.
            // Only a new request scrolls; picking a row in this list does
            // not, so the list never jumps under the user's cursor.
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                withAnimation { proxy.scrollTo(request.oid, anchor: .center) }
            }
        }
    }
}

/// One row: a lane gutter, then ref chips and the subject, short OID, author.
/// The chips (#0358, #0367) are the row's ref labels -- branches and remotes
/// from the sidebar's snapshot, tags and a detached `HEAD` from `%D` -- and
/// the whole row is one VoiceOver element speaking `CommitRowAccessibility.label`.
/// A commit no local tip reaches (#0368) draws its text at 0.6 opacity: its
/// history is reachable only from remote-tracking branches.
private struct CommitHistoryRow: View {
    let entry: CommitLogEntry
    let graphRow: GraphRow?
    let segments: LaneRowSegments?
    let owners: [String: BranchTip]
    /// #0368: `LocalReachability.oids(in:from:)`; `nil` draws every row at
    /// full opacity.
    let localOids: Set<String>?
    let isHead: Bool
    let chips: [RefChip]
    let gutterWidth: CGFloat

    var body: some View {
        let isRemoteOnly = localOids.map { !$0.contains(entry.oid) } ?? false
        HStack(alignment: .center, spacing: 8) {
            LaneGutterView(row: graphRow, segments: segments, owners: owners, localOids: localOids,
                           isHead: isHead, width: gutterWidth)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    ForEach(chips, id: \.self) { chip in
                        RefChipView(chip: chip, tint: BranchColor.color(for: chip))
                    }
                    Text(entry.subject)
                        .fontWeight(isHead ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 8) {
                    Text(entry.shortOid)
                        .font(.system(.caption, design: .monospaced))
                    Text(entry.author)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .opacity(isRemoteOnly ? 0.6 : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(CommitRowAccessibility.label(entry: entry, chips: chips))
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
