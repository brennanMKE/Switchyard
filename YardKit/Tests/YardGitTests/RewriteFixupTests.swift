// RewriteFixupTests.swift — Fixup with Parent on any commit of the branch
// (guide §11 decision 46, #0581)
//
// No signing key is created or used: every fixture sets commit.gpgsign=false.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

private let git = GitProcess()

private func run(_ arguments: [String], in repo: FixtureRepository,
                 environment: [String: String] = [:]) throws -> String {
    try git.run(arguments, workingDirectory: repo.url.path,
                extraEnvironment: hermetic.merging(environment) { _, new in new }).text
}

private func subjects(in repo: FixtureRepository) throws -> [String] {
    try run(["log", "--format=%s"], in: repo).split(separator: "\n").map(String.init)
}

/// The message bytes stored in the commit object — `cat-file commit` minus
/// its header block (`log --format=%B` appends its own newline).
private func storedMessage(_ revision: String, in repo: FixtureRepository) throws -> String {
    let object = try run(["cat-file", "commit", revision], in: repo)
    guard let separator = object.range(of: "\n\n") else { return "" }
    return String(object[separator.upperBound...])
}

private func parents(_ revision: String, in repo: FixtureRepository) throws -> [String] {
    try run(["rev-list", "--parents", "-n", "1", revision], in: repo)
        .split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
}

/// `root → A → B → C → D` on `main`. Each commit adds its own file, and C
/// also edits B's file, so C's change is visible in the folded tree.
private func linearFixture() throws -> FixtureRepository {
    var repo = try FixtureRepository()
    try repo.build([
        .init("root", files: ["root.txt": "root\n"]),
        .init("A", files: ["a.txt": "a\n"]),
        .init("B", files: ["b.txt": "b\n"], message: "B subject\n\nB body"),
        .init("C", files: ["b.txt": "b changed by C\n", "c.txt": "c\n"],
              message: "C subject\n\nC body"),
        .init("D", files: ["d.txt": "d\n"]),
    ])
    return repo
}

/// HEAD, every ref and the index bytes — what a refusal must not move.
private func fullSnapshot(_ repo: FixtureRepository) throws -> String {
    try run(["rev-parse", "HEAD", "HEAD^{tree}"], in: repo)
        + run(["for-each-ref", "--format=%(refname) %(objectname)"], in: repo)
        + run(["ls-files", "-s"], in: repo)
}

// MARK: - The fold

@Test func fixupMidBranchFoldsTheCommitIntoItsParentAndKeepsTheParentsMessage() throws {
    let repo = try linearFixture()
    defer { repo.destroy() }
    let b = try repo.revParse("HEAD~2")
    let c = try repo.revParse("HEAD~1")
    let oldTipTree = try repo.revParse("HEAD^{tree}")
    let parentMessage = try storedMessage(b, in: repo)

    let result = try Rewrite.fixup(commit: c, at: repo.url.path, extraEnvironment: hermetic)

    #expect(result.head == (try repo.revParse("refs/heads/main")))
    #expect(try subjects(in: repo) == ["D", "B subject", "A", "root"],
            "C is gone; its parent B keeps its place and subject")
    #expect(try storedMessage("HEAD~1", in: repo) == parentMessage,
            "the parent's message is kept byte for byte; C's is dropped")
    #expect(try repo.revParse("HEAD~1^{tree}") == (try repo.revParse("\(c)^{tree}")),
            "the folded commit carries C's tree — C's change is in the parent now")
    #expect(try repo.revParse("HEAD~2") == (try repo.revParse("\(b)~1")),
            "the folded commit keeps B's own parent, A, unchanged")
    #expect(try repo.revParse("HEAD^{tree}") == oldTipTree, "the tip's tree is unchanged")
    #expect(try storedMessage("HEAD", in: repo) == "D\n", "the descendant keeps its message")
    #expect(try parents("HEAD", in: repo) == [try repo.revParse("HEAD~1")],
            "the descendant is re-parented on the folded commit")
}

