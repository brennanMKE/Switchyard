// StagingTests.swift — stage hunks by id (#0040)

import Foundation
import Testing
@testable import YardGit

// MARK: - Fixture helpers (same two-hunk shape HunksTests measures)

/// `line 01` … `line 20`, one per line, trailing newline.
private func base20() -> String {
    (1...20).map { String(format: "line %02d", $0) }.joined(separator: "\n") + "\n"
}

/// A line inserted after `line 03`, and `line 17` replaced — far enough
/// apart that git keeps them as two hunks at -U3.
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

/// The two hunks of the one changed file, in listing order.
private func listedHunks(in repo: FixtureRepository, area: DiffArea) throws -> [Hunk] {
    try listHunks(at: repo.url.path, area: area).flatMap(\.hunks)
}

// MARK: - Staging by id (fixture-backed)

@Test(arguments: FixtureRepository.RefFormat.supported())
func stagingOneHunkByIdMovesItToTheStagedListing(format: FixtureRepository.RefFormat) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }

    let before = try listedHunks(in: repo, area: .unstaged)
    let first = try #require(before.first)
    let second = try #require(before.last)

    try stageHunks(ids: [first.id], at: repo.url.path)

    let staged = try listedHunks(in: repo, area: .staged)
    #expect(staged.map(\.id) == [first.id])
    let unstaged = try listedHunks(in: repo, area: .unstaged)
    #expect(unstaged.map(\.id) == [second.id])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func secondCallWithTheSurvivingIdStillApplies(format: FixtureRepository.RefFormat) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }

    let before = try listedHunks(in: repo, area: .unstaged)
    let first = try #require(before.first)
    let second = try #require(before.last)

    // Staging the first hunk shifts the second's @@ header (measured:
    // @@ -14,7 becomes @@ -15,7) while its body — and so its id — survives.
    // The second call must rebuild the patch from a fresh listing, so the
    // shifted header is git's own and the apply succeeds.
    try stageHunks(ids: [first.id], at: repo.url.path)
    try stageHunks(ids: [second.id], at: repo.url.path)

    let unstaged = try listHunks(at: repo.url.path, area: .unstaged)
    #expect(unstaged.isEmpty)
    let staged = try listedHunks(in: repo, area: .staged)
    #expect(Set(staged.map(\.id)) == Set([first.id, second.id]))
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func twoHunksInOneCallBothStage(format: FixtureRepository.RefFormat) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }

    let ids = try listedHunks(in: repo, area: .unstaged).map(\.id)
    #expect(ids.count == 2)
    try stageHunks(ids: ids, at: repo.url.path)

    let unstaged = try listHunks(at: repo.url.path, area: .unstaged)
    #expect(unstaged.isEmpty)
    let staged = try listedHunks(in: repo, area: .staged)
    #expect(staged.map(\.id) == ids)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func unknownIdStagesNothing(format: FixtureRepository.RefFormat) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }

    let good = try #require(try listedHunks(in: repo, area: .unstaged).first)
    let bogus = "000000000000"
    let error = try #require(throws: StagingError.self) {
        try stageHunks(ids: [good.id, bogus], at: repo.url.path)
    }
    #expect(error == .unknownHunkIDs(ids: [bogus], area: .unstaged))

    // All or none: the resolvable id was not staged either.
    let staged = try listHunks(at: repo.url.path, area: .staged)
    #expect(staged.isEmpty)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func staleIdAfterEditIsRefusedByName(format: FixtureRepository.RefFormat) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }

    let stale = try #require(try listedHunks(in: repo, area: .unstaged).last)

    // Edit inside the second hunk: its body changes, so its id changes and
    // the captured id no longer names anything (#0016's detectability,
    // consumed here as the refusal #0016 could not implement).
    var lines = (1...20).map { String(format: "line %02d", $0) }
    lines[16] = "line 17 CHANGED DIFFERENTLY"
    lines.insert("inserted after 03", at: 3)
    try repo.writeUntracked(["f.txt": lines.joined(separator: "\n") + "\n"])

    let error = try #require(throws: StagingError.self) {
        try stageHunks(ids: [stale.id], at: repo.url.path)
    }
    #expect(error == .unknownHunkIDs(ids: [stale.id], area: .unstaged))
    let staged = try listHunks(at: repo.url.path, area: .staged)
    #expect(staged.isEmpty)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func hunksAcrossTwoFilesStageInOneCall(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a1\na2\na3\n", "b.txt": "b1\nb2\nb3\n"])])
    try repo.writeUntracked(["a.txt": "a1 CHANGED\na2\na3\n", "b.txt": "b1 CHANGED\nb2\nb3\n"])

    let files = try listHunks(at: repo.url.path, area: .unstaged)
    #expect(files.map(\.path) == ["a.txt", "b.txt"])
    let ids = files.flatMap(\.hunks).map(\.id)
    #expect(ids.count == 2)

    try stageHunks(ids: ids, at: repo.url.path)
    let staged = try listHunks(at: repo.url.path, area: .staged)
    #expect(staged.map(\.path) == ["a.txt", "b.txt"])
    let unstaged = try listHunks(at: repo.url.path, area: .unstaged)
    #expect(unstaged.isEmpty)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func stagingADeletionHunkStagesTheDeletion(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["keep.txt": "keep\n", "gone.txt": "gone\n"])])
    try FileManager.default.removeItem(at: repo.url.appendingPathComponent("gone.txt"))

    let files = try listHunks(at: repo.url.path, area: .unstaged)
    let file = try #require(files.first)
    #expect(file.path == "gone.txt")
    let hunk = try #require(file.hunks.first)

    try stageHunks(ids: [hunk.id], at: repo.url.path)
    let staged = try listHunks(at: repo.url.path, area: .staged)
    #expect(staged.first?.path == "gone.txt")
    #expect(staged.first?.oldMode == "100644")   // deleted file mode
    let unstaged = try listHunks(at: repo.url.path, area: .unstaged)
    #expect(unstaged.isEmpty)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func conflictedFileIsUnaddressableButOthersStage(format: FixtureRepository.RefFormat) throws {
    // A conflict in m.txt plus an ordinary edit in a.txt. Unmerged paths
    // print as combined diffs (`diff --cc`, `@@@` headers) ahead of every
    // `diff --git` block — measured — and carry no stable ids, so no id can
    // address a conflicted file's content.
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
    #expect(unmerged.lines.count == 3)   // guard against vacuity: a real conflict
    try repo.writeUntracked(["a.txt": "a1 CHANGED\na2\na3\n"])

    // The conflicted path never appears in the listing.
    let files = try listHunks(at: repo.url.path, area: .unstaged)
    #expect(files.map(\.path) == ["a.txt"])

    // Staging the ordinary file works over an unmerged index (measured:
    // `git apply --cached` touches only its own paths).
    let hunk = try #require(files.first?.hunks.first)
    try stageHunks(ids: [hunk.id], at: repo.url.path)
    let staged = try listHunks(at: repo.url.path, area: .staged)
    #expect(staged.map(\.path) == ["a.txt"])

    // Any id aimed at the conflicted file's content fails typed.
    let bogus = "111111111111"
    let error = try #require(throws: StagingError.self) {
        try stageHunks(ids: [bogus], at: repo.url.path)
    }
    #expect(error == .unknownHunkIDs(ids: [bogus], area: .unstaged))
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func emptyIdListIsANoOpAndDoesNotInvokeGitApply(format: FixtureRepository.RefFormat) throws {
    // `git apply` on an empty patch is exit 128 ("No valid patches in
    // input"), so this only passes if the engine skips the apply entirely.
    let repo = try FixtureRepository.linear(refFormat: format)
    defer { repo.destroy() }
    try stageHunks(ids: [], at: repo.url.path)
    let staged = try listHunks(at: repo.url.path, area: .staged)
    #expect(staged.isEmpty)
}

