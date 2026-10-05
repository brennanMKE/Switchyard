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

// MARK: - #0577: a merge commit lists what it brought in

@Test("loadCommitDiff lists the merged branch's file for a clean --no-ff merge", arguments: [false, true])
func loadCommitDiffListsTheMergedFileForACleanMerge(diverged: Bool) async throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a", files: ["README.md": "readme\n"])])
    try repo.branch("docs2")
    try repo.checkout("docs2")
    try repo.build([.init("d", files: ["docs.md": "docs\n"])])
    try repo.checkout("main")
    if diverged { try repo.build([.init("m", files: ["main.txt": "main\n"])]) }
    _ = try Merge.run(branch: "docs2", intent: .noFastForward, at: repo.url.path)
    let merge = try repo.revParse("HEAD")

    let files = try await loadCommitDiff(at: repo.url.path, revision: merge)

    #expect(files.map(\.path) == ["docs.md"])
}

@Test("A merge's file list carries the first-parent caption; other commits carry none")
func diffCaptionNamesTheFirstParentOnlyForAMerge() {
    #expect(CommitDetailView.diffCaption(parentCount: 2)
        == "Compared with the first parent: what this merge brought in")
    #expect(CommitDetailView.diffCaption(parentCount: 3) != nil)
    #expect(CommitDetailView.diffCaption(parentCount: 1) == nil)
    #expect(CommitDetailView.diffCaption(parentCount: 0) == nil)
}
