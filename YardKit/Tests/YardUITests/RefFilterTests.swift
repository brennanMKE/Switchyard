// RefFilterTests.swift
//
// #0378 pins the sidebar filter's match rule: the five results measured in
// the issue, plus the sidebar's short-name filtering seam (`filtered`) that
// applies the rule to ref entries.
//
// Imports YardUI WITHOUT `@testable`, matching this target's idiom: the
// pinned members are `public`, so a member that silently dropped to internal
// would fail to compile here (see RepositorySidebarSectionTests.swift).

import Testing
import YardGit
import YardUI

@Test("an empty query matches everything")
func emptyQueryMatchesEverything() {
    #expect(RefFilter.matches("issue/0404", query: "") == true)
}

@Test("an all-whitespace query matches everything")
func whitespaceQueryMatchesEverything() {
    #expect(RefFilter.matches("issue/0404", query: "  ") == true)
}

@Test("matching is case-insensitive")
func matchingIsCaseInsensitive() {
    #expect(RefFilter.matches("Issue/0404", query: "issue/04") == true)
}

@Test("matching is diacritic-insensitive")
func matchingIsDiacriticInsensitive() {
    #expect(RefFilter.matches("naïve", query: "naive") == true)
}

@Test("a non-matching query does not match")
func nonMatchingQueryDoesNotMatch() {
    #expect(RefFilter.matches("main", query: "feat") == false)
}

@Test("the sidebar filter matches the short ref name, not the full ref name")
func sidebarFilterMatchesShortName() {
    let heads = [
        RefSnapshot.Entry(name: "refs/heads/Issue/0404", oid: "a"),
        RefSnapshot.Entry(name: "refs/heads/main", oid: "b"),
    ]
    let remotes = [
        RefSnapshot.Entry(name: "refs/remotes/origin/Issue/0404", oid: "c"),
        RefSnapshot.Entry(name: "refs/remotes/origin/main", oid: "d"),
    ]
    let branchNames = RepositorySidebarView.filtered(
        heads, prefix: "refs/heads/", query: "issue/04"
    ).map(\.name)
    #expect(branchNames == ["refs/heads/Issue/0404"])
    let remoteNames = RepositorySidebarView.filtered(
        remotes, prefix: "refs/remotes/", query: "issue/04"
    ).map(\.name)
    #expect(remoteNames == ["refs/remotes/origin/Issue/0404"])
}

@Test("an insignificant query returns every entry unchanged")
func insignificantQueryReturnsEveryEntry() {
    let entries = [
        RefSnapshot.Entry(name: "refs/heads/alpha", oid: "a"),
        RefSnapshot.Entry(name: "refs/heads/main", oid: "b"),
    ]
    let names = RepositorySidebarView.filtered(
        entries, prefix: "refs/heads/", query: "  "
    ).map(\.name)
    #expect(names == ["refs/heads/alpha", "refs/heads/main"])
}

@Test("filtering keeps the current branch first among the matches")
func filteringKeepsCurrentBranchFirstAmongMatches() {
    let entries = [
        RefSnapshot.Entry(name: "refs/heads/alpha", oid: "a"),
        RefSnapshot.Entry(name: "refs/heads/main", oid: "b"),
        RefSnapshot.Entry(name: "refs/heads/alpha2", oid: "c"),
    ]
    let sorted = RepositorySidebarView.sortedBranches(entries, currentBranchName: "alpha2")
    let names = RepositorySidebarView.filtered(
        sorted, prefix: "refs/heads/", query: "alpha"
    ).map(\.name)
    #expect(names == ["refs/heads/alpha2", "refs/heads/alpha"])
}
