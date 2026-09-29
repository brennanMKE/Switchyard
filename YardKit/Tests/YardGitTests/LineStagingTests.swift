// LineStagingTests.swift — patches for selected lines of one hunk (#0476)

import Foundation
import Testing
@testable import YardGit

// MARK: - Helpers

/// A one-commit repository holding `f` = `base`, then `f` overwritten
/// with `edited` (unstaged).
private func editedRepo(base: String, edited: String) throws -> FixtureRepository {
    var repo = try FixtureRepository()
    try repo.build([.init("base", files: ["f": base])])
    try repo.writeUntracked(["f": edited])
    return repo
}

private func onlyFile(_ repo: FixtureRepository, area: DiffArea) throws -> FileDiff {
    let files = try listHunks(at: repo.url.path, area: area)
    #expect(files.count == 1)
    return try #require(files.first)
}

private func indexBytes(_ repo: FixtureRepository) throws -> String {
    try GitProcess().run(["show", ":f"], workingDirectory: repo.url.path).text
}

private func worktreeBytes(_ repo: FixtureRepository) throws -> String {
    try String(contentsOf: repo.url.appendingPathComponent("f"), encoding: .utf8)
}

// MARK: - The patch text (pure)

@Test func forwardKeepsAnUnselectedRemovalAsContextAndDropsAnUnselectedAddition() throws {
    let repo = try editedRepo(base: "a\nb\nc\nd\ne\n", edited: "a\nb\nC\nX\nd\ne\n")
    defer { repo.destroy() }
    let file = try onlyFile(repo, area: .unstaged)
    let hunk = try #require(file.hunks.first)
    #expect(hunk.body == [" a", " b", "-c", "+C", "+X", " d", " e"])

    let patch = try linePatch(file: file, hunk: hunk, lines: [4], direction: .forward)

    #expect(patch == file.headerText + "@@ -1,5 +1,6 @@\n a\n b\n c\n+X\n d\n e\n")
}

@Test func reverseKeepsAnUnselectedAdditionAsContextAndDropsAnUnselectedRemoval() throws {
    let repo = try editedRepo(base: "a\nb\nc\nd\ne\n", edited: "a\nb\nC\nX\nd\ne\n")
    defer { repo.destroy() }
    let file = try onlyFile(repo, area: .unstaged)
    let hunk = try #require(file.hunks.first)

    let patch = try linePatch(file: file, hunk: hunk, lines: [2], direction: .reverse)

    #expect(patch == file.headerText + "@@ -1,7 +1,6 @@\n a\n b\n-c\n C\n X\n d\n e\n")
}

@Test func selectingEveryChangedLineIsTheHunkItself() throws {
    let repo = try editedRepo(base: "a\nb\nc\nd\ne\n", edited: "a\nb\nC\nX\nd\ne\n")
    defer { repo.destroy() }
    let file = try onlyFile(repo, area: .unstaged)
    let hunk = try #require(file.hunks.first)

    for direction in [LinePatchDirection.forward, .reverse] {
        let patch = try linePatch(file: file, hunk: hunk, lines: [2, 3, 4], direction: direction)
        #expect(patch == file.headerText + hunk.patchText)
    }
}

@Test func aLineAddedAfterALastLineWithoutANewlineSplitsThatLine() throws {
    // `b` has no newline in both versions' last line; `c` is appended.
    let repo = try editedRepo(base: "a\nb", edited: "a\nb\nc")
    defer { repo.destroy() }
    let file = try onlyFile(repo, area: .unstaged)
    let hunk = try #require(file.hunks.first)
    #expect(hunk.body == [" a", "-b", "\\ No newline at end of file",
                          "+b", "+c", "\\ No newline at end of file"])

    let patch = try linePatch(file: file, hunk: hunk, lines: [4], direction: .forward)

    #expect(patch == file.headerText + "@@ -1,2 +1,3 @@\n a\n-b\n\\ No newline at end of file\n"
        + "+b\n+c\n\\ No newline at end of file\n")
}

