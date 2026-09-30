// DiffViewOptions.swift
//
// #0538: the diff options a diff view is drawn with (guide §11 decision
// 42) — Ignore Whitespace and Context, per view and not persisted, plus
// the app-wide Highlight Changed Words — and the bar that holds their menu.
// The Changes view (#0539), the commit changes window (#0540) and the
// stash detail pane (#0541) each own one `DiffViewOptions` in `@State`.

import SwiftUI
import YardGit

/// How many lines of context a diff shows.
public nonisolated enum DiffContext: Int, CaseIterable, Identifiable, Sendable {
    /// git's own three, which staging acts on.
    case standard = 3
    case ten = 10
    /// Every line of the file: one hunk per file.
    case wholeFile = 2147483647

    public var id: Int { rawValue }

    /// The menu item.
    public var title: String {
        switch self {
        case .standard: "3 Lines of Context"
        case .ten: "10 Lines of Context"
        case .wholeFile: "Whole File"
        }
    }
}

/// Ignore Whitespace and Context for one diff view.
///
/// `nonisolated` for the reason `DiffLineSelection` gives: a plain value
/// type in a `.defaultIsolation(MainActor.self)` target.
public nonisolated struct DiffViewOptions: Equatable, Hashable, Sendable {
    public var ignoresWhitespace: Bool
    public var context: DiffContext

    public init(ignoresWhitespace: Bool = false, context: DiffContext = .standard) {
        self.ignoresWhitespace = ignoresWhitespace
        self.context = context
    }

    /// What git is asked for.
    public var diffOptions: DiffOptions {
        DiffOptions(ignoresWhitespace: ignoresWhitespace, contextLines: context.rawValue)
    }

    /// Whether the diff is the one staging acts on: whitespace shown, three
    /// lines of context. Hunk and line actions need it (decision 42).
    public var isStandard: Bool { diffOptions.isStandard }

    /// What the bar says is different, or `nil` when nothing is.
    public var summary: String? {
        var parts: [String] = []
        if ignoresWhitespace { parts.append("Whitespace ignored") }
        switch context {
        case .standard: break
        case .ten: parts.append("10 lines of context")
        case .wholeFile: parts.append("Whole file")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What to draw for `file`, one file of the listing drawn with the
    /// standard options: its counterpart in `shown`, the listing drawn with
    /// these options, or `file` itself while `shown` is `nil` (standard
    /// options, or not loaded yet). `nil` when `shown` has no file at its
    /// path: `-w` leaves out a file whose every change is whitespace.
    public static func file(_ file: FileDiff, in shown: [FileDiff]?) -> FileDiff? {
        guard let shown else { return file }
        return shown.first { $0.path == file.path }
    }

    /// The line a file with nothing left to show gets in place of its diff.
    public static func whitespaceOnlyNote(for path: String) -> String {
        "Only whitespace changed in \(path)"
    }
}

/// The row above a diff: what the options change, and the Diff Options
/// menu. `stagingNote` adds the Changes view's sentence that hunk and line
/// actions are off, and its Reset button.
struct DiffOptionsBar: View {
    @Binding var options: DiffViewOptions
    var stagingNote = false
    @AppStorage(FileDiffView.highlightsWordChangesKey) private var highlightsWordChanges = true

    var body: some View {
        HStack(spacing: 8) {
            if let summary = options.summary {
                Label(summary, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("diff-options-summary")
                if stagingNote {
                    Text("Hunks and lines can’t be staged or discarded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("diff-options-staging-note")
                    Button("Reset") { options = DiffViewOptions() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityIdentifier("diff-options-reset")
                }
            }
            Spacer()
            Menu {
                Toggle("Ignore Whitespace", isOn: $options.ignoresWhitespace)
                Toggle("Highlight Changed Words", isOn: $highlightsWordChanges)
                Divider()
                Picker("Context", selection: $options.context) {
                    ForEach(DiffContext.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Diff Options", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Ignore whitespace, highlight changed words, choose the context")
            .accessibilityIdentifier("diff-options")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// A file whose every change the options hid: its path and a note, where
/// `FileDiffView` would draw its hunks.
struct WhitespaceOnlyFileView: View {
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(path)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .textSelection(.enabled)
            Text(DiffViewOptions.whitespaceOnlyNote(for: path))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
