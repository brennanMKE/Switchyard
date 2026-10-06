// RewriteFixupNewerTests.swift — Fixup Newer Commits into This: fold every
// commit above the selected one into it, keeping its message and author
// (guide §11 decision 48, #0602).
//
// No signing key is created or used: every fixture sets commit.gpgsign=false.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

private let git = GitProcess()

@discardableResult
private func run(_ arguments: [String], in repo: FixtureRepository,
                 environment: [String: String] = [:]) throws -> String {
    try git.run(arguments, workingDirectory: repo.url.path,
                extraEnvironment: hermetic.merging(environment) { _, new in new }).text
}

private func subjects(in repo: FixtureRepository) throws -> [String] {
    try run(["log", "--format=%s"], in: repo).split(separator: "\n").map(String.init)
}

/// The message bytes stored in the commit object — `cat-file commit` minus
/// its header block.
private func storedMessage(_ revision: String, in repo: FixtureRepository) throws -> String {
    let object = try run(["cat-file", "commit", revision], in: repo)
    guard let separator = object.range(of: "\n\n") else { return "" }
    return String(object[separator.upperBound...])
}

private func parents(_ revision: String, in repo: FixtureRepository) throws -> [String] {
    try run(["rev-list", "--parents", "-n", "1", revision], in: repo)
        .split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
}

private func author(_ revision: String, in repo: FixtureRepository) throws -> String {
    try run(["log", "-n", "1", "--format=%an|%ae|%ad", "--date=raw", revision], in: repo)
}

/// Brennan's workflow: `root`, then the commit with the good message
/// (authored by Bob, 2020), then three `wip` commits by Carol that edit the
/// good commit's file and add their own. `main` is at the third `wip`.
private func wipFixture() throws -> FixtureRepository {
    var repo = try FixtureRepository()
    try repo.build([.init("root", files: ["root.txt": "root\n"])])
    try repo.writeUntracked(["feature.txt": "first draft\n"])
    try run(["add", "feature.txt"], in: repo)
    try run(["commit", "-q", "-m", "Parse the config file", "-m", "Reads ~/.switchyard."],
            in: repo, environment: [
                "GIT_AUTHOR_NAME": "Bob", "GIT_AUTHOR_EMAIL": "bob@example.invalid",
                "GIT_AUTHOR_DATE": "1600000000 +0200"])
    for step in 1...3 {
        try repo.writeUntracked(["feature.txt": "draft \(step)\n", "wip\(step).txt": "\(step)\n"])
        try run(["add", "feature.txt", "wip\(step).txt"], in: repo)
        try run(["commit", "-q", "-m", "wip"], in: repo, environment: [
            "GIT_AUTHOR_NAME": "Carol", "GIT_AUTHOR_EMAIL": "carol@example.invalid",
            "GIT_AUTHOR_DATE": "\(1650000000 + step) -0500"])
    }
    return repo
}

/// HEAD, every ref and the index bytes — what a refusal must not move.
private func fullSnapshot(_ repo: FixtureRepository) throws -> String {
    try run(["rev-parse", "HEAD", "HEAD^{tree}"], in: repo)
        + run(["for-each-ref", "--format=%(refname) %(objectname)"], in: repo)
        + run(["ls-files", "-s"], in: repo)
}

// MARK: - The fold

@Test func fixupNewerFoldsEveryWipCommitIntoTheGoodOneAndKeepsItsMessageAndAuthor() throws {
    let repo = try wipFixture()
    defer { repo.destroy() }
    let good = try repo.revParse("HEAD~3")
    let root = try repo.revParse("HEAD~4")
    let tipTree = try repo.revParse("HEAD^{tree}")
    let goodMessage = try storedMessage(good, in: repo)
    #expect(goodMessage == "Parse the config file\n\nReads ~/.switchyard.\n", "fixture drifted")
    let goodAuthor = try author(good, in: repo)
    #expect(goodAuthor == "Bob|bob@example.invalid|1600000000 +0200\n", "fixture drifted")

    let result = try Rewrite.fixupNewer(into: good, at: repo.url.path, extraEnvironment: hermetic)

    #expect(result.head == (try repo.revParse("refs/heads/main")))
    #expect(try subjects(in: repo) == ["Parse the config file", "root"],
            "the three wip commits are gone; the good commit is the tip")
    #expect(try storedMessage("HEAD", in: repo) == goodMessage,
            "the selected commit's message is kept byte for byte")
    #expect(try repo.revParse("HEAD^{tree}") == tipTree,
            "the result carries the old tip's tree — every wip change is in it")
    #expect(try parents("HEAD", in: repo) == [root], "the result keeps the good commit's parent")
    #expect(try author("HEAD", in: repo) == goodAuthor,
            "the selected commit's author and author date are kept, not the wip author's")
    #expect(try run(["log", "-n", "1", "--format=%cn", "HEAD"], in: repo) == "Fixture\n",
            "the committer is the current identity")
}

@Test func fixupNewerLeavesStagedAndUnstagedWorkInPlace() throws {
    let repo = try wipFixture()
    defer { repo.destroy() }
    try repo.writeUntracked(["staged.txt": "staged\n"])
    try run(["add", "staged.txt"], in: repo)
    try repo.writeUntracked(["root.txt": "root edited, unstaged\n"])
    let statusBefore = try run(["status", "--porcelain"], in: repo)

    _ = try Rewrite.fixupNewer(into: "HEAD~3", at: repo.url.path, extraEnvironment: hermetic)

    #expect(try subjects(in: repo) == ["Parse the config file", "root"])
    #expect(!(try run(["ls-tree", "--name-only", "HEAD"], in: repo).contains("staged.txt")),
            "staged work is never swept into the fold")
    #expect(try run(["status", "--porcelain"], in: repo) == statusBefore,
            "the index and working tree are untouched")
}