@Test func aPartialUnstageOfANewFileBecomesAModification() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["keep": "k\n"])])
    try repo.writeUntracked(["f": "a\nb\nc\n"])
    try GitProcess().run(["add", "f"], workingDirectory: repo.url.path)
    let file = try onlyFile(repo, area: .staged)
    let hunk = try #require(file.hunks.first)
    #expect(file.headerText.contains("new file mode 100644\n"))

    let patch = try linePatch(file: file, hunk: hunk, lines: [1], direction: .reverse)

    #expect(!patch.contains("new file mode"))
    #expect(!patch.contains("/dev/null"))
    #expect(patch.contains("--- a/f\n+++ b/f\n@@ -0,2 +1,3 @@\n a\n+b\n c\n"))
}

@Test func aPartialStageOfADeletedFileBecomesAModification() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["f": "a\nb\nc\n"])])
    try FileManager.default.removeItem(at: repo.url.appendingPathComponent("f"))
    let file = try onlyFile(repo, area: .unstaged)
    let hunk = try #require(file.hunks.first)
    #expect(file.headerText.contains("deleted file mode 100644\n"))

    let patch = try linePatch(file: file, hunk: hunk, lines: [1], direction: .forward)

    #expect(!patch.contains("deleted file mode"))
    #expect(!patch.contains("/dev/null"))
    #expect(patch.contains("--- a/f\n+++ b/f\n@@ -1,3 +0,2 @@\n a\n-b\n c\n"))
}

@Test func contextMarkersAndOutOfRangeIndicesAreRefused() throws {
    let repo = try editedRepo(base: "a\nb", edited: "a\nb\nc")
    defer { repo.destroy() }
    let file = try onlyFile(repo, area: .unstaged)
    let hunk = try #require(file.hunks.first)

    for bad in [0, 2, 6, -1] {
        #expect(throws: StagingError.notAChangedLine(hunkID: hunk.id, line: bad)) {
            try linePatch(file: file, hunk: hunk, lines: [4, bad], direction: .forward)
        }
    }
}

@Test func anUnknownHunkIDIsRefusedByName() throws {
    let repo = try editedRepo(base: "a\n", edited: "b\n")
    defer { repo.destroy() }
    let files = try listHunks(at: repo.url.path, area: .unstaged)

    #expect(throws: StagingError.unknownHunkIDs(ids: ["000000000000"], area: .unstaged)) {
        try selectLinePatch(hunkID: "000000000000", lines: [0], from: files, area: .unstaged,
                            direction: .forward)
    }
}

@Test func aCombinedHunkIsRefusedBeforeAnyPatchIsBuilt() throws {
    // The shape `git diff` prints for a conflicted path (#0350).
    let hunk = Hunk(id: "cc0000000000", path: "m.txt", oldStart: 1, oldCount: 1, newStart: 1,
                    newCount: 1, header: "@@@ -1,1 -1,1 +1,1 @@@", body: ["++resolved"])
    let file = FileDiff(path: "m.txt", oldMode: nil, newMode: nil, isBinary: false,
                        headerText: "diff --cc m.txt\n", hunks: [hunk])

    #expect(throws: StagingError.combinedHunkNotStageable(path: "m.txt")) {
        try selectLinePatch(hunkID: hunk.id, lines: [0], from: [file], area: .unstaged,
                            direction: .forward)
    }
}

// MARK: - Every selection, through the real `git apply`

/// What `git apply` should leave: the fixed side of `hunk` with only the
/// selected changes made, spliced into `preimage` in place of that side's
/// lines. A line ends in a newline unless it is the result's last line and
/// came from a line git marked `\ No newline at end of file`.
private func expected(preimage: String, hunk: Hunk, lines: Set<Int>, reverse: Bool) -> String {
    var region: [(text: Substring, noNewline: Bool)] = []
    var keptLast = false
    for (index, raw) in hunk.body.enumerated() {
        guard let marker = raw.first else { continue }
        if marker == "\\" {
            if keptLast { region[region.count - 1].noNewline = true }
            continue
        }
        let selected = lines.contains(index)
        keptLast = marker == " " || (marker == "-" && selected == reverse)
            || (marker == "+" && selected != reverse)
        if keptLast { region.append((raw.dropFirst(), false)) }
    }
    var all: [(text: Substring, noNewline: Bool)] = []
    // Split on the scalar: "\r\n" is one `Character`.
    let parts = preimage.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        .map { Substring($0) }
    for part in parts.dropLast() { all.append((part, false)) }
    if let last = parts.last, !last.isEmpty { all.append((last, true)) }
    var start = reverse ? hunk.newStart : hunk.oldStart
    let count = reverse ? hunk.newCount : hunk.oldCount
    if count == 0 { start += 1 }
    all.replaceSubrange((start - 1)..<(start - 1 + count), with: region)
    return all.enumerated().map { index, line in
        line.text + (index == all.count - 1 && line.noNewline ? "" : "\n")
    }.joined()
}

