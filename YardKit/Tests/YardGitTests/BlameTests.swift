// BlameTests.swift — structured, range-limited blame (#0018)

import Foundation
import Testing
@testable import YardGit

// MARK: - Fixture helpers

/// Root commit content: five named lines.
private let baseContent = "alpha\nbravo\ncharlie\ndelta\necho\n"

/// Second commit: a line inserted after `alpha`, and `delta` replaced —
/// so lines 1, 3, 4, 6 blame to the root and lines 2, 5 to the edit,
/// and every root line after the insertion has `originalLine == finalLine - 1`.
private let editedContent = "alpha\ninserted after alpha\nbravo\ncharlie\ndelta CHANGED\necho\n"

/// Two commits touching `f.txt`: `base` creates five lines, `edit` inserts
/// one and changes one. `repo.oids["base"]` / `repo.oids["edit"]` hold the
/// commit ids the blame must attribute lines to.
private func twoCommitRepo(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["f.txt": baseContent])])
    try repo.build([.init("edit", files: ["f.txt": editedContent])])
    return repo
}

// MARK: - Fixture-backed

@Test(arguments: FixtureRepository.RefFormat.supported())
func linesBlameToTheCommitsThatWroteThem(format: FixtureRepository.RefFormat) throws {
    let repo = try twoCommitRepo(format)
    defer { repo.destroy() }
    let base = try #require(repo.oids["base"])
    let edit = try #require(repo.oids["edit"])

    let lines = try blameFile(at: repo.url.path, file: "f.txt")
    #expect(lines.count == 6)
    #expect(lines.map(\.finalLine) == [1, 2, 3, 4, 5, 6])
    // The specific mapping: two commits interleaved, not one answer repeated.
    #expect(lines.map(\.oid) == [base, edit, base, base, edit, base])
    #expect(lines.map(\.content) == [
        "alpha", "inserted after alpha", "bravo", "charlie", "delta CHANGED", "echo",
    ])
    // `bravo` was line 2 before the insertion shifted it to line 3.
    let bravo = lines[2]
    #expect(bravo.originalLine == 2)
    #expect(bravo.summary == "base")
    #expect(bravo.author == "Fixture")
    #expect(bravo.authorEmail == "fixture@example.invalid")
    #expect(bravo.authorTime > 0)
    #expect(bravo.originalPath == "f.txt")
    #expect(!bravo.isUncommitted)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func rangeLimitsToTheRequestedLines(format: FixtureRepository.RefFormat) throws {
    let repo = try twoCommitRepo(format)
    defer { repo.destroy() }
    let base = try #require(repo.oids["base"])

    let lines = try blameFile(at: repo.url.path, file: "f.txt", lines: 3...4)
    #expect(lines.map(\.finalLine) == [3, 4])
    #expect(lines.map(\.oid) == [base, base])
    #expect(lines.map(\.content) == ["bravo", "charlie"])
    // Original line numbers are pre-insertion — 2 and 3, not 3 and 4.
    #expect(lines.map(\.originalLine) == [2, 3])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func rangePastTheEndOfTheFileThrows(format: FixtureRepository.RefFormat) throws {
    let repo = try twoCommitRepo(format)
    defer { repo.destroy() }

    // `git blame -L 100,110` on a 6-line file exits 128 with
    // `fatal: file f.txt has only 6 lines`. A range that limited only the
    // output would return [] here instead of throwing.
    #expect(throws: GitProcess.Failure.self) {
        try blameFile(at: repo.url.path, file: "f.txt", lines: 100...110)
    }
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func uncommittedEditsReportTheZeroOid(format: FixtureRepository.RefFormat) throws {
    let repo = try twoCommitRepo(format)
    defer { repo.destroy() }
    let base = try #require(repo.oids["base"])

    // Edit line 3 in the worktree only.
    try repo.writeUntracked(["f.txt":
        "alpha\ninserted after alpha\nbravo EDITED\ncharlie\ndelta CHANGED\necho\n"])

    let lines = try blameFile(at: repo.url.path, file: "f.txt")
    #expect(lines.count == 6)
    let edited = lines[2]
    #expect(edited.oid == BlameLine.uncommittedOID)
    #expect(edited.isUncommitted)
    #expect(edited.author == "Not Committed Yet")
    #expect(edited.content == "bravo EDITED")
    // The untouched neighbours still blame to their real commits.
    #expect(lines[0].oid == base)
    #expect(!lines[0].isUncommitted)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func rootCommitLinesAreMarkedBoundary(format: FixtureRepository.RefFormat) throws {
    let repo = try twoCommitRepo(format)
    defer { repo.destroy() }
    let base = try #require(repo.oids["base"])

    let lines = try blameFile(at: repo.url.path, file: "f.txt")
    let rootLine = lines[0]
    #expect(rootLine.isBoundary)
    // Boundary lines carry the real root oid, not zeros.
    #expect(rootLine.oid == base)
    #expect(!lines[1].isBoundary)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func blameFollowsARename(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("create", files: ["old.txt": "one\ntwo\nthree\n"])])
    let git = GitProcess()
    try git.run(["mv", "old.txt", "new.txt"], workingDirectory: repo.url.path)
    try git.run(["commit", "-qm", "rename"], workingDirectory: repo.url.path)
    try repo.build([.init("edit", files: ["new.txt": "one\ntwo CHANGED\nthree\n"])])

    let lines = try blameFile(at: repo.url.path, file: "new.txt")
    #expect(lines.count == 3)
    // Unchanged lines blame through the rename to the creating commit, and
    // report the path the line had *in that commit*.
    #expect(lines[0].oid == repo.oids["create"])
    #expect(lines[0].originalPath == "old.txt")
    #expect(lines[1].oid == repo.oids["edit"])
    #expect(lines[1].originalPath == "new.txt")
}

