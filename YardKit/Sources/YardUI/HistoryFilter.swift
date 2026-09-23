// HistoryFilter.swift
//
// #0402: which History rows the filter field matches. A commit matches when
// its message (subject or body) contains the query, case- and
// diacritic-insensitively; when a ref chip on it matches the way the sidebar
// matches ref names (`RefFilter`); or when the query is a hex prefix (4+
// characters) of its oid.

import Foundation
import YardGit

public nonisolated enum HistoryFilter {
    /// The trimmed query; empty means the filter is off.
    public static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces)
    }

    public static func matches(_ entry: CommitLogEntry, chips: [RefChip], query: String) -> Bool {
        let q = normalized(query)
        if q.isEmpty { return true }
        if entry.message.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return true
        }
        if chips.contains(where: { RefFilter.matches($0.name, query: q) }) { return true }
        let lower = q.lowercased()
        if lower.count >= 4, lower.allSatisfy(\.isHexDigit), entry.oid.hasPrefix(lower) {
            return true
        }
        return false
    }
}