/// Every non-empty selection of changed lines in every hunk of `f`,
/// staged, unstaged and discarded through `git apply`, against `expected`.
/// Returns the number of selections tried.
private func applyEverySelection(base: String, edited: String) throws -> Int {
    let repo = try editedRepo(base: base, edited: edited)
    defer { repo.destroy() }
    let path = repo.url.path, git = GitProcess()
    var tried = 0
    for mode in ["stage", "unstage", "discard"] {
        let reset: () throws -> Void = {
            try repo.writeUntracked(["f": edited])
            try git.run(mode == "unstage" ? ["add", "f"] : ["reset", "-q", "--", "f"], workingDirectory: path)
        }
        try reset()
        let area: DiffArea = mode == "unstage" ? .staged : .unstaged
        let file = try onlyFile(repo, area: area)
        for hunk in file.hunks {
            let changed = hunk.body.indices.filter { hunk.body[$0].first == "+" || hunk.body[$0].first == "-" }
            for mask in 1..<(1 << changed.count) {
                let lines = Set(changed.indices.filter { mask & (1 << $0) != 0 }.map { changed[$0] })
                try reset()
                let reverse = mode != "stage"
                let patch = try linePatch(file: file, hunk: hunk, lines: lines,
                                          direction: reverse ? .reverse : .forward)
                let argv = ["stage": ["apply", "--cached"], "unstage": ["apply", "--cached", "--reverse"],
                            "discard": ["apply", "--reverse"]][mode]!
                try git.run(argv, workingDirectory: path, standardInput: Data(patch.utf8))
                let want = expected(preimage: reverse ? edited : base, hunk: hunk, lines: lines, reverse: reverse)
                let got = try mode == "discard" ? worktreeBytes(repo) : indexBytes(repo)
                #expect(got == want, "\(mode) lines \(lines.sorted()) of \(hunk.header)")
                // The other side is untouched.
                if mode == "discard" { #expect(try indexBytes(repo) == base) }
                if mode == "stage" { #expect(try worktreeBytes(repo) == edited) }
                tried += 1
            }
        }
    }
    return tried
}

private let twenty: [String] = (1...20).map { String(format: "l%02d\n", $0) }

/// `twenty` with the lines at `indices` upper-cased, and `tail` appended.
private func twenty(editing indices: Set<Int>, tail: String = "") -> String {
    twenty.enumerated().map { indices.contains($0) ? $1.uppercased() : $1 }.joined() + tail
}

struct LineCase: Sendable, CustomTestStringConvertible {
    let name: String, base: String, edited: String
    /// How many selections the case has over all three directions.
    let selections: Int
    var testDescription: String { name }
}

/// Measured 2026-09-29 (git 2.54.0): every case, every selection, all three
/// directions, matching `expected`.
private let lineCases: [LineCase] = [
    LineCase(name: "modified pair", base: "a\nb\nc\nd\ne\n", edited: "a\nb\nC\nX\nd\ne\n", selections: 21),
    LineCase(name: "only additions", base: "a\nb\n", edited: "a\nX\nY\nb\n", selections: 9),
    LineCase(name: "only removals", base: "a\nX\nY\nb\n", edited: "a\nb\n", selections: 9),
    LineCase(name: "append after a last line without newline", base: "a\nb", edited: "a\nb\nc", selections: 21),
    LineCase(name: "replace lines ending without newline", base: "a\nb\nc", edited: "a\nB", selections: 21),
    LineCase(name: "gain the final newline", base: "a\nb", edited: "a\nb\nc\n", selections: 21),
    LineCase(name: "CRLF lines", base: "a\r\nb\r\nc\r\nd\r\n", edited: "a\r\nB\r\nc\r\nX\r\nd\r\n", selections: 21),
    LineCase(name: "two hunks", base: twenty.joined(), edited: twenty(editing: [1, 17]), selections: 18),
    LineCase(name: "two changes in one hunk, and a third hunk", base: twenty.joined(),
             edited: twenty(editing: [4, 8], tail: "tail\n"), selections: 48),
    LineCase(name: "adjacent hunks, one line apart", base: twenty.joined(),
             edited: twenty(editing: [4, 12], tail: "tail\n"), selections: 21),
    LineCase(name: "from an empty file", base: "", edited: "a\nb\nc\n", selections: 21),
    LineCase(name: "to an empty file", base: "a\nb\nc\n", edited: "", selections: 21),
]

@Test(arguments: lineCases)
func everySelectionAppliesToExactlyTheSelectedChanges(_ lineCase: LineCase) throws {
    #expect(try applyEverySelection(base: lineCase.base, edited: lineCase.edited) == lineCase.selections)
}

// MARK: - #0477 stageLines / unstageLines

private let fiveLines = "a\nb\nc\nd\ne\n"
/// `c` replaced by `C`, `X` added after it: body
/// `[" a", " b", "-c", "+C", "+X", " d", " e"]`.
private let fiveEdited = "a\nb\nC\nX\nd\ne\n"

private func entryCount(_ repo: FixtureRepository) throws -> Int {
    try JournalAnchor.list(in: try WorktreeContext.resolve(path: repo.url.path)).count
}

@Test func stageLinesStagesOnlyTheSelectedLine() throws {
    let repo = try editedRepo(base: fiveLines, edited: fiveEdited)
    defer { repo.destroy() }
    let hunk = try #require(try onlyFile(repo, area: .unstaged).hunks.first)
    let entries = try entryCount(repo)

    try stageLines(hunkID: hunk.id, lines: [4], at: repo.url.path)

    #expect(try indexBytes(repo) == "a\nb\nc\nX\nd\ne\n")
    #expect(try worktreeBytes(repo) == fiveEdited)
    #expect(try entryCount(repo) == entries + 1)
}

@Test func unstageLinesUnstagesOnlyTheSelectedLine() throws {
    let repo = try editedRepo(base: fiveLines, edited: fiveEdited)
    defer { repo.destroy() }
    try GitProcess().run(["add", "f"], workingDirectory: repo.url.path)
    let hunk = try #require(try onlyFile(repo, area: .staged).hunks.first)
    let entries = try entryCount(repo)

    // Unstage the removal of `c` only: `c` is back in the index, `C` and `X` stay.
    try unstageLines(hunkID: hunk.id, lines: [2], at: repo.url.path)

    #expect(try indexBytes(repo) == "a\nb\nc\nC\nX\nd\ne\n")
    #expect(try worktreeBytes(repo) == fiveEdited)
    #expect(try entryCount(repo) == entries + 1)
}

@Test func undoStageLinesPutsTheIndexBack() throws {
    let repo = try editedRepo(base: fiveLines, edited: fiveEdited)
    defer { repo.destroy() }
    let hunk = try #require(try onlyFile(repo, area: .unstaged).hunks.first)

    try stageLines(hunkID: hunk.id, lines: [2, 3], at: repo.url.path)
    #expect(try indexBytes(repo) == "a\nb\nC\nd\ne\n")
    try JournalUndo.undo(in: try WorktreeContext.resolve(path: repo.url.path))

    #expect(try indexBytes(repo) == fiveLines)
    #expect(try worktreeBytes(repo) == fiveEdited)
}

@Test func stageLinesWithAStaleHunkIDStagesNothing() throws {
    let repo = try editedRepo(base: fiveLines, edited: fiveEdited)
    defer { repo.destroy() }
    let hunk = try #require(try onlyFile(repo, area: .unstaged).hunks.first)
    try repo.writeUntracked(["f": "a\nb\nC\nY\nd\ne\n"])  // the hunk's lines changed

    #expect(throws: StagingError.unknownHunkIDs(ids: [hunk.id], area: .unstaged)) {
        try stageLines(hunkID: hunk.id, lines: [4], at: repo.url.path)
    }
    #expect(try indexBytes(repo) == fiveLines)
}

@Test func stageLinesRefusesAContextLineAndStagesNothing() throws {
    let repo = try editedRepo(base: fiveLines, edited: fiveEdited)
    defer { repo.destroy() }
    let hunk = try #require(try onlyFile(repo, area: .unstaged).hunks.first)

    #expect(throws: StagingError.notAChangedLine(hunkID: hunk.id, line: 0)) {
        try stageLines(hunkID: hunk.id, lines: [0, 4], at: repo.url.path)
    }
    #expect(try indexBytes(repo) == fiveLines)
}

