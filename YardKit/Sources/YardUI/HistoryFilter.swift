// HistoryFilter.swift
//
// #0402: which History rows the filter field matches. A commit matches when
// its message (subject or body) or (#0523) its author contains the query,
// case- and diacritic-insensitively; when a ref chip on it matches the way the sidebar
// matches ref names (`RefFilter`); or when the query is a hex prefix (4+
// characters) of its oid.

import Foundation
import YardGit

public nonisolated enum HistoryFilter {
    /// The trimmed query; empty means the filter is off.
    public static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// #0552: one commit against `query`, by the same rule
    /// `HistoryIndex.matches(query:)` applies to every loaded commit.
    public static func matches(_ entry: CommitLogEntry, chips: [RefChip], query: String) -> Bool {
        guard let folded = Query(query) else { return true }
        return SearchKey(entry: entry, chips: chips).matches(folded)
    }
}
