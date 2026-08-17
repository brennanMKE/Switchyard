// HunksTests.swift — stable hunk ids (#0016)

import Foundation
import Testing
@testable import YardGit

// MARK: - Fixture helpers

/// `line 01` … `line 20`, one per line, trailing newline.
private func base20() -> String {
    (1...20).map { String(format: "line %02d", $0) }.joined(separator: "\n") + "\n"
}

/// The two-hunk edit: a line inserted after `line 03`, and `line 17`
/// replaced — far enough apart that git keeps them as separate hunks
/// (edits within 6 lines of each other merge into one hunk at -U3).
private func edited20() -> String {
    var lines = (1...20).map { String(format: "line %02d", $0) }
    lines[16] = "line 17 CHANGED"
    lines.insert("inserted after 03", at: 3)
    return lines.joined(separator: "\n") + "\n"
}

private func twoHunkRepo(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["f.txt": base20()])])
    try repo.writeUntracked(["f.txt": edited20()])
    return repo
}

// MARK: - Listing and id stability (fixture-backed)

@Test(arguments: FixtureRepository.RefFormat.supported())
func twoSeparatedEditsProduceTwoHunks(format: FixtureRepository.RefFormat) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }

    let files = try listHunks(at: repo.url.path, area: .unstaged)
    #expect(files.map(\.path) == ["f.txt"])
    let file = try #require(files.first)
    #expect(file.hunks.count == 2)

    let first = try #require(file.hunks.first)
    #expect(first.header == "@@ -1,6 +1,7 @@")
    #expect(first.oldStart == 1 && first.oldCount == 6)
    #expect(first.newStart == 1 && first.newCount == 7)
    #expect(first.body.contains("+inserted after 03"))

    let second = try #require(file.hunks.last)
    #expect(second.header == "@@ -14,7 +15,7 @@ line 13")
    #expect(second.oldStart == 14 && second.newStart == 15)
    #expect(second.body.contains("-line 17"))
    #expect(second.body.contains("+line 17 CHANGED"))

    for hunk in file.hunks {
        #expect(hunk.id.count == 12)
        #expect(hunk.id.allSatisfy { $0.isHexDigit })
    }
    #expect(first.id != second.id)

    // Deterministic: a second listing reports identical results.
    let again = try listHunks(at: repo.url.path, area: .unstaged)
    #expect(again == files)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func stagingOneHunkKeepsTheOtherHunkId(format: FixtureRepository.RefFormat) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }
    let git = GitProcess()

    let before = try listHunks(at: repo.url.path, area: .unstaged)
    let file = try #require(before.first)
    let staged = try #require(file.hunks.first)     // the insertion at line 03
    let kept = try #require(file.hunks.last)        // the edit at line 17

    // Stage only the first hunk, exactly as a future stage-by-id would:
    // file header plus that hunk's patch text, applied to the index.
    try git.run(["apply", "--cached"],
                workingDirectory: repo.url.path,
                standardInput: Data((file.headerText + staged.patchText).utf8))

    // The remaining unstaged hunk: same id, same body, shifted old side.
    let afterUnstaged = try listHunks(at: repo.url.path, area: .unstaged)
    let remaining = try #require(afterUnstaged.first?.hunks)
    #expect(remaining.map(\.id) == [kept.id])
    let survivor = try #require(remaining.first)
    #expect(survivor.body == kept.body)
    #expect(kept.oldStart == 14 && survivor.oldStart == 15)
    #expect(survivor.header != kept.header)

    // The staged listing reports the staged hunk under its unstaged id.
    let afterStaged = try listHunks(at: repo.url.path, area: .staged)
    #expect(afterStaged.first?.hunks.map(\.id) == [staged.id])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func unrelatedEditElsewhereKeepsExistingHunkIds(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["f.txt": base20()])])

    var lines = (1...20).map { String(format: "line %02d", $0) }
    lines[16] = "line 17 CHANGED"
    try repo.writeUntracked(["f.txt": lines.joined(separator: "\n") + "\n"])
    let only = try #require(try listHunks(at: repo.url.path, area: .unstaged)
        .first?.hunks.first)

    // An unrelated edit far from the hunk: line 03, replaced in place so
    // no line numbers below it shift either.
    lines[2] = "line 03 EDITED"
    try repo.writeUntracked(["f.txt": lines.joined(separator: "\n") + "\n"])
    let ids = try #require(try listHunks(at: repo.url.path, area: .unstaged)
        .first?.hunks.map(\.id))
    #expect(ids.count == 2)
    #expect(ids.contains(only.id))
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func editInsideAHunkChangesItsId(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["f.txt": base20()])])

    var lines = (1...20).map { String(format: "line %02d", $0) }
    lines[16] = "line 17 CHANGED"
    try repo.writeUntracked(["f.txt": lines.joined(separator: "\n") + "\n"])
    let stale = try #require(try listHunks(at: repo.url.path, area: .unstaged)
        .first?.hunks.first)

    lines[16] = "line 17 CHANGED DIFFERENTLY"
    try repo.writeUntracked(["f.txt": lines.joined(separator: "\n") + "\n"])
    let fresh = try #require(try listHunks(at: repo.url.path, area: .unstaged)
        .first?.hunks)
    #expect(fresh.count == 1)
    // The stale id is gone from the listing — which is what makes a stale
    // id detectable when stage-by-id (#0040) refuses unknown ids.
    #expect(!fresh.map(\.id).contains(stale.id))
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func identicalChangeInTwoFilesGetsDistinctIds(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": base20(), "b.txt": base20()])])
    var lines = (1...20).map { String(format: "line %02d", $0) }
    lines[16] = "line 17 CHANGED"
    let edited = lines.joined(separator: "\n") + "\n"
    try repo.writeUntracked(["a.txt": edited, "b.txt": edited])

    let files = try listHunks(at: repo.url.path, area: .unstaged)
    #expect(files.map(\.path) == ["a.txt", "b.txt"])
    let a = try #require(files.first?.hunks.first)
    let b = try #require(files.last?.hunks.first)
    #expect(a.body == b.body)      // same change …
    #expect(a.id != b.id)          // … different id, because the path is hashed
}