@Test func noSelectedLinesWritesNoEntry() throws {
    let repo = try editedRepo(base: fiveLines, edited: fiveEdited)
    defer { repo.destroy() }
    let hunk = try #require(try onlyFile(repo, area: .unstaged).hunks.first)
    let entries = try entryCount(repo)

    try stageLines(hunkID: hunk.id, lines: [], at: repo.url.path)
    try unstageLines(hunkID: hunk.id, lines: [], at: repo.url.path)

    #expect(try entryCount(repo) == entries)
}

@Test func unstageLinesOfAStagedNewFileKeepsTheRestStaged() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["keep": "k\n"])])
    try repo.writeUntracked(["f": "a\nb\nc\n"])
    try GitProcess().run(["add", "f"], workingDirectory: repo.url.path)
    let hunk = try #require(try onlyFile(repo, area: .staged).hunks.first)

    try unstageLines(hunkID: hunk.id, lines: [1], at: repo.url.path)

    // Measured without the header rewrite: git exits 128, "new file f
    // depends on old contents"; with only the mode line dropped, it exits
    // 0 and removes `f` from the index altogether.
    #expect(try indexBytes(repo) == "a\nc\n")
    #expect(try worktreeBytes(repo) == "a\nb\nc\n")
}

@Test func stageLinesOfADeletedFileStagesOnlyThoseRemovals() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["f": "a\nb\nc\n"])])
    try FileManager.default.removeItem(at: repo.url.appendingPathComponent("f"))
    let hunk = try #require(try onlyFile(repo, area: .unstaged).hunks.first)

    try stageLines(hunkID: hunk.id, lines: [0, 2], at: repo.url.path)

    // Measured without the header rewrite: exit 128, "deleted file f still
    // has contents".
    #expect(try indexBytes(repo) == "b\n")
}

