// DiscardChangesTests.swift — discard unstaged changes, journaled (#0468)

import Foundation
import Testing
@testable import YardGit

/// What a path is on disk: its bytes, whether it is executable, and a
/// symlink's target. `nil` when nothing is there.
private struct OnDisk: Equatable {
    let bytes: Data?
    let executable: Bool
    let linkTarget: String?
}

private func onDisk(_ path: String, in repo: FixtureRepository) -> OnDisk? {
    let full = repo.url.appendingPathComponent(path).path
    let fm = FileManager.default
    if let target = try? fm.destinationOfSymbolicLink(atPath: full) {
        return OnDisk(bytes: nil, executable: false, linkTarget: target)
    }
    guard fm.fileExists(atPath: full) else { return nil }
    return OnDisk(bytes: fm.contents(atPath: full), executable: fm.isExecutableFile(atPath: full),
                  linkTarget: nil)
}

/// `git status --porcelain=v2`'s XY field per path; untracked reads `"??"`.
private func xy(in repo: FixtureRepository) throws -> [String: String] {
    let status = try gitStatus(at: repo.url.path)
    return Dictionary(uniqueKeysWithValues: status.entries.map {
        ($0.path, $0.worktree == .untracked ? "??" : "\($0.staged.rawValue)\($0.worktree.rawValue)")
    })
}

/// One commit holding `m.txt`, `bin.dat`, `run.sh`, `link` (a symlink to
/// `m.txt`), `gone.txt` and `.gitignore` (`*.o`). Then, unstaged: `m.txt`
/// edited, `bin.dat` rewritten with NUL bytes, `run.sh` made executable,
/// `link` replaced by a regular file, `gone.txt` deleted; untracked:
/// `new.txt`, `*.txt`, `gen/b.txt`, and `dir/` holding `a.txt` and the
/// ignored `a.o`.
private func dirtyRepo(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: [
        "m.txt": "one\n", "run.sh": "echo hi\n", "gone.txt": "gone\n", ".gitignore": "*.o\n",
    ])])
    let url = repo.url
    let fm = FileManager.default
    try Data([0, 1, 2, 3]).write(to: url.appendingPathComponent("bin.dat"))
    try fm.createSymbolicLink(atPath: url.appendingPathComponent("link").path,
                              withDestinationPath: "m.txt")
    try GitProcess().run(["add", "bin.dat", "link"], workingDirectory: url.path)
    try GitProcess().run(["commit", "-q", "-m", "binary and link"], workingDirectory: url.path)

    try repo.writeUntracked(["m.txt": "one\ntwo\n", "new.txt": "new\n", "*.txt": "star\n",
                             "dir/a.txt": "a\n", "dir/a.o": "object\n", "gen/b.txt": "b\n"])
    try Data([0, 9, 9, 0, 255]).write(to: url.appendingPathComponent("bin.dat"))
    try fm.setAttributes([.posixPermissions: 0o755],
                         ofItemAtPath: url.appendingPathComponent("run.sh").path)
    try fm.removeItem(at: url.appendingPathComponent("link"))
    try "not a link\n".write(to: url.appendingPathComponent("link"), atomically: true, encoding: .utf8)
    try fm.removeItem(at: url.appendingPathComponent("gone.txt"))
    return repo
}

private let everyPath = ["m.txt", "bin.dat", "run.sh", "link", "gone.txt", "new.txt", "*.txt",
                         "dir/a.txt", "dir/a.o", "gen/b.txt"]

