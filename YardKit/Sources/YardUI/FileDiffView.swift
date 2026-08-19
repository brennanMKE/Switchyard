// FileDiffView.swift

import SwiftUI
import YardGit

/// One file's diff: its path, and either a binary note or its hunks
/// (#0082). Kept in its own file, separate from `CommitDetailView`, so
/// #0055's review sheet and #0057's three-way merge can reuse it later
/// without a refactor -- the issue's "Re-scoped 2026-08-18" note is that
/// this separation is the whole of what "factored for reuse" means for the
/// MVP, nothing more.
public struct FileDiffView: View {
    private let file: FileDiff

    public init(file: FileDiff) {
        self.file = file
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.path)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .textSelection(.enabled)

            // Binary files are reported, not rendered -- `FileDiff.isBinary`
            // is the flag; `hunks` is always empty for a binary change and
            // rendering it would silently show nothing.
            if file.isBinary {
                Text("Binary file")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(file.hunks, id: \.id) { hunk in
                    HunkView(hunk: hunk)
                }
            }
        }
    }
}

/// One hunk: its `@@` header line, then its body lines.
private struct HunkView: View {
    let hunk: Hunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
            ForEach(Array(hunk.body.enumerated()), id: \.offset) { _, line in
                DiffLineView(line: line)
            }
        }
        .padding(.bottom, 8)
    }
}

/// One body line of a hunk. Added and removed lines are visually
/// distinguished by a tinted background keyed on the leading marker git
/// prints (` `, `-`, `+`, or `\` for "No newline at end of file") --
/// `.green`/`.red` are SwiftUI's context-dependent system colors, which
/// adapt to light and dark automatically, not a fixed RGB literal.
private struct DiffLineView: View {
    let line: String

    private var marker: Character? { line.first }

    private var backgroundTint: Color {
        switch marker {
        case "+": Color.green.opacity(0.12)
        case "-": Color.red.opacity(0.12)
        default: Color.clear
        }
    }

    var body: some View {
        Text(line)
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .background(backgroundTint)
            .foregroundStyle(marker == "\\" ? .secondary : .primary)
    }
}

#Preview {
    FileDiffView(file: FileDiff(
        path: "Sources/Example.swift",
        oldMode: nil,
        newMode: nil,
        isBinary: false,
        headerText: "diff --git a/Sources/Example.swift b/Sources/Example.swift\n",
        hunks: [
            Hunk(
                id: "abc123",
                path: "Sources/Example.swift",
                oldStart: 1, oldCount: 2, newStart: 1, newCount: 3,
                header: "@@ -1,2 +1,3 @@",
                body: [" line one", "+line two (added)", " line three"]
            ),
        ]
    ))
    .padding()
}
