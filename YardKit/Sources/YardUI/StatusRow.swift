// StatusRow.swift

import SwiftUI
import YardGit

/// One row in the status list: `path`, the staged and worktree state
/// characters, and `originalPath` when present (a rename).
struct StatusRow: View {
    let entry: WorktreeStatusEntry

    var body: some View {
        HStack(spacing: 8) {
            Text("\(entry.staged.rawValue)\(entry.worktree.rawValue)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.path)
                if let originalPath = entry.originalPath {
                    Text("was \(originalPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    List {
        StatusRow(entry: WorktreeStatusEntry(path: "Sources/Example.swift"))
    }
}
