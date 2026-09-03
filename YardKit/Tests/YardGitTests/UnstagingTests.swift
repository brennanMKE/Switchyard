// UnstagingTests.swift — unstage hunks by id (#0162)

import Foundation
import Testing
@testable import YardGit

// MARK: - Fixture helpers (the two-hunk shape HunksTests measures)

private func base20() -> String {
    (1...20).map { String(format: "line %02d", $0) }.joined(separator: "\n") + "\n"
}

private func edited20() -> String {
    var lines = (1...20).map { String(format: "line %02d", $0) }
    lines[16] = "line 17 CHANGED"
    lines.insert("inserted after 03", at: 3)
    return lines.joined(separator: "\n") + "\n"
}

/// Two hunks in f.txt, both already staged (`git add`), worktree clean
/// against the index.
private func twoStagedHunksRepo(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["f.txt": base20()])])
    try repo.writeUntracked(["f.txt": edited20()])
    try GitProcess().run(["add", "f.txt"], workingDirectory: repo.url.path)
    return repo
}

private func listedHunks(in repo: FixtureRepository, area: DiffArea) throws -> [Hunk] {
    try listHunks(at: repo.url.path, area: area).flatMap(\.hunks)
}

// MARK: - Unstaging by id (fixture-backed)

@Test(arguments: FixtureRepository.RefFormat.supported())
func unstagingOneOfTwoStagedHunksLeavesTheOtherStaged(format: FixtureRepository.RefFormat) throws {
    let repo = try twoStagedHunksRepo(format)
    defer { repo.destroy() }

    let before = try listedHunks(in: repo, area: .staged)
    let first = try #require(before.first)
    let second = try #require(before.last)

    try unstageHunks(ids: [first.id], at: repo.url.path)

    // The unstaged hunk reappears in the unstaged listing under the same id;
    // the survivor stays staged, id unchanged, even though its header moved
    // (measured: @@ -14,7 +15,7 became @@ -14,7 +14,7).
    let unstaged = try listedHunks(in: repo, area: .unstaged)
    #expect(unstaged.map(\.id) == [first.id])
    let staged = try listedHunks(in: repo, area: .staged)
    #expect(staged.map(\.id) == [second.id])
    let survivor = try #require(staged.first)
    #expect(survivor.body == second.body)
    #expect(survivor.header != second.header)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func secondUnstageCallWithTheSurvivingIdStillApplies(format: FixtureRepository.RefFormat) throws {
    let repo = try twoStagedHunksRepo(format)
    defer { repo.destroy() }

    let before = try listedHunks(in: repo, area: .staged)
    let first = try #require(before.first)
    let second = try #require(before.last)

    try unstageHunks(ids: [first.id], at: repo.url.path)
    try unstageHunks(ids: [second.id], at: repo.url.path)

    let staged = try listHunks(at: repo.url.path, area: .staged)
    #expect(staged.isEmpty)
    let unstaged = try listedHunks(in: repo, area: .unstaged)
    #expect(Set(unstaged.map(\.id)) == Set([first.id, second.id]))
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func unstagingAStagedNewFileRemovesTheIndexEntry(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    try repo.writeUntracked(["added.txt": "brand new\n"])
    try GitProcess().run(["add", "added.txt"], workingDirectory: repo.url.path)

    let staged = try listHunks(at: repo.url.path, area: .staged)
    let file = try #require(staged.first)
    #expect(file.path == "added.txt")
    #expect(file.newMode == "100644")   // new file mode rides the header
    let hunk = try #require(file.hunks.first)

    try unstageHunks(ids: [hunk.id], at: repo.url.path)

    // Index entry gone, worktree file untouched: the file is untracked again.
    let stagedAfter = try listHunks(at: repo.url.path, area: .staged)
    #expect(stagedAfter.isEmpty)
    let status = try GitProcess().run(["status", "--porcelain"],
                                      workingDirectory: repo.url.path)
    #expect(status.lines == ["?? added.txt"])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func unknownIdUnstagesNothing(format: FixtureRepository.RefFormat) throws {
    let repo = try twoStagedHunksRepo(format)
    defer { repo.destroy() }

    let before = try listedHunks(in: repo, area: .staged)
    let good = try #require(before.first)
    let bogus = "000000000000"
    let error = try #require(throws: StagingError.self) {
        try unstageHunks(ids: [good.id, bogus], at: repo.url.path)
    }
    #expect(error == .unknownHunkIDs(ids: [bogus], area: .staged))

    // All or none: the resolvable id is still staged.
    let after = try listedHunks(in: repo, area: .staged)
    #expect(after.map(\.id) == before.map(\.id))
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func unstagingWorksWhileAnotherPathIsUnmerged(format: FixtureRepository.RefFormat) throws {
    // The staged listing during a conflict contains `* Unmerged path m.txt`
    // at its sorted position (#0161): without the parser hardening, a.txt's
    // headerText would carry that line and `git apply` would refuse the
    // reconstructed patch with "patch with only garbage".
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["m.txt": "original\n", "a.txt": "a1\na2\na3\n"])])
    try repo.build([.init("ours", parents: ["base"], files: ["m.txt": "ours\n"])])
    try repo.build([.init("theirs", parents: ["base"], files: ["m.txt": "theirs\n"])])
    let ours = try #require(repo.oids["ours"])
    let theirs = try #require(repo.oids["theirs"])
    try repo.checkoutDetached(ours)
    _ = try? GitProcess().run(["merge", "--no-commit", theirs],
                              workingDirectory: repo.url.path)
    let unmerged = try GitProcess().run(["ls-files", "-u"], workingDirectory: repo.url.path)
    #expect(unmerged.lines.count == 3)   // a real conflict, not vacuously green

    try repo.writeUntracked(["a.txt": "a1 CHANGED\na2\na3\n"])
    // The conflicted path lists first since #0342 (its combined `diff --cc`
    // block precedes every `diff --git` block), so a.txt must be found by
    // path, not taken as the first file.
    let conflictedFile = try #require(listHunks(at: repo.url.path, area: .unstaged)
        .first { $0.path == "m.txt" })
    let conflictedHunk = try #require(conflictedFile.hunks.first)
    #expect(conflictedHunk.header == "@@@ -1,1 -1,1 +1,5 @@@",
            "guard against vacuity: the unmerged path really parses as a combined diff")
    let hunk = try #require(try listHunks(at: repo.url.path, area: .unstaged)
        .first { $0.path == "a.txt" }?.hunks.first)
    try stageHunks(ids: [hunk.id], at: repo.url.path)

    // a.txt sorts before m.txt, so its staged block precedes the unmerged
    // marker line — the exact shape measured to poison the header.
    try unstageHunks(ids: [hunk.id], at: repo.url.path)
    let staged = try listHunks(at: repo.url.path, area: .staged)
    #expect(staged.isEmpty)
    let unstagedIDs = try listedHunks(in: repo, area: .unstaged).map(\.id)
    #expect(unstagedIDs == [conflictedHunk.id, hunk.id],
            "a.txt's hunk is back unstaged, after the still-conflicted path's combined listing")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func emptyUnstageIdListIsANoOpAndDoesNotInvokeGitApply(format: FixtureRepository.RefFormat) throws {
    // `git apply` on an empty patch is exit 128, so this only passes if the
    // engine skips the apply entirely.
    let repo = try twoStagedHunksRepo(format)
    defer { repo.destroy() }
    let before = try listedHunks(in: repo, area: .staged).map(\.id)
    try unstageHunks(ids: [], at: repo.url.path)
    let after = try listedHunks(in: repo, area: .staged).map(\.id)
    #expect(after == before)
}