// MARK: - selectPatch (pure)

private func hunk(path: String, header: String, body: [String]) -> Hunk {
    Hunk(id: HunkParser.hunkID(path: path, body: body), path: path,
         oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
         header: header, body: body)
}

@Test func selectPatchKeepsListingOrderWhateverTheRequestOrder() throws {
    let h1 = hunk(path: "f.txt", header: "@@ -1 +1 @@", body: ["-a", "+A"])
    let h2 = hunk(path: "f.txt", header: "@@ -9 +9 @@", body: ["-b", "+B"])
    let file = FileDiff(path: "f.txt", oldMode: nil, newMode: nil, isBinary: false,
                        headerText: "HEADER\n", hunks: [h1, h2])
    // Request in reverse order: the patch must still put h1 first, because
    // hunks inside one file patch must be in file order for git to apply.
    let patch = try selectPatch(ids: [h2.id, h1.id], from: [file], area: .unstaged)
    #expect(patch == "HEADER\n" + h1.patchText + h2.patchText)
}

@Test func selectPatchEmitsEachFileHeaderOnceAndSkipsUnselectedFiles() throws {
    let h1 = hunk(path: "one.txt", header: "@@ -1 +1 @@", body: ["-x", "+y"])
    let one = FileDiff(path: "one.txt", oldMode: nil, newMode: nil, isBinary: false,
                       headerText: "ONE\n", hunks: [h1])
    let h2 = hunk(path: "two.txt", header: "@@ -1 +1 @@", body: ["-p", "+q"])
    let two = FileDiff(path: "two.txt", oldMode: nil, newMode: nil, isBinary: false,
                       headerText: "TWO\n", hunks: [h2])
    let patch = try selectPatch(ids: [h1.id], from: [one, two], area: .unstaged)
    #expect(patch == "ONE\n" + h1.patchText)
    #expect(!patch.contains("TWO"))
}

