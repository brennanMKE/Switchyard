// CommitStagedTests.swift — commit the index as it stands, journaled (#0440)
//
// NO SIGNING KEY IS CREATED OR USED ANYWHERE IN THIS FILE. Every commit is
// unsigned, through the hermetic environment CommitHunksTests uses.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

/// One commit holding `a.txt`, then `a.txt` modified and staged.
private func stagedRepo(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    try repo.writeUntracked(["a.txt": "one\ntwo\n"])
    try GitProcess().run(["add", "a.txt"], workingDirectory: repo.url.path)
    return repo
}

/// Installs an executable `pre-commit` hook into the directory git resolves
/// for hooks — `rev-parse --git-path hooks`, never a path built onto `.git/`.
private func installPreCommit(_ script: String, in repo: FixtureRepository) throws {
    let hooks = try GitProcess().run(
        ["rev-parse", "--path-format=absolute", "--git-path", "hooks"],
        workingDirectory: repo.url.path
    ).lines.first ?? ""
    try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
    let hook = URL(fileURLWithPath: hooks).appendingPathComponent("pre-commit")
    try script.write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func commitStagedCommitsTheIndexAndReturnsTheNewHead(format: FixtureRepository.RefFormat) throws {
    let repo = try stagedRepo(format)
    defer { repo.destroy() }
    let before = try repo.revParse("HEAD")

    let result = try commitStaged(message: "second", at: repo.url.path, extraEnvironment: hermetic)

    #expect(result.oid == (try repo.revParse("HEAD")))
    #expect(result.oid != before)
    #expect(try repo.revParse("HEAD~1") == before)
    let shown = try GitProcess().run(["show", "HEAD:a.txt"], workingDirectory: repo.url.path).text
    #expect(shown == "one\ntwo\n")
    #expect(try gitStatus(at: repo.url.path).entries.isEmpty)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func commitStagedWritesOneEntryAndUndoRestoresBranchAndIndex(
    format: FixtureRepository.RefFormat
) throws {
    let repo = try stagedRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let head = try repo.revParse("HEAD")
    let entriesBefore = try JournalAnchor.list(in: ctx).count

    _ = try commitStaged(message: "second", at: repo.url.path, extraEnvironment: hermetic)
    let entries = try JournalAnchor.list(in: ctx)
    #expect(entries.count == entriesBefore + 1)
    let metadata = try JournalList.list(in: ctx).items.last?.metadata
    #expect(metadata?.operation == "commit")

    try JournalUndo.undo(in: ctx)

    #expect(try repo.revParse("HEAD") == head)
    #expect(try repo.revParse("refs/heads/main") == head)
    let staged = try gitStatus(at: repo.url.path).entries.map { "\($0.staged.rawValue)\($0.worktree.rawValue) \($0.path)" }
    #expect(staged == ["M. a.txt"], "undo must put the change back in the index, staged")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func aRejectingPreCommitHookRefusesTheCommitAndItsOutputIsInTheError(
    format: FixtureRepository.RefFormat
) throws {
    let repo = try stagedRepo(format)
    defer { repo.destroy() }
    try installPreCommit("#!/bin/sh\necho 'lint: trailing whitespace in a.txt'\nexit 1\n", in: repo)
    let head = try repo.revParse("HEAD")

    let error = try #require(throws: GitProcess.Failure.self) {
        try commitStaged(message: "second", at: repo.url.path, extraEnvironment: hermetic)
    }

    guard case let .exited(code, stderr, _) = error else {
        Issue.record("expected .exited, got \(error)")
        return
    }
    #expect(code == 1)
    #expect(stderr.contains("lint: trailing whitespace in a.txt"))
    #expect(try repo.revParse("HEAD") == head, "a refused commit must not move HEAD")
}
