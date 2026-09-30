// CommitMessageGuide.swift
//
// #0563: the line under the Changes view's message editor (guide §11
// decision 45). The editor's first line is the subject; the guide counts it
// against 50, says when line 2 is not blank (git would fold it into the
// subject), and counts body lines over 72. It warns and never blocks: the
// Commit button does not read it.

import Foundation

/// What the guide line says about one message. `nonisolated` for the reason
/// `WorkingChanges` gives: a plain value type in a MainActor-default target.
public nonisolated struct CommitMessageGuide: Equatable, Sendable {
    /// The subject length a log reads best at.
    public static let subjectLimit = 50
    /// The body width `git log` and email patches read best at.
    public static let bodyLimit = 72

    /// The first line's length in characters (grapheme clusters, so `é` and
    /// an emoji count once, as a reader sees them).
    public let subjectLength: Int
    /// Line 2 holds text. `git log --format=%s` joins the first paragraph
    /// into the subject, so the body never starts where the user meant.
    public let secondLineHasText: Bool
    /// Body lines (line 3 on) longer than `bodyLimit`, not counting lines
    /// with no space (a URL or a path cannot wrap) or trailers
    /// (`Co-authored-by: …`, which git does not wrap either).
    public let longBodyLines: Int

    public init(message: String) {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        subjectLength = lines.first?.count ?? 0
        secondLineHasText = lines.count > 1
            && !lines[1].trimmingCharacters(in: .whitespaces).isEmpty
        longBodyLines = lines.dropFirst(2).filter { line in
            line.count > Self.bodyLimit && line.contains(" ") && !Self.isTrailer(line)
        }.count
    }

    /// Whether any part of the guide is a warning: the line turns orange.
    public var isWarning: Bool {
        subjectLength > Self.subjectLimit || secondLineHasText || longBodyLines > 0
    }

    /// The guide line: `Subject 42/50`, then each warning.
    public var summary: String {
        var parts = ["Subject \(subjectLength)/\(Self.subjectLimit)"]
        if secondLineHasText { parts.append("Leave line 2 blank") }
        if longBodyLines == 1 {
            parts.append("1 body line over \(Self.bodyLimit)")
        } else if longBodyLines > 1 {
            parts.append("\(longBodyLines) body lines over \(Self.bodyLimit)")
        }
        return parts.joined(separator: " · ")
    }

    /// `Token: value`, the token letters, digits and hyphens.
    static func isTrailer(_ line: Substring) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let token = line[..<colon]
        return !token.isEmpty
            && token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            && line[colon...].hasPrefix(": ")
    }
}
