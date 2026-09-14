// RepositorySidebarSectionTests.swift
//
// #0371 pins the ref-section behavior that is checkable without hosting the
// view: the current-branch-first ordering (`sortedBranches`), the sections'
// initial expanded/collapsed state, and the rows' help text. Whether
// `Section(_:isExpanded:)` renders a working disclosure on macOS 26 is spike
// #0386's question and is deliberately not asserted here.
//
// Imports YardUI WITHOUT `@testable`, matching this target's idiom: the
// pinned members are `public`, so a member that silently dropped to internal
// would fail to compile here (#0116's failure class) -- this file doubles as
// the compile contract for the #0371 public API on `RepositorySidebarView`.

import Testing
import YardGit
import YardUI

@Test("sortedBranches puts the current branch first, then full-name order")
func sortedBranchesCurrentFirst() {
    let entries = [
        RefSnapshot.Entry(name: "refs/heads/alpha", oid: "a"),
        RefSnapshot.Entry(name: "refs/heads/main", oid: "b"),
        RefSnapshot.Entry(name: "refs/heads/feature", oid: "c"),
    ]
    let names = RepositorySidebarView.sortedBranches(entries, currentBranchName: "main")
        .map(\.name)
    #expect(names == ["refs/heads/main", "refs/heads/alpha", "refs/heads/feature"])
}

@Test("sortedBranches falls back to name order on a detached HEAD")
func sortedBranchesDetachedHeadIsPlainNameOrder() {
    let entries = [
        RefSnapshot.Entry(name: "refs/heads/main", oid: "b"),
        RefSnapshot.Entry(name: "refs/heads/alpha", oid: "a"),
        RefSnapshot.Entry(name: "refs/heads/feature", oid: "c"),
    ]
    let names = RepositorySidebarView.sortedBranches(entries, currentBranchName: nil)
        .map(\.name)
    #expect(names == ["refs/heads/alpha", "refs/heads/feature", "refs/heads/main"])
}

@Test("sortedBranches falls back to name order when the current branch has no ref")
func sortedBranchesDeletedCurrentBranchIsPlainNameOrder() {
    let entries = [
        RefSnapshot.Entry(name: "refs/heads/main", oid: "b"),
        RefSnapshot.Entry(name: "refs/heads/alpha", oid: "a"),
    ]
    let names = RepositorySidebarView.sortedBranches(entries, currentBranchName: "gone")
        .map(\.name)
    #expect(names == ["refs/heads/alpha", "refs/heads/main"])
}

@Test("the ref sections start expanded, collapsed, collapsed")
func refSectionsStartExpandedCollapsedCollapsed() {
    #expect(RepositorySidebarView.branchesStartExpanded == true)
    #expect(RepositorySidebarView.remotesStartExpanded == false)
    #expect(RepositorySidebarView.tagsStartExpanded == false)
}

@Test("help text is the full ref name, not the short display name")
func helpTextIsTheFullRefName() {
    let branch = RefSnapshot.Entry(name: "refs/heads/very-long-branch-name-that-truncates", oid: "a")
    let remote = RefSnapshot.Entry(name: "refs/remotes/origin/very-long-remote-name", oid: "b")
    let tag = RefSnapshot.Entry(name: "refs/tags/v1.0.0-rc1-plus-suffix", oid: "c")
    #expect(RepositorySidebarView.helpText(for: branch) == "refs/heads/very-long-branch-name-that-truncates")
    #expect(RepositorySidebarView.helpText(for: remote) == "refs/remotes/origin/very-long-remote-name")
    #expect(RepositorySidebarView.helpText(for: tag) == "refs/tags/v1.0.0-rc1-plus-suffix")
}
