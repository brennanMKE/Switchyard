// HistorySearchScope.swift
//
// #0524 (umbrella #0521): what the History filter's text is matched
// against, guide §11 decision 40. `.commits` is #0402's in-memory match
// (message, author, ref names, oid prefix); `.paths` and `.content` ask git
// (`HistorySearch`) about the commits History has loaded.

import Foundation
import YardGit

public nonisolated enum HistorySearchScope: String, CaseIterable, Identifiable, Sendable {
    case commits
    case paths
    case content

    public var id: String { rawValue }

    /// The segment's title.
    public var title: String {
        switch self {
        case .commits: "Commits"
        case .paths: "Paths"
        case .content: "Content"
        }
    }

    /// The segment's tooltip.
    public var help: String {
        switch self {
        case .commits: "Match commit messages, authors, branch and tag names, and commit IDs"
        case .paths: "Match commits that changed a file whose path contains the text"
        case .content: "Match commits that added or removed the text"
        }
    }

    /// The search git runs for this scope; `nil` for `.commits`, which is
    /// matched in memory by `HistoryFilter`.
    public var engineKind: HistorySearch.Kind? {
        switch self {
        case .commits: nil
        case .paths: .path
        case .content: .content
        }
    }

    /// The match bar's count: "Searching…" while git runs, else "N matches".
    public static func summary(count: Int, searching: Bool) -> String {
        if searching { return "Searching…" }
        return count == 1 ? "1 match" : "\(count) matches"
    }
}

/// Which of `candidates` match `query` in `kind`, in `candidates`' order.
/// `@concurrent` keeps `git log` off the main actor, as `loadFileHistory`
/// does; cancelling the calling task terminates `git`.
@concurrent
public func loadHistorySearch(
    at path: String, kind: HistorySearch.Kind, query: String, candidates: [String]
) async throws -> [String] {
    try await HistorySearch.run(kind: kind, query: query, candidates: candidates, at: path)
}