@Test func fixupKeepsTheParentsAuthorAndEachDescendantsAuthor() throws {
    let repo = try linearFixture()
    defer { repo.destroy() }
    // Give B and D distinct authors and dates, rebuilding the chain with git.
    try run(["reset", "-q", "--hard", "HEAD~3"], in: repo) // at A
    try run(["commit", "-q", "--allow-empty", "-m", "B"], in: repo, environment: [
        "GIT_AUTHOR_NAME": "Bob", "GIT_AUTHOR_EMAIL": "bob@example.invalid",
        "GIT_AUTHOR_DATE": "1600000000 +0200"])
    try run(["commit", "-q", "--allow-empty", "-m", "C"], in: repo, environment: [
        "GIT_AUTHOR_NAME": "Carol", "GIT_AUTHOR_EMAIL": "carol@example.invalid",
        "GIT_AUTHOR_DATE": "1650000000 -0500"])
    try run(["commit", "-q", "--allow-empty", "-m", "D"], in: repo, environment: [
        "GIT_AUTHOR_NAME": "Dan", "GIT_AUTHOR_EMAIL": "dan@example.invalid",
        "GIT_AUTHOR_DATE": "1700000000 +0000"])

    _ = try Rewrite.fixup(commit: "HEAD~1", at: repo.url.path, extraEnvironment: hermetic)

    #expect(try run(["log", "-n", "1", "--format=%an|%ae|%ad", "--date=raw", "HEAD~1"], in: repo)
            == "Bob|bob@example.invalid|1600000000 +0200\n",
            "the folded commit keeps the parent's author and author date, as `commit --amend` does")
    #expect(try run(["log", "-n", "1", "--format=%an|%ae|%ad", "--date=raw", "HEAD"], in: repo)
            == "Dan|dan@example.invalid|1700000000 +0000\n",
            "a copied descendant keeps its own author and date")
    #expect(try run(["log", "-n", "1", "--format=%cn", "HEAD~1"], in: repo) == "Fixture\n",
            "the committer is the current identity")
}

@Test func fixupOfTheTipLeavesStagedAndUnstagedWorkInPlace() throws {
    let repo = try linearFixture()
    defer { repo.destroy() }
    try repo.writeUntracked(["staged.txt": "staged\n"])
    try run(["add", "staged.txt"], in: repo)
    try repo.writeUntracked(["a.txt": "a edited, unstaged\n"])
    let statusBefore = try run(["status", "--porcelain"], in: repo)

    _ = try Rewrite.fixup(commit: "HEAD", at: repo.url.path, extraEnvironment: hermetic)

    #expect(try subjects(in: repo) == ["C subject", "B subject", "A", "root"])
    #expect(try run(["ls-tree", "--name-only", "HEAD"], in: repo).contains("d.txt"),
            "D's file is in the folded commit")
    #expect(!(try run(["ls-tree", "--name-only", "HEAD"], in: repo).contains("staged.txt")),
            "unlike the alias, staged work is never swept into the fold")
    #expect(try run(["status", "--porcelain"], in: repo) == statusBefore,
            "the index and working tree are untouched")
}

@Test func fixupIntoTheRootMakesANewRootCommit() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("root"), .init("second")])

    _ = try Rewrite.fixup(commit: "HEAD", at: repo.url.path, extraEnvironment: hermetic)

    #expect(try subjects(in: repo) == ["root"])
    #expect(try parents("HEAD", in: repo).isEmpty, "the folded root stays a root")
    #expect(try run(["ls-tree", "--name-only", "HEAD"], in: repo) == "root.txt\nsecond.txt\n")
}

@Test func aMergeAboveIsCopiedWithItsSecondParentIntact() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1"), .init("c2"), .init("c3"),
        .init("side", parents: ["c1"]),
        .init("m", parents: ["c3", "side"]),
        .init("top", parents: ["m"]),
    ])
    try repo.branch("main", at: "top")
    try repo.checkout("main")
    let side = try #require(repo.oids["side"])
    let tipTree = try repo.revParse("HEAD^{tree}")

    _ = try Rewrite.fixup(commit: try #require(repo.oids["c3"]), at: repo.url.path,
                          extraEnvironment: hermetic)

    #expect(try run(["log", "--first-parent", "--format=%s"], in: repo) == "top\nm\nc2\nc1\n")
    #expect(try parents("HEAD~1", in: repo).last == side,
            "the merge above keeps its second parent")
    #expect(try parents("HEAD~1", in: repo).count == 2)
    #expect(try repo.revParse("HEAD^{tree}") == tipTree)
}

