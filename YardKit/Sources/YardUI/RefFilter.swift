// RefFilter.swift
//
// #0378: the sidebar filter's match rule.

import Foundation

/// #0378: the sidebar filter's match rule.
public nonisolated enum RefFilter {
    /// Case- and diacritic-insensitive substring match on the short ref
    /// name. An empty or all-whitespace query matches everything.
    public static func matches(_ name: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
            || name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