// MARK: - Binary, mode-only, no-newline, staged area (fixture-backed)

@Test(arguments: FixtureRepository.RefFormat.supported())
func binaryChangeIsRepresentedNotSkipped(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    let git = GitProcess()
    try Data([0x42, 0x49, 0x4e, 0x00, 0x01, 0x02])
        .write(to: repo.url.appendingPathComponent("bin.dat"))
    try git.run(["add", "bin.dat"], workingDirectory: repo.url.path)
    try git.run(["commit", "-qm", "bin"], workingDirectory: repo.url.path)
    try Data([0x42, 0x49, 0x4e, 0x00, 0x99, 0x98])
        .write(to: repo.url.appendingPathComponent("bin.dat"))

    let files = try listHunks(at: repo.url.path, area: .unstaged)
    #expect(files.map(\.path) == ["bin.dat"])
    let file = try #require(files.first)
    #expect(file.isBinary)
    #expect(file.hunks.isEmpty)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func modeOnlyChangeIsRepresented(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("a")])    // creates and commits a.txt
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: repo.url.appendingPathComponent("a.txt").path)

    let files = try listHunks(at: repo.url.path, area: .unstaged)
    #expect(files.map(\.path) == ["a.txt"])
    let file = try #require(files.first)
    #expect(file.oldMode == "100644")
    #expect(file.newMode == "100755")
    #expect(!file.isBinary)
    #expect(file.hunks.isEmpty)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func noNewlineAtEofRoundTripsThroughApply(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["s.txt": "only line"])])
    try repo.writeUntracked(["s.txt": "only line CHANGED"])

    let files = try listHunks(at: repo.url.path, area: .unstaged)
    let file = try #require(files.first)
    let hunk = try #require(file.hunks.first)
    #expect(hunk.body == [
        "-only line",
        "\\ No newline at end of file",
        "+only line CHANGED",
        "\\ No newline at end of file",
    ])

    // The patch text is faithful enough for git to apply it byte-for-byte:
    // after staging it, index and worktree agree and the unstaged diff is empty.
    try GitProcess().run(["apply", "--cached"],
                         workingDirectory: repo.url.path,
                         standardInput: Data((file.headerText + hunk.patchText).utf8))
    let after = try listHunks(at: repo.url.path, area: .unstaged)
    #expect(after.isEmpty)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func stagedAreaListsTheIndexNotTheWorktree(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["f.txt": base20(), "g.txt": "g\n"])])
    try repo.writeUntracked(["f.txt": edited20(), "g.txt": "g CHANGED\n"])
    try GitProcess().run(["add", "f.txt"], workingDirectory: repo.url.path)

    let staged = try listHunks(at: repo.url.path, area: .staged)
    #expect(staged.map(\.path) == ["f.txt"])
    #expect(staged.first?.hunks.count == 2)

    let unstaged = try listHunks(at: repo.url.path, area: .unstaged)
    #expect(unstaged.map(\.path) == ["g.txt"])
}