// MARK: - #0488: a changed line that opens with a combining mark

/// A body line is its marker scalar plus the file's line. When the file's
/// line opens with a combining mark (U+0301), Swift fuses the marker and the
/// mark into one `Character`, so `line.first` is `"+\u{301}"`, never `"+"`.
/// Measured on `main` at `b00ddbeb`: `stageLines` threw
/// `notAChangedLine(line: 2)` for the `+\u{301}B` line, and nothing was
/// staged. The text after the marker must keep the mark too: with only the
/// marker read fixed, `raw.dropFirst()` dropped the mark with the marker and
/// `git apply` refused the patch (`error: patch failed: f:1`).
@Test func stageLinesStagesALineThatOpensWithACombiningMark() throws {
    var old = (1...20).map { "line \($0)" }
    old[1] = "\u{301}b"
    var new = old
    new[1] = "\u{301}B"
    let repo = try editedRepo(
        base: old.joined(separator: "\n") + "\n", edited: new.joined(separator: "\n") + "\n")
    defer { repo.destroy() }
    let hunk = try #require(try onlyFile(repo, area: .unstaged).hunks.first)
    #expect(hunk.body == [" line 1", "-\u{301}b", "+\u{301}B", " line 3", " line 4", " line 5"])

    try stageLines(hunkID: hunk.id, lines: [2], at: repo.url.path)

    var staged = old
    staged.insert("\u{301}B", at: 2)
    #expect(try indexBytes(repo) == staged.joined(separator: "\n") + "\n")
}
