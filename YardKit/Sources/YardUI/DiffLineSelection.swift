// DiffLineSelection.swift
//
// #0479: which changed lines of the Changes view's diff are selected (guide
// §11 decision 35). A pure value, so DiffLineSelectionTests reach every
// click rule without a view; `WorkingChangesView` owns one in `@State` and
// `FileDiffView` edits it through a binding.

import YardGit

/// The selected lines of one hunk. A selection never spans hunks: a click
/// in another hunk starts a new one. Only `+` and `-` lines can be
/// selected — context lines and `\ No newline at end of file` markers are
/// part of every patch already.
///
/// `nonisolated` for the reason `WorkingChanges` gives: a plain value type
/// in a `.defaultIsolation(MainActor.self)` target.
public nonisolated struct DiffLineSelection: Equatable, Sendable {

    /// How a click was modified.
    public enum Modifier: Sendable {
        case none, shift, command
    }

    /// The hunk the selected lines belong to; `nil` when none are selected.
    public private(set) var hunkID: String?
    /// Indices into that hunk's `body`.
    public private(set) var lines: Set<Int> = []
    /// Where a shift-click extends from: the last line clicked, or where a
    /// drag started.
    private var anchor: Int?

    public init() {}

    /// Whether `line` of `hunk` can be selected: a `+` or `-` line.
    public static func isSelectable(_ line: Int, in hunk: Hunk) -> Bool {
        guard hunk.body.indices.contains(line) else { return false }
        // The first *scalar*: a line opening with a combining mark fuses
        // with its marker into one `Character` (#0488).
        let marker = hunk.body[line].unicodeScalars.first
        return marker == "+" || marker == "-"
    }

    /// Whether `line` of `hunk` is selected.
    public func isSelected(_ line: Int, in hunk: Hunk) -> Bool {
        hunkID == hunk.id && lines.contains(line)
    }

    /// The selected lines of `hunk` in body order, what the engine's
    /// `stageLines` takes; empty when the selection is in another hunk.
    public func selectedLines(in hunk: Hunk) -> [Int] {
        hunkID == hunk.id ? lines.sorted() : []
    }

    /// A click on `line` of `hunk`.
    ///
    /// - A plain click selects that line alone. Clicking the only selected
    ///   line, or a line that cannot be selected, clears the selection.
    /// - Shift-click selects every changed line from the anchor to `line`,
    ///   when the anchor is in the same hunk; otherwise it is a plain click.
    /// - ⌘-click adds or removes `line`, in the same hunk; otherwise it is a
    ///   plain click.
    public mutating func click(_ line: Int, in hunk: Hunk, modifier: Modifier = .none) {
        let sameHunk = hunkID == hunk.id
        guard Self.isSelectable(line, in: hunk) else {
            if modifier == .none { self = DiffLineSelection() }
            return
        }
        if modifier == .shift, sameHunk, let anchor {
            lines = Self.changedLines(from: anchor, to: line, in: hunk)
            return
        }
        if modifier == .command, sameHunk {
            if lines.remove(line) == nil { lines.insert(line) }
            anchor = line
            if lines.isEmpty { self = DiffLineSelection() }
            return
        }
        if sameHunk, lines == [line] {
            self = DiffLineSelection()
            return
        }
        hunkID = hunk.id
        lines = [line]
        anchor = line
    }

    /// A drag from `start` to `end`, both body indices of `hunk`: selects
    /// every changed line between them, inclusive, replacing any selection.
    /// A drag over context alone changes nothing.
    public mutating func drag(from start: Int, to end: Int, in hunk: Hunk) {
        let range = Self.changedLines(from: start, to: end, in: hunk)
        guard !range.isEmpty else { return }
        hunkID = hunk.id
        lines = range
        anchor = start
    }

    /// Every selectable line between `a` and `b`, inclusive, either order.
    private static func changedLines(from a: Int, to b: Int, in hunk: Hunk) -> Set<Int> {
        Set((min(a, b)...max(a, b)).filter { isSelectable($0, in: hunk) })
    }
}
