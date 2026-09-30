// HistoryIndexTests.swift
//
// #0552 (guide §11 decision 44): `HistoryIndex` answers what
// `CommitHistoryView.body` used to compute per render -- the same chips
// `RefChips.make` gives with every ref, and the same matches as
// `HistoryFilter.matches` -- in History's order. Public API, no @testable.

import Testing
import YardGit
import YardUI

private let oidA = "aaaa000000000000000000000000000000000001"
private let oidB = "bbbb000000000000000000000000000000000002"
private let oidC = "cccc000000000000000000000000000000000003"

private func commit(
    _ oid: String, _ message: String, author: String = "Ada", refs: String = ""
) -> CommitLogEntry {
    CommitLogEntry(oid: oid, parents: [], author: author, refs: refs,
                   signatureStatus: .noSig, message: message, trailers: [])
}

/// B is HEAD's branch `main` with `topic` and `origin/main` beside it and a
/// tag in its decoration; A has only `origin/feature`; C has no refs. Two
/// refs point at a commit History did not load.
private let entries = [
    commit(oidB, "Second commit", refs: "HEAD -> main, origin/main, topic, tag: v1.0"),
    commit(oidA, "First commit", author: "Zoë Fixture"),
    commit(oidC, "Straße renamed"),
]
private let refs = RefSnapshot(head: .symbolic(target: "refs/heads/main"), refs: [
    .init(name: "refs/heads/main", oid: oidB),
    .init(name: "refs/heads/topic", oid: oidB),
    .init(name: "refs/remotes/origin/main", oid: oidB),
    .init(name: "refs/remotes/origin/HEAD", oid: oidB),
    .init(name: "refs/remotes/origin/feature", oid: oidA),
    .init(name: "refs/heads/elsewhere", oid: "dddd000000000000000000000000000000000004"),
    .init(name: "refs/tags/v1.0", oid: "eeee000000000000000000000000000000000005"),
])

@Test("chips are RefChips.make's, with every ref, for every loaded commit")
func historyIndexChipsMatchRefChips() {
    let index = HistoryIndex(entries: entries, refs: refs)
    for entry in entries {
        #expect(index.chipsByOid[entry.oid]
            == RefChips.make(oid: entry.oid, refs: refs, decoration: entry.refs))
    }
    // Not only equal to `make`: the actual chips, so an empty answer on
    // both sides cannot pass.
    #expect(index.chipsByOid[oidB]?.map(\.name) == ["main", "topic", "origin/main", "v1.0"])
    #expect(index.chipsByOid[oidA]?.map(\.name) == ["origin/feature"])
    #expect(index.chipsByOid[oidC] == [])
}

@Test("without refs no commit has chips")
func historyIndexWithoutRefsHasNoChips() {
    let index = HistoryIndex(entries: entries, refs: nil)
    #expect(index.chipsByOid.isEmpty)
    #expect(index.entriesByOid.count == 3)
}

@Test("entriesByOid holds every loaded commit by oid")
func historyIndexEntriesByOid() {
    let index = HistoryIndex(entries: entries, refs: refs)
    #expect(index.entriesByOid[oidA]?.message == "First commit")
    #expect(index.entriesByOid[oidC]?.message == "Straße renamed")
    #expect(HistoryIndex.empty.entriesByOid.isEmpty)
}

@Test("matches are HistoryFilter.matches's, in History's order")
func historyIndexMatchesFollowTheFilter() {
    let index = HistoryIndex(entries: entries, refs: refs)
    #expect(index.matches(query: "commit") == [oidB, oidA])
    #expect(index.matches(query: "ZOE") == [oidA])
    #expect(index.matches(query: "feature") == [oidA])
    #expect(index.matches(query: "v1.0") == [oidB])
    #expect(index.matches(query: "CCCC") == [oidC])
    #expect(index.matches(query: "nothing like it").isEmpty)
    for query in ["commit", "ZOE", "feature", "v1.0", "cccc", "ccc", "strasse", "main"] {
        let filtered = entries.filter { entry in
            HistoryFilter.matches(entry, chips: index.chipsByOid[entry.oid] ?? [], query: query)
        }.map(\.oid)
        #expect(index.matches(query: query) == filtered, "query \(query)")
    }
}

@Test("a blank query matches nothing in the index: the filter is off")
func historyIndexBlankQuery() {
    let index = HistoryIndex(entries: entries, refs: refs)
    #expect(index.matches(query: "").isEmpty)
    #expect(index.matches(query: "   ").isEmpty)
}

@Test("folding expands ß to ss, and a lone ß no longer matches every s")
func historyFilterFoldsSharpS() {
    #expect(HistoryFilter.matches(entries[2], chips: [], query: "STRASSE"))
    #expect(!HistoryFilter.matches(commit(oidA, "Signed-off-by: A"), chips: [], query: "ß"))
}
