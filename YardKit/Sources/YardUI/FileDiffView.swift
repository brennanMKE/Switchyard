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
    /// #0444: a button on every hunk's header line — the Changes view's
    /// Stage Hunk / Unstage Hunk. `nil` (every other caller) draws none.
    private let hunkAction: HunkAction?
    /// #0472: a second button, left of `hunkAction` — the Changes view's
    /// Discard Hunk… on an unstaged hunk. `nil` draws none.
    private let discardAction: HunkAction?
    /// #0480: the Changes view's selected lines. Non-nil makes `+` and `-`
    /// lines selectable by click, shift-click, ⌘-click and drag (guide §11
    /// decision 35); `nil` (every other caller) leaves the diff read-only.
    private let lineSelection: Binding<DiffLineSelection>?
    /// #0537: the words that changed inside paired lines, drawn on a
    /// stronger tint (guide §11 decision 42). App-wide, on by default.
    @AppStorage(FileDiffView.highlightsWordChangesKey) private var highlightsWordChanges = true

    /// The `UserDefaults` key for Highlight Changed Words.
    public nonisolated static let highlightsWordChangesKey = "diffHighlightsWordChanges"

    /// One per-hunk button: its title, whether it is enabled, and what it
    /// does with the hunk it sits on.
    public struct HunkAction {
        public let title: String
        /// #0480: the title while lines of this hunk are selected, such as
        /// "Stage Lines"; `nil` keeps `title`.
        public let linesTitle: String?
        public let isEnabled: Bool
        /// The hunk, and its selected lines (indices into `body`) — empty
        /// when none are, which means the whole hunk.
        public let perform: (Hunk, [Int]) -> Void

        public init(
            title: String, linesTitle: String? = nil, isEnabled: Bool,
            perform: @escaping (Hunk, [Int]) -> Void
        ) {
            self.title = title
            self.linesTitle = linesTitle
            self.isEnabled = isEnabled
            self.perform = perform
        }
    }

    public init(
        file: FileDiff, hunkAction: HunkAction? = nil, discardAction: HunkAction? = nil,
        lineSelection: Binding<DiffLineSelection>? = nil
    ) {
        self.file = file
        self.hunkAction = hunkAction
        self.discardAction = discardAction
        self.lineSelection = lineSelection
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
                    HunkView(hunk: hunk, action: hunkAction, discard: discardAction,
                             selection: lineSelection, highlightsWords: highlightsWordChanges)
                }
            }
        }
    }
}

/// One hunk: its `@@` header line, then its body lines.
private struct HunkView: View {
    let hunk: Hunk
    let action: FileDiffView.HunkAction?
    let discard: FileDiffView.HunkAction?
    let selection: Binding<DiffLineSelection>?
    /// #0537: draw the words that changed inside paired lines.
    let highlightsWords: Bool
    /// #0480: where each line sits, for mapping a drag to a line. A class,
    /// so `onGeometryChange` writing it invalidates nothing: only the drag
    /// gesture reads it, never `body`.
    @State private var frames = LineFrames()

    /// The coordinate space line frames and drag locations share.
    private var space: String { "hunk-\(hunk.id)" }

    private var selectedLines: [Int] { selection?.wrappedValue.selectedLines(in: hunk) ?? [] }