@Test func selectPatchReportsMissingIdsInCallerOrderDeduplicated() {
    let h1 = hunk(path: "f.txt", header: "@@ -1 +1 @@", body: ["-a", "+A"])
    let file = FileDiff(path: "f.txt", oldMode: nil, newMode: nil, isBinary: false,
                        headerText: "H\n", hunks: [h1])
    do {
        _ = try selectPatch(ids: ["bbbbbbbbbbbb", h1.id, "aaaaaaaaaaaa", "bbbbbbbbbbbb"],
                            from: [file], area: .staged)
        Issue.record("expected unknownHunkIDs")
    } catch let error as StagingError {
        #expect(error == .unknownHunkIDs(ids: ["bbbbbbbbbbbb", "aaaaaaaaaaaa"],
                                         area: .staged))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func stagingErrorMapsToRepositoryError() {
    let error = StagingError.unknownHunkIDs(ids: ["abc"], area: .unstaged)
    #expect(error.exitClass == .repositoryError)
}

// MARK: - #0212: stageHunks writes exactly one journal entry per call, so
// undo works after staging directly.

@Test(arguments: FixtureRepository.RefFormat.supported())
func stageHunksWritesExactlyOneJournalEntry(format: FixtureRepository.RefFormat) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let before = try JournalAnchor.list(in: ctx).count

    let first = try #require(try listedHunks(in: repo, area: .unstaged).first)
    try stageHunks(ids: [first.id], at: repo.url.path)

    let after = try JournalAnchor.list(in: ctx).count
    #expect(after - before == 1,
            "stageHunks called directly must write exactly one journal entry")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func undoAfterStageHunksRestoresThePreStageState(format: FixtureRepository.RefFormat) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)

    let beforeStages = try GitProcess().run(
        ["ls-files", "-s"], workingDirectory: repo.url.path).text
    let before = try JournalAnchor.list(in: ctx).count

    let first = try #require(try listedHunks(in: repo, area: .unstaged).first)
    try stageHunks(ids: [first.id], at: repo.url.path)

    let afterEntries = try JournalAnchor.list(in: ctx)
    #expect(afterEntries.count == before + 1)
    // `JournalAnchor.list` is creation-ordered oldest-first, so the entry
    // stageHunks just wrote is the last one.
    let checkpointEntry = try #require(afterEntries.last)

    let wreckedStages = try GitProcess().run(
        ["ls-files", "-s"], workingDirectory: repo.url.path).text
    #expect(wreckedStages != beforeStages,
            "the stage must actually change the index, or this proves nothing")

    let report = try JournalRestore.restore(checkpointEntry.id, in: ctx)
    #expect(report.restored.contains(.index))

    let afterStages = try GitProcess().run(
        ["ls-files", "-s"], workingDirectory: repo.url.path).text
    #expect(afterStages == beforeStages,
            "index stages must round-trip back to before the stage")
}
