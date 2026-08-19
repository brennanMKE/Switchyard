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
    @Binding private var selection: String?

    public init(entries: [CommitLogEntry], graphRows: [GraphRow] = [], selection: Binding<String?>) {
        self.entries = entries
        self.graphRows = graphRows
        self._selection = selection
    }

    public var body: some View {
        let rowsByOid = Dictionary(graphRows.map { ($0.oid, $0) }, uniquingKeysWith: { first, _ in first })
        let gutterWidth = LaneGeometry.laneGutterWidth(maxLane: LaneGeometry.maxLane(in: graphRows))

        List(entries, id: \.oid, selection: $selection) { entry in
            CommitHistoryRow(entry: entry, graphRow: rowsByOid[entry.oid], gutterWidth: gutterWidth)
        }
    }
}

/// One row: a lane gutter, then subject, short OID, author, and refs when
/// non-empty.
private struct CommitHistoryRow: View {
    let entry: CommitLogEntry
    let graphRow: GraphRow?
    let gutterWidth: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            LaneGutterView(row: graphRow, width: gutterWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.subject)
                HStack(spacing: 8) {
                    Text(entry.shortOid)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(entry.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !entry.refs.isEmpty {
                        Text(entry.refs)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