// MARK: - Pure parser tests (measured literals)

/// The measured `git blame --porcelain` output of the two-commit fixture
/// shape, verbatim from git 2.50.1: full headers once per commit, then bare
/// `<oid> <orig> <final>` entries — including a 3-token group-continuation
/// line (`… 3 4`) with no line count.
private let porcelainTwoCommits = """
bf5667010615a9348bd45c628a822e333a953470 1 1 1
author Fixture
author-mail <fixture@example.invalid>
author-time 1786145206
author-tz -0700
committer Fixture
committer-mail <fixture@example.invalid>
committer-time 1786145206
committer-tz -0700
summary root adds five lines
boundary
filename f.txt
\talpha
df996ea0d03703e0b1829e8a99c7b40aa3c381e6 2 2 1
author Fixture
author-mail <fixture@example.invalid>
author-time 1786145206
author-tz -0700
committer Fixture
committer-mail <fixture@example.invalid>
committer-time 1786145206
committer-tz -0700
summary insert and change
previous bf5667010615a9348bd45c628a822e333a953470 f.txt
filename f.txt
\tinserted after alpha
bf5667010615a9348bd45c628a822e333a953470 2 3 2
\tbravo
bf5667010615a9348bd45c628a822e333a953470 3 4
\tcharlie
df996ea0d03703e0b1829e8a99c7b40aa3c381e6 5 5 1
\tdelta CHANGED
bf5667010615a9348bd45c628a822e333a953470 5 6 1
\techo

"""

@Test func repeatedCommitEntriesInheritTheCachedHeader() throws {
    let lines = try BlameParser().parse(porcelainTwoCommits)
    #expect(lines.count == 6)

    // Line 4 arrives as the bare continuation `bf… 3 4` — every field must
    // come from the cache built by line 1's full header.
    let charlie = lines[3]
    #expect(charlie.oid == "bf5667010615a9348bd45c628a822e333a953470")
    #expect(charlie.originalLine == 3)
    #expect(charlie.finalLine == 4)
    #expect(charlie.author == "Fixture")
    #expect(charlie.authorEmail == "fixture@example.invalid")
    #expect(charlie.authorTime == 1786145206)
    #expect(charlie.authorTimeZone == "-0700")
    #expect(charlie.summary == "root adds five lines")
    #expect(charlie.originalPath == "f.txt")
    #expect(charlie.isBoundary)
    #expect(charlie.content == "charlie")

    // And the interleaving is preserved: root, edit, root, root, edit, root.
    let root = "bf5667010615a9348bd45c628a822e333a953470"
    let edit = "df996ea0d03703e0b1829e8a99c7b40aa3c381e6"
    #expect(lines.map(\.oid) == [root, edit, root, root, edit, root])
    #expect(lines[1].isBoundary == false)
    #expect(lines[1].summary == "insert and change")
}

@Test func uncommittedPorcelainEntryParses() throws {
    // Measured: a worktree-only edit blames to the zero oid with a
    // fabricated author and summary.
    let text = """
0000000000000000000000000000000000000000 3 3 1
author Not Committed Yet
author-mail <not.committed.yet>
author-time 1786145224
author-tz -0700
committer Not Committed Yet
committer-mail <not.committed.yet>
committer-time 1786145224
committer-tz -0700
summary Version of f.txt from f.txt
previous df996ea0d03703e0b1829e8a99c7b40aa3c381e6 f.txt
filename f.txt
\tbravo EDITED IN WORKTREE

"""
    let line = try #require(try BlameParser().parse(text).first)
    #expect(line.isUncommitted)
    #expect(line.oid == BlameLine.uncommittedOID)
    #expect(line.author == "Not Committed Yet")
    #expect(line.authorEmail == "not.committed.yet")
    #expect(!line.isBoundary)
}

@Test func spacePathInFilenameParsesRaw() throws {
    // Measured: `filename my file.txt` — no quoting for a plain space.
    let text = """
0262f504e72eaded807d7c99dccbf9cd56a63e5d 1 1 1
author Fixture
author-mail <fixture@example.invalid>
author-time 1786145258
author-tz -0700
summary files
boundary
filename my file.txt
\tx

"""
    let line = try #require(try BlameParser().parse(text).first)
    #expect(line.originalPath == "my file.txt")
}

@Test func quotedFilenameThrowsInsteadOfMisparsing() {
    // Measured: a double quote in the name stays C-quoted even under
    // core.quotepath=false: `filename "we\\"ird.txt"`.
    let text = """
0262f504e72eaded807d7c99dccbf9cd56a63e5d 1 1 1
author Fixture
author-mail <fixture@example.invalid>
author-time 1786145258
author-tz -0700
summary quote
filename "we\\"ird.txt"
\tz

"""
    #expect(throws: BlameParser.Failure.self) {
        try BlameParser().parse(text)
    }
}

@Test func continuationForAnUnseenCommitThrows() {
    // A bare continuation entry whose commit never got a header — porcelain
    // out of order or truncated upstream. Half-filled lines are refused.
    let text = "bf5667010615a9348bd45c628a822e333a953470 3 4\n\tcharlie\n"
    #expect(throws: BlameParser.Failure.missingCommitHeader(
        oid: "bf5667010615a9348bd45c628a822e333a953470")) {
        try BlameParser().parse(text)
    }
}

@Test func emptyOutputParsesToNoLines() throws {
    // Measured: blaming an empty committed file exits 0 with no output.
    let lines = try BlameParser().parse("")
    #expect(lines.isEmpty)
}
