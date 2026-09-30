// IntralineDiff.swift
//
// #0536: the words that changed inside a hunk's changed lines (guide §11
// decision 42). Computed in the app from the hunk's own body, not asked of
// git (`--word-diff=porcelain` is a second output format with no hunk
// bodies to stage from): a drawing aid only, so staging never sees it.
// Measured on git/git (`HEAD~300..HEAD`, 139,492 body lines, 6,998 hunks,
// release build): 0.108 s for every hunk, the slowest hunk 0.84 ms.

import YardGit

/// Word-level changes inside a hunk's paired `-`/`+` lines.
///
/// `nonisolated` for the reason `DiffLineSelection` gives: pure values in a
/// `.defaultIsolation(MainActor.self)` target.
public nonisolated enum IntralineDiff {

    /// A line longer than this many `Character`s is not compared: a
    /// minified or generated line is quadratic to diff and unreadable
    /// highlighted.
    static let maximumLineLength = 500

    /// One piece of a line, for drawing: changed or not.
    public struct Segment: Equatable, Sendable {
        public let text: Substring
        public let isChanged: Bool
    }

    /// The changed ranges of each paired line of `body`, keyed by index
    /// into `body`. A run of `-` lines followed directly by a run of `+`
    /// lines **of the same length** is paired line by line; no other line
    /// has an entry — a run of three lines replaced by two is a rewrite,
    /// and pairing it guesses. A pair with less than half its text in
    /// common has no entry either, so a rewritten line is not striped.
    /// Ranges are in the line's own `String` indices and never include the
    /// marker.
    public static func changes(in body: [String]) -> [Int: [Range<String.Index>]] {
        var result: [Int: [Range<String.Index>]] = [:]
        var index = 0
        while index < body.count {
            guard marker(of: body[index]) == "-" else {
                index += 1
                continue
            }
            let removedStart = index
            while index < body.count, marker(of: body[index]) == "-" { index += 1 }
            let addedStart = index
            while index < body.count, marker(of: body[index]) == "+" { index += 1 }
            let count = addedStart - removedStart
            guard index - addedStart == count else { continue }
            for offset in 0..<count {
                let old = removedStart + offset
                let new = addedStart + offset
                guard let (removed, inserted) = compare(body[old], body[new]) else { continue }
                if !removed.isEmpty { result[old] = removed }
                if !inserted.isEmpty { result[new] = inserted }
            }
        }
        return result
    }

    /// `changes(in: hunk.body)`, or none for a combined (`@@@`) hunk: its
    /// lines carry one marker column per parent, so `- ours` and
    /// `++resolved` are not a removed line and its replacement.
    public static func changes(in hunk: Hunk) -> [Int: [Range<String.Index>]] {
        hunk.header.hasPrefix("@@@") ? [:] : changes(in: hunk.body)
    }

    /// The ranges of `old` that `new` removed and of `new` that it
    /// inserted, token by token; `nil` when either line is longer than
    /// `maximumLineLength` or the two share less than half their text.
    static func compare(
        _ old: String, _ new: String
    ) -> (removed: [Range<String.Index>], inserted: [Range<String.Index>])? {
        guard old.count <= maximumLineLength, new.count <= maximumLineLength else { return nil }
        let oldTokens = tokens(of: old)
        let newTokens = tokens(of: new)
        var removed: [Range<String.Index>] = []
        var inserted: [Range<String.Index>] = []
        var changed = 0
        for change in newTokens.difference(from: oldTokens) {
            switch change {
            case let .remove(_, token, _):
                append(token.startIndex..<token.endIndex, to: &removed)
                changed += token.count
            case let .insert(_, token, _):
                append(token.startIndex..<token.endIndex, to: &inserted)
                changed += token.count
            }
        }
        let total = oldTokens.reduce(0) { $0 + $1.count } + newTokens.reduce(0) { $0 + $1.count }
        guard changed * 2 <= total else { return nil }
        return (removed, inserted)
    }

    /// `line` after its marker, as tokens: runs of letters, digits and `_`,
    /// runs of whitespace, and single other characters. The marker is the
    /// first *scalar* (#0488): a line opening with a combining mark keeps
    /// that mark as its first token.
    static func tokens(of line: String) -> [Substring] {
        let scalars = line.unicodeScalars
        guard let first = scalars.indices.first else { return [] }
        let content = line[scalars.index(after: first)...]
        var tokens: [Substring] = []
        var start = content.startIndex
        var kind: Int?
        var index = content.startIndex
        while index < content.endIndex {
            let character = content[index]
            let next = character.isLetter || character.isNumber || character == "_" ? 0
                : character.isWhitespace ? 1 : 2
            if let kind, kind != next || next == 2 {
                tokens.append(content[start..<index])
                start = index
            }
            kind = next
            index = content.index(after: index)
        }
        if start < content.endIndex { tokens.append(content[start...]) }
        return tokens
    }

    /// `line` cut at the bounds of `changes` (ascending, not overlapping,
    /// as `changes(in:)` gives them), for drawing.
    public static func segments(of line: String, changes: [Range<String.Index>]) -> [Segment] {
        var segments: [Segment] = []
        var position = line.startIndex
        for range in changes {
            if position < range.lowerBound {
                segments.append(Segment(text: line[position..<range.lowerBound], isChanged: false))
            }
            segments.append(Segment(text: line[range], isChanged: true))
            position = range.upperBound
        }
        if position < line.endIndex {
            segments.append(Segment(text: line[position...], isChanged: false))
        }
        return segments
    }

    /// Joins `range` onto the last range when the two touch.
    private static func append(_ range: Range<String.Index>, to ranges: inout [Range<String.Index>]) {
        if let last = ranges.last, last.upperBound == range.lowerBound {
            ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
        } else {
            ranges.append(range)
        }
    }

    private static func marker(of line: String) -> Unicode.Scalar? { line.unicodeScalars.first }
}
