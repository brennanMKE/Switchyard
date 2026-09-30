// HistorySearchScopeTests.swift
//
// #0524: the History search scopes and the match bar's count. Public API,
// no @testable.

import Foundation
import Testing
import YardGit
import YardUI

@Test("commits are matched in memory; paths and content ask git")
func scopesMapToTheirEngineSearch() {
    #expect(HistorySearchScope.commits.engineKind == nil)
    #expect(HistorySearchScope.paths.engineKind == .path)
    #expect(HistorySearchScope.content.engineKind == .content)
    #expect(HistorySearchScope.allCases.map(\.title) == ["Commits", "Paths", "Content"])
}

@Test("the count says Searching… while git runs, else how many matched")
func summaryCountsMatches() {
    #expect(HistorySearchScope.summary(count: 3, searching: true) == "Searching…")
    #expect(HistorySearchScope.summary(count: 0, searching: false) == "0 matches")
    #expect(HistorySearchScope.summary(count: 1, searching: false) == "1 match")
    #expect(HistorySearchScope.summary(count: 2, searching: false) == "2 matches")
}

@Test("loadHistorySearch returns the matching candidates")
func loadHistorySearchReturnsMatches() async throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("one", files: ["notes.txt": "alpha\n"]),
        .init("two", files: ["other.txt": "bravo\n"]),
    ])
    let one = try #require(repo.oids["one"])
    let two = try #require(repo.oids["two"])

    #expect(try await loadHistorySearch(
        at: repo.url.path, kind: .path, query: "NOTES", candidates: [two, one]) == [one])
    #expect(try await loadHistorySearch(
        at: repo.url.path, kind: .content, query: "bravo", candidates: [two, one]) == [two])
}