@Test(arguments: FixtureRepository.RefFormat.supported())
func discardPathsPutsTrackedFilesBackAndRemovesUntrackedOnes(
    format: FixtureRepository.RefFormat
) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }

    try DiscardChanges.discardPaths(
        ["m.txt", "bin.dat", "run.sh", "link", "gone.txt", "new.txt", "dir/", "gen/"],
        at: repo.url.path)

    #expect(onDisk("m.txt", in: repo)?.bytes == Data("one\n".utf8))
    #expect(onDisk("bin.dat", in: repo)?.bytes == Data([0, 1, 2, 3]))
    #expect(onDisk("run.sh", in: repo)?.executable == false, "the mode change was not discarded")
    #expect(onDisk("link", in: repo)?.linkTarget == "m.txt", "the symlink did not come back")
    #expect(onDisk("gone.txt", in: repo)?.bytes == Data("gone\n".utf8))
    #expect(onDisk("new.txt", in: repo) == nil)
    #expect(onDisk("dir/a.txt", in: repo) == nil)
    #expect(!FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("gen").path),
            "an untracked directory with nothing ignored in it must go entirely")
    #expect(try xy(in: repo) == ["*.txt": "??"], "only the path not named may stay changed")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func discardPathsKeepsAnIgnoredFileInAnUntrackedDirectory(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }

    try DiscardChanges.discardPaths(["dir/"], at: repo.url.path)

    #expect(onDisk("dir/a.txt", in: repo) == nil)
    #expect(onDisk("dir/a.o", in: repo)?.bytes == Data("object\n".utf8),
            "the ignored file is in no snapshot, so deleting it could not be undone")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func discardPathsReadsAGlobCharacterLiterally(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }

    try DiscardChanges.discardPaths(["*.txt"], at: repo.url.path)

    #expect(onDisk("*.txt", in: repo) == nil)
    #expect(onDisk("new.txt", in: repo)?.bytes == Data("new\n".utf8), "`*.txt` was read as a pattern")
    #expect(onDisk("m.txt", in: repo)?.bytes == Data("one\ntwo\n".utf8), "`*.txt` was read as a pattern")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func discardPathsLeavesTheStagedChange(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }
    try GitProcess().run(["add", "m.txt"], workingDirectory: repo.url.path)
    try "one\ntwo\nthree\n".write(to: repo.url.appendingPathComponent("m.txt"),
                                  atomically: true, encoding: .utf8)
    #expect(try xy(in: repo)["m.txt"] == "MM")

    try DiscardChanges.discardPaths(["m.txt"], at: repo.url.path)

    #expect(onDisk("m.txt", in: repo)?.bytes == Data("one\ntwo\n".utf8),
            "the worktree must go back to the staged version, not HEAD's")
    #expect(try xy(in: repo)["m.txt"] == "M.", "the staged change must stay staged")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func undoDiscardRestoresEveryFileByteForByte(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let before = Dictionary(uniqueKeysWithValues: everyPath.map { ($0, onDisk($0, in: repo)) })
    let statusBefore = try xy(in: repo)
    let entriesBefore = try JournalAnchor.list(in: ctx).count

    try DiscardChanges.discardPaths(
        ["m.txt", "bin.dat", "run.sh", "link", "gone.txt", "new.txt", "*.txt", "dir/", "gen/"],
        at: repo.url.path)
    #expect(try JournalAnchor.list(in: ctx).count == entriesBefore + 1)
    #expect(try xy(in: repo).isEmpty, "the discard must change everything, or undo proves nothing")

    try JournalUndo.undo(in: ctx)

    for path in everyPath {
        #expect(onDisk(path, in: repo) == before[path] ?? nil, "\(path) did not come back as it was")
    }
    #expect(try xy(in: repo) == statusBefore)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func discardPathsWithNoPathsWritesNoEntry(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let entriesBefore = try JournalAnchor.list(in: ctx).count

    try DiscardChanges.discardPaths([], at: repo.url.path)

    #expect(try JournalAnchor.list(in: ctx).count == entriesBefore)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func aRefusedDiscardWritesNoEntryAndChangesNothing(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let entriesBefore = try JournalAnchor.list(in: ctx).count
    let statusBefore = try xy(in: repo)

    // `m.txt` alone would be discarded; the clean `.gitignore` refuses the call.
    #expect(throws: DiscardChanges.Refusal.noUnstagedChange(path: ".gitignore")) {
        try DiscardChanges.discardPaths(["m.txt", ".gitignore"], at: repo.url.path)
    }

    #expect(try JournalAnchor.list(in: ctx).count == entriesBefore)
    #expect(try xy(in: repo) == statusBefore)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func aNestedRepositoryIsRefused(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }
    try GitProcess().run(["init", "-q", repo.url.appendingPathComponent("inner").path])
    try "x\n".write(to: repo.url.appendingPathComponent("inner/x"), atomically: true, encoding: .utf8)
    #expect(try xy(in: repo)["inner/"] == "??")

    #expect(throws: DiscardChanges.Refusal.nestedRepository(path: "inner/")) {
        try DiscardChanges.discardPaths(["inner/"], at: repo.url.path)
    }
    #expect(onDisk("inner/x", in: repo) != nil)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func anIntentToAddFileIsRefused(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }
    try GitProcess().run(["add", "-N", "new.txt"], workingDirectory: repo.url.path)
    #expect(try xy(in: repo)["new.txt"] == ".A")

    #expect(throws: DiscardChanges.Refusal.intentToAdd(path: "new.txt")) {
        try DiscardChanges.discardPaths(["new.txt"], at: repo.url.path)
    }
    #expect(onDisk("new.txt", in: repo)?.bytes == Data("new\n".utf8),
            "restoring an intent-to-add file empties it")
}

