// CommitDiffLoaderTests.swift
//
// `loadCommitDiff` is `public`, so this target imports both `YardUI` and
// `YardGit` WITHOUT `@testable`, matching `CommitHistoryLoaderTests` and
// `RepositoryLoaderTests` — a public loader whose caller-visible members
// silently dropped to internal would still compile under `@testable`
// (#0116's failure class).

import Foundation
import Testing
import YardGit
import YardUI

@Test("loadCommitDiff returns the changed file's path and hunk count for a fixture commit")
func loadCommitDiffReturnsPathAndHunkCount() async throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    try repo.build([.init("b", parents: ["a"])])
    let commit = try #require(repo.oids["b"])

    let files = try await loadCommitDiff(at: repo.url.path, revision: commit)

    // `FixtureRepository.Commit.init` defaults `files` to a single
    // `"<name>.txt"` entry when none is given, so commit "b" adds exactly
    // "b.txt" against parent "a", which never had it -- one file, one hunk
    // (an add, not an edit). Asserting the path and count, not merely
    // non-empty, is what pins this against a loader that silently returns
    // the wrong file or drops hunks.
    #expect(files.map(\.path) == ["b.txt"])
    let file = try #require(files.first)
    #expect(file.hunks.count == 1)
}