// MARK: - #0212: unstageHunks writes exactly one journal entry per call, so
// undo works after unstaging directly.

@Test(arguments: FixtureRepository.RefFormat.supported())
func unstageHunksWritesExactlyOneJournalEntry(format: FixtureRepository.RefFormat) throws {
    let repo = try twoStagedHunksRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let before = try JournalAnchor.list(in: ctx).count

    let first = try #require(try listedHunks(in: repo, area: .staged).first)
    try unstageHunks(ids: [first.id], at: repo.url.path)

    let after = try JournalAnchor.list(in: ctx).count
    #expect(after - before == 1,
            "unstageHunks called directly must write exactly one journal entry")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func undoAfterUnstageHunksRestoresThePreUnstageState(format: FixtureRepository.RefFormat) throws {
    let repo = try twoStagedHunksRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)

    let beforeStages = try GitProcess().run(
        ["ls-files", "-s"], workingDirectory: repo.url.path).text
    let before = try JournalAnchor.list(in: ctx).count

    let first = try #require(try listedHunks(in: repo, area: .staged).first)
    try unstageHunks(ids: [first.id], at: repo.url.path)

    let afterEntries = try JournalAnchor.list(in: ctx)
    #expect(afterEntries.count == before + 1)
    // `JournalAnchor.list` is creation-ordered oldest-first, so the entry
    // unstageHunks just wrote is the last one.
    let checkpointEntry = try #require(afterEntries.last)

    let wreckedStages = try GitProcess().run(
        ["ls-files", "-s"], workingDirectory: repo.url.path).text
    #expect(wreckedStages != beforeStages,
            "the unstage must actually change the index, or this proves nothing")

    let report = try JournalRestore.restore(checkpointEntry.id, in: ctx)
    #expect(report.restored.contains(.index))

    let afterStages = try GitProcess().run(
        ["ls-files", "-s"], workingDirectory: repo.url.path).text
    #expect(afterStages == beforeStages,
            "index stages must round-trip back to before the unstage")
}