@Test
func planRefusesAConflictedPath() throws {
    var entry = WorktreeStatusEntry(path: "c.txt")
    entry.staged = .conflicted
    entry.worktree = .conflicted
    #expect(throws: DiscardChanges.Refusal.conflicted(path: "c.txt")) {
        try DiscardChanges.plan(["c.txt"], status: [entry], isRepository: { _ in false })
    }
}

@Test
func planRefusesASubmodule() throws {
    var entry = WorktreeStatusEntry(path: "sub")
    entry.worktree = .modified
    entry.submodule = WorktreeStatusEntry.SubmoduleState(subToken: "S.M.")
    #expect(throws: DiscardChanges.Refusal.submodule(path: "sub")) {
        try DiscardChanges.plan(["sub"], status: [entry], isRepository: { _ in false })
    }
}

@Test
func planSplitsTrackedFromUntracked() throws {
    var modified = WorktreeStatusEntry(path: "m.txt")
    modified.worktree = .modified
    var deleted = WorktreeStatusEntry(path: "d.txt")
    deleted.worktree = .deleted
    var typechange = WorktreeStatusEntry(path: "l")
    typechange.worktree = .typechange
    var untracked = WorktreeStatusEntry(path: "dir/")
    untracked.worktree = .untracked

    let plan = try DiscardChanges.plan(
        ["dir/", "m.txt", "d.txt", "l"], status: [modified, deleted, typechange, untracked],
        isRepository: { _ in false })

    #expect(plan == .init(tracked: ["m.txt", "d.txt", "l"], untracked: ["dir/"]))
}

// MARK: - #0469 discardHunks

/// One commit holding `t.txt`, twenty lines; then lines 2 and 18 edited,
/// unstaged — two hunks, far enough apart that git keeps them separate.
private func twoHunkRepo(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    let lines = (1...20).map { String(format: "line %02d\n", $0) }
    try repo.build([.init("base", files: ["t.txt": lines.joined()])])
    var edited = lines
    edited[1] = "line 02 edited\n"
    edited[17] = "line 18 edited\n"
    try repo.writeUntracked(["t.txt": edited.joined()])
    return repo
}

private func text(_ path: String, in repo: FixtureRepository) throws -> String {
    try String(contentsOf: repo.url.appendingPathComponent(path), encoding: .utf8)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func discardHunksRemovesOnlyTheNamedHunk(format: FixtureRepository.RefFormat) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }
    let hunks = try listHunks(at: repo.url.path, area: .unstaged).flatMap(\.hunks)
    #expect(hunks.count == 2)

    try DiscardChanges.discardHunks(ids: [hunks[0].id], at: repo.url.path)

    let after = try text("t.txt", in: repo)
    #expect(after.contains("line 02\n"), "the first hunk was not discarded")
    #expect(after.contains("line 18 edited\n"), "the second hunk was discarded too")
    #expect(try listHunks(at: repo.url.path, area: .staged).isEmpty, "discard staged something")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func discardHunksLeavesTheIndexAlone(format: FixtureRepository.RefFormat) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }
    let first = try listHunks(at: repo.url.path, area: .unstaged).flatMap(\.hunks)[0]
    try stageHunks(ids: [first.id], at: repo.url.path)
    let staged = try listHunks(at: repo.url.path, area: .staged)
    let second = try listHunks(at: repo.url.path, area: .unstaged).flatMap(\.hunks)
    #expect(second.count == 1)

    try DiscardChanges.discardHunks(ids: [second[0].id], at: repo.url.path)

    #expect(try listHunks(at: repo.url.path, area: .staged) == staged, "the staged hunk moved")
    #expect(try listHunks(at: repo.url.path, area: .unstaged).isEmpty)
    #expect(try text("t.txt", in: repo).contains("line 02 edited\n"),
            "the worktree lost the staged hunk's line")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func undoDiscardHunkBringsTheLinesBack(format: FixtureRepository.RefFormat) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let before = try text("t.txt", in: repo)
    let entriesBefore = try JournalAnchor.list(in: ctx).count
    let ids = try listHunks(at: repo.url.path, area: .unstaged).flatMap(\.hunks).map(\.id)

    try DiscardChanges.discardHunks(ids: ids, at: repo.url.path)
    #expect(try JournalAnchor.list(in: ctx).count == entriesBefore + 1)
    #expect(try text("t.txt", in: repo) != before)

    try JournalUndo.undo(in: ctx)

    #expect(try text("t.txt", in: repo) == before)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func discardHunksWithAnUnknownIDChangesNothing(format: FixtureRepository.RefFormat) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }
    let before = try text("t.txt", in: repo)
    let first = try listHunks(at: repo.url.path, area: .unstaged).flatMap(\.hunks)[0]

    #expect(throws: StagingError.unknownHunkIDs(ids: ["000000000000"], area: .unstaged)) {
        try DiscardChanges.discardHunks(ids: [first.id, "000000000000"], at: repo.url.path)
    }
    #expect(try text("t.txt", in: repo) == before)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func discardHunksWithNoIDsWritesNoEntry(format: FixtureRepository.RefFormat) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let entriesBefore = try JournalAnchor.list(in: ctx).count

    try DiscardChanges.discardHunks(ids: [], at: repo.url.path)

    #expect(try JournalAnchor.list(in: ctx).count == entriesBefore)
}

