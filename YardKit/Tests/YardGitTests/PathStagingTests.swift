// PathStagingTests.swift — stage and unstage whole paths (#0438, #0439)

import Foundation
import Testing
@testable import YardGit

/// `git status --porcelain=v2`'s XY field per path, e.g. `["m.txt": "M."]`.
/// Untracked files read `"??"`.
private func xy(in repo: FixtureRepository) throws -> [String: String] {
    let status = try gitStatus(at: repo.url.path)
    return Dictionary(uniqueKeysWithValues: status.entries.map {
        ($0.path, $0.worktree == .untracked ? "??" : "\($0.staged.rawValue)\($0.worktree.rawValue)")
    })
}

/// One commit holding `m.txt`, `d.txt` and `r.txt`; then `m.txt` modified,
/// `d.txt` deleted, `n.txt` created and `*.txt` created — none staged.
private func dirtyRepo(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["m.txt": "one\n", "d.txt": "del\n", "r.txt": "ren\n"])])
    try repo.writeUntracked(["m.txt": "one\ntwo\n", "n.txt": "new\n", "*.txt": "star\n"])
    try FileManager.default.removeItem(at: repo.url.appendingPathComponent("d.txt"))
    return repo
}

// MARK: - #0438 stagePaths

@Test(arguments: FixtureRepository.RefFormat.supported())
func stagePathsStagesModifiedDeletedAndUntrackedPaths(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }

    try stagePaths(["m.txt", "d.txt", "n.txt"], at: repo.url.path)

    let after = try xy(in: repo)
    #expect(after["m.txt"] == "M.")
    #expect(after["d.txt"] == "D.")
    #expect(after["n.txt"] == "A.")
    #expect(after["*.txt"] == "??", "a path that was not named must stay unstaged")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func stagePathsReadsAGlobCharacterLiterally(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }

    try stagePaths(["*.txt"], at: repo.url.path)

    let after = try xy(in: repo)
    #expect(after["*.txt"] == "A.")
    // Read as a pathspec, `*.txt` would also have staged these three.
    #expect(after["m.txt"] == ".M")
    #expect(after["d.txt"] == ".D")
    #expect(after["n.txt"] == "??")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func stagePathsWritesOneEntryAndUndoRestoresTheIndex(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let before = try xy(in: repo)
    let entriesBefore = try JournalAnchor.list(in: ctx).count

    try stagePaths(["m.txt", "n.txt"], at: repo.url.path)
    #expect(try JournalAnchor.list(in: ctx).count == entriesBefore + 1)
    #expect(try xy(in: repo) != before, "the stage must change the index, or undo proves nothing")

    try JournalUndo.undo(in: ctx)

    #expect(try xy(in: repo) == before)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func stagePathsWithNoPathsWritesNoEntry(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let entriesBefore = try JournalAnchor.list(in: ctx).count

    try stagePaths([], at: repo.url.path)

    #expect(try JournalAnchor.list(in: ctx).count == entriesBefore)
}
