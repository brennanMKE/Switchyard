// HistoryIndex.swift
//
// #0552 (umbrella #0551, guide §11 decision 44): what the History pane
// derives from its commits and refs -- each commit's ref chips, the commits
// by oid, and each commit's folded search text -- built once per load
// instead of on every `CommitHistoryView.body`. On git/git (5,000 commits,
// 1,017 refs; measured 2026-09-30, release build) the per-body chip build
// cost 42-46 ms (770 ms in a debug build) and the filter 118-150 ms per
// evaluation, both on the main actor. Built here: 8 ms once, then 1-2 ms
// per filter query.

import Foundation
import YardGit

public nonisolated struct HistoryIndex: Sendable {
    /// Each loaded commit's ref chips: `RefChips.make`'s answer, unchanged.
    public let chipsByOid: [String: [RefChip]]
    /// Each loaded commit by oid (the first, if an oid repeats).
    public let entriesByOid: [String: CommitLogEntry]
    /// The commits' search keys, in History's order.
    private let keys: [HistoryFilter.SearchKey]

    /// No commits.
    public static let empty = HistoryIndex(entries: [], refs: nil)

    /// Indexes `entries` (History's order) against `refs`. `nil` refs (the
    /// sidebar has not loaded, or failed) gives every commit no chips --
    /// what `CommitHistoryView` always did without refs.
    ///
    /// The chips come from `RefChips.make` itself, handed a snapshot holding
    /// only the refs at that commit: grouping the refs by oid once makes the
    /// build O(commits + refs) where calling `make` with every ref was
    /// O(commits x refs).
    public init(entries: [CommitLogEntry], refs: RefSnapshot?) {
        var chips: [String: [RefChip]] = [:]
        if let refs {
            let refsByOid = Dictionary(grouping: refs.refs, by: \.oid)
            for entry in entries where chips[entry.oid] == nil {
                let own = RefSnapshot(head: refs.head, refs: refsByOid[entry.oid] ?? [])
                chips[entry.oid] = RefChips.make(oid: entry.oid, refs: own, decoration: entry.refs)
            }
        }
        chipsByOid = chips
        entriesByOid = Dictionary(entries.map { ($0.oid, $0) }, uniquingKeysWith: { first, _ in first })
        keys = entries.map { HistoryFilter.SearchKey(entry: $0, chips: chips[$0.oid] ?? []) }
    }

    /// The oids of the commits `HistoryFilter.matches` accepts for `query`,
    /// in History's order. Empty when the query is empty after trimming
    /// (the filter is off; `CommitHistoryView` shows no match bar).
    public func matches(query: String) -> [String] {
        guard let folded = HistoryFilter.Query(query) else { return [] }
        return keys.compactMap { $0.matches(folded) ? $0.oid : nil }
    }
}

extension HistoryFilter {
    /// `text` case- and diacritic-folded. A byte substring test on two
    /// folded strings is the filter's match rule.
    nonisolated static func folded(_ text: String) -> [UInt8] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).utf8)
    }

    /// Whether `haystack` contains `needle` as a byte sequence (`memmem(3)`).
    /// An empty needle is contained in everything.
    nonisolated static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        haystack.withUnsafeBytes { text in
            needle.withUnsafeBytes { pattern in
                memmem(text.baseAddress, text.count, pattern.baseAddress, pattern.count) != nil
            }
        }
    }

    /// A trimmed, folded filter query. `nil` for an empty query.
    nonisolated struct Query: Sendable {
        let folded: [UInt8]
        /// The lowercased query when it is 4+ hex digits, else `nil`.
        let hexPrefix: String?

        init?(_ raw: String) {
            let trimmed = HistoryFilter.normalized(raw)
            guard !trimmed.isEmpty else { return nil }
            folded = HistoryFilter.folded(trimmed)
            let lower = trimmed.lowercased()
            hexPrefix = lower.count >= 4 && lower.allSatisfy(\.isHexDigit) ? lower : nil
        }
    }

    /// One commit's folded message, author and chip names.
    nonisolated struct SearchKey: Sendable {
        let oid: String
        let message: [UInt8]
        let author: [UInt8]
        let chipNames: [[UInt8]]

        init(entry: CommitLogEntry, chips: [RefChip]) {
            oid = entry.oid
            message = HistoryFilter.folded(entry.message)
            author = HistoryFilter.folded(entry.author)
            chipNames = chips.map { HistoryFilter.folded($0.name) }
        }

        func matches(_ query: Query) -> Bool {
            HistoryFilter.contains(message, query.folded)
                || HistoryFilter.contains(author, query.folded)
                || chipNames.contains { HistoryFilter.contains($0, query.folded) }
                || query.hexPrefix.map { oid.hasPrefix($0) } == true
        }
    }
}