// MARK: - Pure parser tests (no fixture, measured literals)

@Test func hunkIdIsAPureFunctionOfPathAndBody() {
    // sha256("f.txt" + NUL + "-x\n+y") — pinned; measured with
    // `printf 'f.txt\0-x\n+y' | shasum -a 256`.
    #expect(HunkParser.hunkID(path: "f.txt", body: ["-x", "+y"]) == "b88468cda3e3")
    #expect(HunkParser.hunkID(path: "g.txt", body: ["-x", "+y"]) != "b88468cda3e3")
    #expect(HunkParser.hunkID(path: "f.txt", body: ["-x", "+z"]) != "b88468cda3e3")
}

@Test func omittedHunkCountsDefaultToOne() throws {
    // Measured: single-line file, `x` → `y`.
    let text = """
    diff --git a/one.txt b/one.txt
    index 587be6b..975fbec 100644
    --- a/one.txt
    +++ b/one.txt
    @@ -1 +1 @@
    -x
    +y

    """
    let file = try #require(try HunkParser().parse(text).first)
    let hunk = try #require(file.hunks.first)
    #expect(hunk.oldStart == 1 && hunk.oldCount == 1)
    #expect(hunk.newStart == 1 && hunk.newCount == 1)
    #expect(hunk.body == ["-x", "+y"])
}

@Test func newAndDeletedFilesTakePathFromTheNonNullSide() throws {
    // Measured: `git diff --cached` of a staged new file and a staged rm.
    let added = """
    diff --git a/added.txt b/added.txt
    new file mode 100644
    index 0000000..d5a09df
    --- /dev/null
    +++ b/added.txt
    @@ -0,0 +1 @@
    +brand new

    """
    let addedFile = try #require(try HunkParser().parse(added).first)
    #expect(addedFile.path == "added.txt")
    #expect(addedFile.oldMode == nil && addedFile.newMode == "100644")
    let addedHunk = try #require(addedFile.hunks.first)
    #expect(addedHunk.oldStart == 0 && addedHunk.oldCount == 0)
    #expect(addedHunk.newStart == 1 && addedHunk.newCount == 1)

    let deleted = """
    diff --git a/one.txt b/one.txt
    deleted file mode 100644
    index 587be6b..0000000
    --- a/one.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -x

    """
    let deletedFile = try #require(try HunkParser().parse(deleted).first)
    #expect(deletedFile.path == "one.txt")
    #expect(deletedFile.oldMode == "100644" && deletedFile.newMode == nil)
}

@Test func spacePathTrailingTabIsStripped() throws {
    // Measured: paths containing a space get a trailing TAB on the ---/+++
    // lines. The literal tabs below are load-bearing.
    let text = "diff --git a/my file.txt b/my file.txt\n"
        + "index de98044..7be73ce 100644\n"
        + "--- a/my file.txt\t\n"
        + "+++ b/my file.txt\t\n"
        + "@@ -1,3 +1,3 @@\n"
        + " a\n-b\n+B\n c\n"
    let file = try #require(try HunkParser().parse(text).first)
    #expect(file.path == "my file.txt")
    #expect(file.hunks.count == 1)
}

@Test func quotedPathThrowsInsteadOfMisparsing() {
    // Measured: a double quote in the path stays C-quoted even under
    // core.quotepath=false.
    let text = """
    diff --git "a/we\\"ird.txt" "b/we\\"ird.txt"
    index 587be6b..975fbec 100644
    --- "a/we\\"ird.txt"
    +++ "b/we\\"ird.txt"
    @@ -1 +1 @@
    -x
    +y

    """
    #expect(throws: HunkParser.Failure.self) {
        try HunkParser().parse(text)
    }
}