@Test func fixupNewerIntoTheRootMakesANewRoot() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("root"), .init("wip1"), .init("wip2")])
    let rootMessage = try storedMessage("HEAD~2", in: repo)
    let tipTree = try repo.revParse("HEAD^{tree}")

    _ = try Rewrite.fixupNewer(into: "HEAD~2", at: repo.url.path, extraEnvironment: hermetic)

    #expect(try subjects(in: repo) == ["root"])
    #expect(try parents("HEAD", in: repo).isEmpty, "the result is still a root")
    #expect(try storedMessage("HEAD", in: repo) == rootMessage)
    #expect(try repo.revParse("HEAD^{tree}") == tipTree)
}

@Test func fixupNewerIntoAMergeKeepsTheMergesParents() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1"), .init("c2"),
        .init("side", parents: ["c1"]),
        .init("m", parents: ["c2", "side"]),
        .init("wip1", parents: ["m"]),
        .init("wip2", parents: ["wip1"]),
    ])
    try repo.branch("main", at: "wip2")
    try repo.checkout("main")
    let m = try #require(repo.oids["m"])
    let mergeParents = try parents(m, in: repo)
    let tipTree = try repo.revParse("HEAD^{tree}")

    _ = try Rewrite.fixupNewer(into: m, at: repo.url.path, extraEnvironment: hermetic)

    #expect(try subjects(in: repo).first == "m")
    #expect(try parents("HEAD", in: repo) == mergeParents,
            "the folded merge keeps both of its parents")
    #expect(try repo.revParse("HEAD^{tree}") == tipTree)
}

@Test func fixupNewerOnADetachedHeadMovesHead() throws {
    let repo = try wipFixture()
    defer { repo.destroy() }
    let mainBefore = try repo.revParse("refs/heads/main")
    try repo.checkoutDetached(mainBefore)

    let result = try Rewrite.fixupNewer(into: "HEAD~3", at: repo.url.path,
                                        extraEnvironment: hermetic)

    #expect(try repo.revParse("HEAD") == result.head)
    #expect(try subjects(in: repo) == ["Parse the config file", "root"])
    #expect(try repo.revParse("refs/heads/main") == mainBefore, "no branch moves while detached")
}

// MARK: - Refusals

@Test func theTipIsNothingToDoAndNothingMoves() throws {
    let repo = try wipFixture()
    defer { repo.destroy() }
    let before = try fullSnapshot(repo)

    #expect(throws: RewriteError.nothingToDo) {
        try Rewrite.fixupNewer(into: "HEAD", at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try fullSnapshot(repo) == before)
}

@Test func aMergeAboveIsRefusedAndNothingMoves() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1"), .init("c2"),
        .init("side", parents: ["c1"]),
        .init("m", parents: ["c2", "side"]),
        .init("top", parents: ["m"]),
    ])
    try repo.branch("main", at: "top")
    try repo.checkout("main")
    let before = try fullSnapshot(repo)
    let m = try #require(repo.oids["m"])

    #expect(throws: RewriteError.foldMergeRefused(commit: m)) {
        try Rewrite.fixupNewer(into: try #require(repo.oids["c2"]), at: repo.url.path,
                               extraEnvironment: hermetic)
    }
    #expect(try fullSnapshot(repo) == before)
}

@Test func aCommitOffTheBranchIsRefusedAndNothingMoves() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1"), .init("c2"),
        .init("side", parents: ["c1"]),
    ])
    try repo.branch("main", at: "c2")
    try repo.checkout("main")
    let before = try fullSnapshot(repo)
    let side = try #require(repo.oids["side"])

    #expect(throws: RewriteError.commitNotOnRef(commit: side, ref: "refs/heads/main")) {
        try Rewrite.fixupNewer(into: side, at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try fullSnapshot(repo) == before)
}

// MARK: - Undo

@Test func undoFixupNewerRestoresTheBranchAndTheIndexExactly() throws {
    let repo = try wipFixture()
    defer { repo.destroy() }
    try repo.writeUntracked(["staged.txt": "staged\n"])
    try run(["add", "staged.txt"], in: repo)
    let tipBefore = try repo.revParse("refs/heads/main")
    let indexBefore = try run(["ls-files", "-s"], in: repo)

    _ = try Rewrite.fixupNewer(into: "HEAD~3", at: repo.url.path, extraEnvironment: hermetic)
    #expect(try repo.revParse("refs/heads/main") != tipBefore)
    let context = try WorktreeContext.resolve(path: repo.url.path)
    #expect(try JournalList.list(in: context).items.last?.metadata?.operation == "fixup-newer",
            "one journal entry, named for Edit ▸ Undo")

    _ = try JournalUndo.undo(in: context)

    #expect(try repo.revParse("refs/heads/main") == tipBefore)
    #expect(try repo.revParse("HEAD") == tipBefore)
    #expect(try run(["ls-files", "-s"], in: repo) == indexBefore)
    #expect(try subjects(in: repo) == ["wip", "wip", "wip", "Parse the config file", "root"])
}