// MARK: - #0478 discardLines

/// `t.txt` = a…e committed, then `c` replaced by `C` and `X` added, unstaged:
/// one hunk, body `[" a", " b", "-c", "+C", "+X", " d", " e"]`.
private func pairRepo(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["t.txt": "a\nb\nc\nd\ne\n"])])
    try repo.writeUntracked(["t.txt": "a\nb\nC\nX\nd\ne\n"])
    return repo
}

private func stagedText(_ path: String, in repo: FixtureRepository) throws -> String {
    try GitProcess().run(["show", ":" + path], workingDirectory: repo.url.path).text
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func discardLinesRemovesOnlyTheSelectedAddition(format: FixtureRepository.RefFormat) throws {
    let repo = try pairRepo(format)
    defer { repo.destroy() }
    let hunk = try #require(try listHunks(at: repo.url.path, area: .unstaged).first?.hunks.first)

    try DiscardChanges.discardLines(hunkID: hunk.id, lines: [4], at: repo.url.path)

    #expect(try text("t.txt", in: repo) == "a\nb\nC\nd\ne\n")
    #expect(try stagedText("t.txt", in: repo) == "a\nb\nc\nd\ne\n", "discard touched the index")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func discardLinesBringsBackOnlyTheSelectedRemoval(format: FixtureRepository.RefFormat) throws {
    let repo = try pairRepo(format)
    defer { repo.destroy() }
    let hunk = try #require(try listHunks(at: repo.url.path, area: .unstaged).first?.hunks.first)

    try DiscardChanges.discardLines(hunkID: hunk.id, lines: [2], at: repo.url.path)

    #expect(try text("t.txt", in: repo) == "a\nb\nc\nC\nX\nd\ne\n")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func undoDiscardLinesBringsTheLineBack(format: FixtureRepository.RefFormat) throws {
    let repo = try pairRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let entriesBefore = try JournalAnchor.list(in: ctx).count
    let hunk = try #require(try listHunks(at: repo.url.path, area: .unstaged).first?.hunks.first)

    try DiscardChanges.discardLines(hunkID: hunk.id, lines: [3, 4], at: repo.url.path)
    #expect(try JournalAnchor.list(in: ctx).count == entriesBefore + 1)
    #expect(try text("t.txt", in: repo) == "a\nb\nd\ne\n")

    try JournalUndo.undo(in: ctx)

    #expect(try text("t.txt", in: repo) == "a\nb\nC\nX\nd\ne\n")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func discardLinesWithAnUnknownIDChangesNothing(format: FixtureRepository.RefFormat) throws {
    let repo = try pairRepo(format)
    defer { repo.destroy() }

    #expect(throws: StagingError.unknownHunkIDs(ids: ["000000000000"], area: .unstaged)) {
        try DiscardChanges.discardLines(hunkID: "000000000000", lines: [4], at: repo.url.path)
    }
    #expect(try text("t.txt", in: repo) == "a\nb\nC\nX\nd\ne\n")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func discardLinesWithNoLinesWritesNoEntry(format: FixtureRepository.RefFormat) throws {
    let repo = try pairRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let entriesBefore = try JournalAnchor.list(in: ctx).count
    let hunk = try #require(try listHunks(at: repo.url.path, area: .unstaged).first?.hunks.first)

    try DiscardChanges.discardLines(hunkID: hunk.id, lines: [], at: repo.url.path)

    #expect(try JournalAnchor.list(in: ctx).count == entriesBefore)
}
