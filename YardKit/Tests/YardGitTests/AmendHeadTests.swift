// AmendHeadTests.swift — what Amend would rewrite, and the amend itself (#0463, #0464)
//
// NO NETWORK: the only remote is a bare repository in a temporary directory.
// NO SIGNING KEY is created or used: FixtureRepository sets
// commit.gpgsign=false and the hermetic environment blanks global and
// system config.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

// MARK: - #0463: AmendHead.target

@Test(arguments: FixtureRepository.RefFormat.supported())
func amendTargetReadsHeadAndItsFullMessage(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    try GitProcess().run(
        ["commit", "-q", "--allow-empty", "-m", "Subject line", "-m", "Body paragraph."],
        workingDirectory: repo.url.path)

    let target = try AmendHead.target(at: repo.url.path, extraEnvironment: hermetic)

    #expect(target.oid == (try repo.revParse("HEAD")))
    #expect(target.message == "Subject line\n\nBody paragraph.")
    #expect(target.refusal == nil)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func amendTargetRefusesAnUnbornBranch(format: FixtureRepository.RefFormat) throws {
    let repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }

    let target = try AmendHead.target(at: repo.url.path, extraEnvironment: hermetic)

    #expect(target.oid == nil)
    #expect(target.message == "")
    #expect(target.refusal == .noCommits)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func amendTargetRefusesACommitItsUpstreamContains(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    let bare = try repo.addUpstream()
    defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }
    // A second remote branch at the same commit, sorting before the
    // upstream: the upstream is the one named.
    try GitProcess().run(["push", "-q", "origin", "main:aaa"], workingDirectory: repo.url.path)
    try GitProcess().run(["fetch", "-q", "origin"], workingDirectory: repo.url.path)

    let pushed = try AmendHead.target(at: repo.url.path, extraEnvironment: hermetic)
    #expect(pushed.refusal == .pushed(remoteRef: "origin/main"))

    try repo.build([.init("local", files: ["a.txt": "two\n"])])
    let local = try AmendHead.target(at: repo.url.path, extraEnvironment: hermetic)
    #expect(local.refusal == nil, "a commit only on the local branch can be amended")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func amendTargetRefusesACommitAnyRemoteBranchContains(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    let bare = try repo.addUpstream()
    defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }
    // `git fetch` also writes origin/HEAD, a symbolic ref, which sorts first
    // and must be skipped.
    try GitProcess().run(["fetch", "-q", "origin"], workingDirectory: repo.url.path)
    // A new branch at origin/main's commit, with no upstream of its own.
    try GitProcess().run(["switch", "-q", "-c", "topic"], workingDirectory: repo.url.path)

    let target = try AmendHead.target(at: repo.url.path, extraEnvironment: hermetic)

    #expect(target.refusal == .pushed(remoteRef: "origin/main"))
}

// MARK: - #0464: AmendHead.run

/// Two commits, then `a.txt` modified and staged.
private func amendableRepo(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([
        .init("base", files: ["a.txt": "one\n"]),
        .init("second", files: ["b.txt": "bee\n"]),
    ])
    try repo.writeUntracked(["a.txt": "one\ntwo\n"])
    try GitProcess().run(["add", "a.txt"], workingDirectory: repo.url.path)
    return repo
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func amendReplacesHeadWithTheIndexAndTheNewMessageOnTheSameParent(
    format: FixtureRepository.RefFormat
) throws {
    let repo = try amendableRepo(format)
    defer { repo.destroy() }
    let parent = try repo.revParse("HEAD~1")
    let oldHead = try repo.revParse("HEAD")

    let result = try AmendHead.run(message: "second, amended", at: repo.url.path, extraEnvironment: hermetic)

    #expect(result.oid == (try repo.revParse("HEAD")))
    #expect(result.oid != oldHead)
    #expect(try repo.revParse("HEAD~1") == parent, "amend replaces HEAD; it does not add a child")
    let subject = try GitProcess().run(["log", "-1", "--format=%s"], workingDirectory: repo.url.path).text
    #expect(subject == "second, amended\n")
    let shown = try GitProcess().run(["show", "HEAD:a.txt"], workingDirectory: repo.url.path).text
    #expect(shown == "one\ntwo\n")
    let kept = try GitProcess().run(["show", "HEAD:b.txt"], workingDirectory: repo.url.path).text
    #expect(kept == "bee\n", "the amended commit keeps HEAD's own change")
    #expect(try gitStatus(at: repo.url.path).entries.isEmpty)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func amendWithNothingStagedChangesOnlyTheMessageOfARootCommit(
    format: FixtureRepository.RefFormat
) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    let oldTree = try repo.revParse("HEAD^{tree}")

    try AmendHead.run(message: "base, reworded", at: repo.url.path, extraEnvironment: hermetic)

    #expect(try repo.revParse("HEAD^{tree}") == oldTree)
    let subject = try GitProcess().run(["log", "-1", "--format=%s"], workingDirectory: repo.url.path).text
    #expect(subject == "base, reworded\n")
    let count = try GitProcess().run(["rev-list", "--count", "HEAD"], workingDirectory: repo.url.path).text
    #expect(count == "1\n")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func amendWritesOneAmendEntryAndUndoRestoresTheOldHeadAndTheIndex(
    format: FixtureRepository.RefFormat
) throws {
    let repo = try amendableRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let oldHead = try repo.revParse("HEAD")
    let entriesBefore = try JournalAnchor.list(in: ctx).count

    try AmendHead.run(message: "second, amended", at: repo.url.path, extraEnvironment: hermetic)
    #expect(try JournalAnchor.list(in: ctx).count == entriesBefore + 1)
    #expect(try JournalList.list(in: ctx).items.last?.metadata?.operation == "amend")

    try JournalUndo.undo(in: ctx)

    #expect(try repo.revParse("HEAD") == oldHead)
    #expect(try repo.revParse("refs/heads/main") == oldHead)
    let status = try gitStatus(at: repo.url.path).entries.map {
        "\($0.staged.rawValue)\($0.worktree.rawValue) \($0.path)"
    }
    #expect(status == ["M. a.txt"], "undo must put the change back in the index, staged")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func amendRefusesAPushedHeadBeforeWritingAnything(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    let bare = try repo.addUpstream()
    defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let head = try repo.revParse("HEAD")
    let entriesBefore = try JournalAnchor.list(in: ctx).count

    #expect(throws: AmendHead.Refusal.pushed(remoteRef: "origin/main")) {
        try AmendHead.run(message: "rewritten", at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try repo.revParse("HEAD") == head)
    #expect(try JournalAnchor.list(in: ctx).count == entriesBefore, "a refused amend writes no entry")
}