@Test func fixupIntoAMergeParentKeepsTheMergesParents() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1"), .init("c2"),
        .init("side", parents: ["c1"]),
        .init("m", parents: ["c2", "side"]),
        .init("head", parents: ["m"]),
    ])
    try repo.branch("main", at: "head")
    try repo.checkout("main")
    let mergeParents = try parents(try #require(repo.oids["m"]), in: repo)

    _ = try Rewrite.fixup(commit: "HEAD", at: repo.url.path, extraEnvironment: hermetic)

    #expect(try subjects(in: repo).first == "m")
    #expect(try parents("HEAD", in: repo) == mergeParents,
            "the folded merge keeps both parents, as the alias and GitUp do")
    #expect(try run(["ls-tree", "--name-only", "HEAD"], in: repo).contains("head.txt"))
}

// MARK: - Refusals

@Test func aMergeCommitIsRefusedAndNothingMoves() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1"), .init("c2"),
        .init("side", parents: ["c1"]),
        .init("m", parents: ["c2", "side"]),
    ])
    try repo.branch("main", at: "m")
    try repo.checkout("main")
    let before = try fullSnapshot(repo)
    let m = try repo.revParse("HEAD")

    #expect(throws: RewriteError.foldMergeRefused(commit: m)) {
        try Rewrite.fixup(commit: "HEAD", at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try fullSnapshot(repo) == before)
}

@Test func theRootCommitIsRefusedAndNothingMoves() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("root"), .init("second")])
    let before = try fullSnapshot(repo)
    let root = try repo.revParse("HEAD~1")

    #expect(throws: RewriteError.rootRewriteRefused(operation: "fixup", commit: root)) {
        try Rewrite.fixup(commit: root, at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try fullSnapshot(repo) == before)
}

// MARK: - Undo

@Test func undoRestoresTheBranchAndTheIndexExactly() throws {
    let repo = try linearFixture()
    defer { repo.destroy() }
    try repo.writeUntracked(["staged.txt": "staged\n"])
    try run(["add", "staged.txt"], in: repo)
    let tipBefore = try repo.revParse("refs/heads/main")
    let indexBefore = try run(["ls-files", "-s"], in: repo)

    _ = try Rewrite.fixup(commit: "HEAD~1", at: repo.url.path, extraEnvironment: hermetic)
    #expect(try repo.revParse("refs/heads/main") != tipBefore)

    _ = try JournalUndo.undo(in: try WorktreeContext.resolve(path: repo.url.path))

    #expect(try repo.revParse("refs/heads/main") == tipBefore)
    #expect(try repo.revParse("HEAD") == tipBefore)
    #expect(try run(["ls-files", "-s"], in: repo) == indexBefore)
    #expect(try run(["for-each-ref", "--format=%(subject)", "refs/heads/main"], in: repo)
            == "D\n")
}

// MARK: - StoredCommit

@Test func storedCommitReadsTheMessageBytesAndTheAuthorLine() {
    let object = """
        tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
        parent 1111111111111111111111111111111111111111
        author Ann Example <ann@example.invalid> 1600000000 +0200
        committer Fixture <fixture@example.invalid> 1700000000 +0000

        subject

        body line

        """
    let stored = StoredCommit(object)
    #expect(stored.message == "subject\n\nbody line\n")
    #expect(stored.authorEnvironment == [
        "GIT_AUTHOR_NAME": "Ann Example",
        "GIT_AUTHOR_EMAIL": "ann@example.invalid",
        "GIT_AUTHOR_DATE": "@1600000000 +0200",
    ])
}