    var body: some View {
        // #0537: per hunk, when drawn — measured at most 0.84 ms for a hunk.
        let words = highlightsWords ? IntralineDiff.changes(in: hunk) : [:]
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hunk.header)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    // #0574: the header gives way, not the buttons.
                    .lineLimit(1)
                    .truncationMode(.tail)
                if action != nil || discard != nil { Spacer() }
                if let discard { button(discard) }
                if let action { button(action) }
            }
            .padding(.vertical, 2)
            ForEach(Array(hunk.body.enumerated()), id: \.offset) { offset, line in
                if let selection {
                    DiffLineView(line: line, isSelected: selection.wrappedValue.isSelected(offset, in: hunk),
                                 changes: words[offset] ?? [])
                        .contentShape(Rectangle())
                        .onGeometryChange(for: CGRect.self) { [space] proxy in proxy.frame(in: .named(space)) } action: {
                            frames.rows[offset] = $0
                        }
                        .gesture(clicks(offset, selection))
                } else {
                    DiffLineView(line: line, isSelected: false, changes: words[offset] ?? [])
                }
            }
        }
        .simultaneousGesture(drag, isEnabled: selection != nil)
        .coordinateSpace(.named(space))
        .padding(.bottom, 8)
    }

    /// A header button, titled for the selected lines when this hunk has any.
    private func button(_ action: FileDiffView.HunkAction) -> some View {
        let lines = selectedLines
        return Button(lines.isEmpty ? action.title : action.linesTitle ?? action.title) {
            action.perform(hunk, lines)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
        .disabled(!action.isEnabled)
    }

    /// Shift-click, then ⌘-click, then a plain click: the first whose
    /// modifier is held wins.
    private func clicks(_ offset: Int, _ selection: Binding<DiffLineSelection>) -> some Gesture {
        TapGesture().modifiers(.shift).onEnded { selection.wrappedValue.click(offset, in: hunk, modifier: .shift) }
            .exclusively(before: TapGesture().modifiers(.command).onEnded {
                selection.wrappedValue.click(offset, in: hunk, modifier: .command)
            })
            .exclusively(before: TapGesture().onEnded {
                selection.wrappedValue.click(offset, in: hunk)
            })
    }

    /// A drag over the hunk selects the changed lines between the line it
    /// started on and the line under the pointer. One gesture on the whole
    /// hunk, beside the lines' own tap gestures; a drag shorter than 3
    /// points is left to them as a click.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(space)).onChanged { value in
            guard let selection,
                  let start = frames.line(at: value.startLocation.y),
                  let end = frames.line(at: value.location.y) else { return }
            selection.wrappedValue.drag(from: start, to: end, in: hunk)
        }
    }
}

/// Each body line's frame in its hunk's coordinate space (#0480).
private final class LineFrames {
    var rows: [Int: CGRect] = [:]

    /// The line at `y`: the one whose frame holds it, else the nearest —
    /// a drag past the hunk's first or last line selects up to that line.
    func line(at y: CGFloat) -> Int? {
        if let hit = rows.first(where: { $0.value.minY <= y && y < $0.value.maxY }) { return hit.key }
        return rows.min { abs($0.value.midY - y) < abs($1.value.midY - y) }?.key
    }
}

/// One body line of a hunk. Added and removed lines are visually
/// distinguished by a tinted background keyed on the leading marker git
/// prints (` `, `-`, `+`, or `\` for "No newline at end of file") --
/// `.green`/`.red` are SwiftUI's context-dependent system colors, which
/// adapt to light and dark automatically, not a fixed RGB literal.
struct DiffLineView: View {
    let line: String
    /// #0480: selected in the Changes view; drawn with the accent color.
    let isSelected: Bool
    /// #0537: the words that changed (`IntralineDiff`), drawn on a stronger
    /// tint of the line's own; empty for none.
    var changes: [Range<String.Index>] = []

    private var marker: Unicode.Scalar? { Self.marker(of: line) }

    /// The marker git printed: the line's first *scalar*. A line opening
    /// with a combining mark fuses with its marker into one `Character`, so
    /// `line.first` would be `"+\u{301}"` and the line would go untinted
    /// (#0488).
    nonisolated static func marker(of line: String) -> Unicode.Scalar? {
        line.unicodeScalars.first
    }

    private var backgroundTint: Color {
        if isSelected { return Color.accentColor.opacity(0.35) }
        return switch marker {
        case "+": Color.green.opacity(0.12)
        case "-": Color.red.opacity(0.12)
        default: Color.clear
        }
    }

    /// `line` as drawn: every character of it — the text an accessibility
    /// query finds is the line itself — with `changes` on `tint`.
    nonisolated static func attributed(
        _ line: String, changes: [Range<String.Index>], tint: Color
    ) -> AttributedString {
        var text = AttributedString()
        for segment in IntralineDiff.segments(of: line, changes: changes) {
            var piece = AttributedString(segment.text)
            if segment.isChanged { piece.backgroundColor = tint }
            text += piece
        }
        return text
    }

    /// A changed word's tint: the line's color, three times as strong. A
    /// selected line shows the accent color alone.
    private var wordTint: Color {
        marker == "+" ? Color.green.opacity(0.36) : Color.red.opacity(0.36)
    }

    var body: some View {
        Text(Self.attributed(line, changes: isSelected ? [] : changes, tint: wordTint))
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .background(backgroundTint)
            .foregroundStyle(marker == "\\" ? .secondary : .primary)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
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
