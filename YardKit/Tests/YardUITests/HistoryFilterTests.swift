// HistoryFilterTests.swift
//
// #0402: the History filter's match rule. Public API, no @testable.

import Testing
import YardGit
import YardUI

private func entry(_ message: String, oid: String = "abcdef0123456789abcdef0123456789abcdef01") -> CommitLogEntry {
    CommitLogEntry(oid: oid, parents: [], author: "A", refs: "",
                   signatureStatus: .noSig, message: message, trailers: [])
}

@Test("an empty or blank query matches every commit")
func blankQueryMatchesEverything() {
    #expect(HistoryFilter.matches(entry("anything"), chips: [], query: ""))
    #expect(HistoryFilter.matches(entry("anything"), chips: [], query: "   "))
}

@Test("a query matches the subject case-insensitively, including a leading #")
func queryMatchesSubject() {
    let e = entry("#0337 Add per-Session pane focus history\n\nbody")
    #expect(HistoryFilter.matches(e, chips: [], query: "#0337"))
    #expect(HistoryFilter.matches(e, chips: [], query: "337"))
    #expect(HistoryFilter.matches(e, chips: [], query: "PANE FOCUS"))
}

@Test("a query matches the body, not only the subject")
func queryMatchesBody() {
    #expect(HistoryFilter.matches(entry("subject\n\nthe clipboard policy"), chips: [], query: "clipboard"))
}

@Test("a query matches a ref chip's name")
func queryMatchesChip() {
    let chip = RefChip(name: "feature/0337", kind: .localBranch, isHead: false)
    #expect(HistoryFilter.matches(entry("unrelated"), chips: [chip], query: "0337"))
}

@Test("a hex query of four or more characters matches an oid prefix")
func hexQueryMatchesOidPrefix() {
    #expect(HistoryFilter.matches(entry("x"), chips: [], query: "abcd"))
    #expect(!HistoryFilter.matches(entry("x"), chips: [], query: "abc"))
    #expect(!HistoryFilter.matches(entry("x"), chips: [], query: "bcde"))
}

@Test("a query that matches nothing does not match")
func nonMatchingHistoryQueryDoesNotMatch() {
    #expect(!HistoryFilter.matches(entry("Fix the build"), chips: [], query: "clipboard"))
}
