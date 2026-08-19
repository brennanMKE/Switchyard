// RepositorySidebarLoaderTests.swift
//
// `loadRepositorySidebar` is `public`, so this target imports both `YardUI`
// and `YardGit` WITHOUT `@testable`, matching `RepositoryLoaderTests` and
// `CommitHistoryLoaderTests` -- a public loader whose caller-visible members
// silently dropped to internal would still compile under `@testable`
// (#0116's failure class).

import Foundation
import Testing
import YardGit
import YardKit
import YardUI

@Test("loadRepositorySidebar returns the branch and tag by name and excludes a real journal anchor ref")
func loadRepositorySidebarExcludesJournalAnchor() async throws {
    var repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    try repo.branch("feature", at: "b")

    let git = GitProcess()
    try git.run(["tag", "v1.0", repo.oids["c"]!], workingDirectory: repo.url.path)

    // `RefSnapshot.capture` already filters `refs/switchyard/`
    // (`RefSnapshot.swift:166`) -- this writes a real anchor ref and asserts
    // it does not come back, rather than trusting that filter silently
    // (issue 0081's explicit instruction). `ServiceNames.journalRefPrefix`
    // rather than the literal string: `ServiceNamesTests.
    // noOtherSwiftSourceHardcodesTheIdentifiers` forbids hardcoding it
    // anywhere outside `ServiceNames.swift`.
    try git.run(["update-ref", "\(ServiceNames.journalRefPrefix)anchor-test", repo.oids["c"]!],
                workingDirectory: repo.url.path)

    let sidebar = try await loadRepositorySidebar(at: repo.url.path)

    let refNames = sidebar.refs.refs.map(\.name)
    #expect(refNames.contains("refs/heads/main"))
    #expect(refNames.contains("refs/heads/feature"))
    #expect(refNames.contains("refs/tags/v1.0"))
    #expect(!refNames.contains { $0.hasPrefix("refs/switchyard/") })

    if case let .symbolic(target) = sidebar.refs.head {
        #expect(target == "refs/heads/main")
    } else {
        Issue.record("expected HEAD to be symbolic on a fresh checkout of main")
    }

    // `FixtureRepository.url` is already `realpath(3)`-resolved
    // (`FixtureRepository.swift`'s init comment), so it compares equal to
    // `currentWorktreePath` -- itself resolved the same way via
    // `WorktreeContext.topLevel` -- without any extra canonicalization here.
    #expect(sidebar.currentWorktreePath == repo.url.path)
}
