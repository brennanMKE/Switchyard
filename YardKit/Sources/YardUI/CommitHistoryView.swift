// CommitHistoryView.swift

import SwiftUI
import YardGit

/// The History pane's content: one selectable row per commit, newest first
/// as `CommitLog.run` returns them (#0340).
///
/// `selection` is keyed on `oid` rather than an index or a wrapper type so
/// #0082's detail pane can observe it without this view owning navigation.
/// This view takes no action on selection beyond changing the binding —
/// checkout, revert, and the rest are MVP gaps, not omissions.
public struct CommitHistoryView: View {
    private let entries: [CommitLogEntry]
    @Binding private var selection: String?

    public init(entries: [CommitLogEntry], selection: Binding<String?>) {
        self.entries = entries
        self._selection = selection
    }

    public var body: some View {
        List(entries, id: \.oid, selection: $selection) { entry in
            CommitHistoryRow(entry: entry)
        }
    }
}

/// One row: subject, short OID, author, and refs when non-empty.
private struct CommitHistoryRow: View {
    let entry: CommitLogEntry

    var body: some View {
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