@Test func duplicateHunksGetOccurrenceSuffixes() throws {
    let text = """
    diff --git a/dup.txt b/dup.txt
    index 1111111..2222222 100644
    --- a/dup.txt
    +++ b/dup.txt
    @@ -1,3 +1,3 @@
     c1
    -old
    +new
     c2
    @@ -10,3 +10,3 @@
     c1
    -old
    +new
     c2

    """
    let file = try #require(try HunkParser().parse(text).first)
    #expect(file.hunks.count == 2)
    let first = try #require(file.hunks.first)
    let second = try #require(file.hunks.last)
    #expect(first.id.count == 12)
    #expect(second.id == first.id + "-2")
}

@Test func addedPlusPlusLineStaysInsideItsHunk() throws {
    // An added line reading `++ x` prints as `+++ x`. Body membership is
    // decided by the header's line counts, so it must not be taken for a
    // `+++ b/…` file header.
    let text = """
    diff --git a/p.txt b/p.txt
    index 1111111..2222222 100644
    --- a/p.txt
    +++ b/p.txt
    @@ -1,2 +1,3 @@
     keep
    +++ x
     tail

    """
    let file = try #require(try HunkParser().parse(text).first)
    #expect(file.path == "p.txt")
    let hunk = try #require(file.hunks.first)
    #expect(hunk.body == [" keep", "+++ x", " tail"])
}

// MARK: - Conflict-format lines

@Test func unmergedPathLineIsNotAppendedToThePreviousFilesHeader() throws {
    // Measured: `git diff --cached` during a merge prints `* Unmerged path
    // m.txt` at its sorted position — here after a.txt's block. Appended to
    // headerText, the reconstructed patch fails `git apply` with "patch with
    // only garbage at line 5".
    let text = """
    diff --git a/a.txt b/a.txt
    index 2cdcdb0..1c76fbc 100644
    --- a/a.txt
    +++ b/a.txt
    @@ -1,3 +1,3 @@
    -a1
    +a1 CHANGED
     a2
     a3
    * Unmerged path m.txt

    """
    let files = try HunkParser().parse(text)
    #expect(files.map(\.path) == ["a.txt"])
    let file = try #require(files.first)
    #expect(file.headerText == """
    diff --git a/a.txt b/a.txt
    index 2cdcdb0..1c76fbc 100644
    --- a/a.txt
    +++ b/a.txt

    """)
    #expect(file.hunks.count == 1)
}

@Test func combinedDiffBlockDoesNotCorruptAnOpenFile() throws {
    // Synthetic order: a `diff --cc` block after a `diff --git` block.
    // Measured git output puts all --cc blocks first, but the parser must
    // not depend on that: without a boundary here, the --cc block's
    // `--- a/m.txt` line would overwrite the open file's path.
    let text = """
    diff --git a/a.txt b/a.txt
    index 2cdcdb0..1c76fbc 100644
    --- a/a.txt
    +++ b/a.txt
    @@ -1,3 +1,3 @@
    -a1
    +a1 CHANGED
     a2
     a3
    diff --cc m.txt
    index abd82df,846f043..0000000
    --- a/m.txt
    +++ b/m.txt
    @@@ -1,1 -1,1 +1,5 @@@
    ++<<<<<<< HEAD
     +main version
    ++=======
     + side version
    ++>>>>>>> side

    """
    let files = try HunkParser().parse(text)
    #expect(files.map(\.path) == ["a.txt"])
    let file = try #require(files.first)
    #expect(file.hunks.count == 1)
    #expect(!file.headerText.contains("m.txt"))
}

@Test func combinedDiffFirstThenNormalFileParses() throws {
    // The order git actually emits (measured): every `diff --cc` block
    // precedes every `diff --git` block.
    let text = """
    diff --cc m.txt
    index abd82df,846f043..0000000
    --- a/m.txt
    +++ b/m.txt
    @@@ -1,1 -1,1 +1,5 @@@
    ++<<<<<<< HEAD
     +main version
    ++=======
     + side version
    ++>>>>>>> side
    diff --git a/z.txt b/z.txt
    index c1c940f..b759132 100644
    --- a/z.txt
    +++ b/z.txt
    @@ -1,3 +1,3 @@
    -z1
    +z1 CHANGED
     z2
     z3

    """
    let files = try HunkParser().parse(text)
    #expect(files.map(\.path) == ["z.txt"])
    #expect(files.first?.hunks.count == 1)
}
