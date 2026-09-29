// StashSnapshotTests.swift — the stash list as a journal piece (#0490)

import Foundation
import Testing
@testable import YardGit

/// `git stash list` as `(oid, message)` pairs, newest first.
private func stashList(in repo: FixtureRepository) throws -> [StashSnapshot.Entry] {
    try StashSnapshot.capture(in: WorktreeContext.resolve(path: repo.url.path)).entries
}

/// One commit holding `a.txt`, then three stashes made with `git stash
/// push -m`: `one`, `two`, `three` (so `stash@{0}` is `three`). Each edit
/// has a different length: a same-size rewrite inside one second is
/// racily clean to git, and `stash push` then saves nothing (measured).
private func stashedRepo(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["a.txt": "a\n"])])
    let git = GitProcess()
    for (index, name) in ["one", "two", "three"].enumerated() {
        try repo.writeUntracked(["a.txt": "a\n" + String(repeating: "x", count: index + 1) + "\n"])
        try git.run(["stash", "push", "-q", "-m", name], workingDirectory: repo.url.path)
    }
    return repo
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func captureListsTheStashesNewestFirstWithTheirMessages(format: FixtureRepository.RefFormat) throws {
    let repo = try stashedRepo(format)
    defer { repo.destroy() }

    let entries = try stashList(in: repo)

    #expect(entries.map(\.message) == ["On main: three", "On main: two", "On main: one"])
    #expect(entries.first?.oid == (try repo.revParse("refs/stash")))
    #expect(entries.last?.oid == (try repo.revParse("stash@{2}")))
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func captureOfARepositoryWithNoStashIsEmpty(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\n"])])

    #expect(try stashList(in: repo).isEmpty)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func undoOfADroppedMiddleStashBringsItBack(format: FixtureRepository.RefFormat) throws {
    let repo = try stashedRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let before = try stashList(in: repo)

    try JournalCheckpoint.checkpoint(operation: "stash-drop", in: ctx)
    try GitProcess().run(["stash", "drop", "-q", "stash@{1}"], workingDirectory: repo.url.path)
    #expect(try stashList(in: repo).count == 2, "the drop must change the list, or undo proves nothing")
    #expect(try repo.revParse("refs/stash") == before[0].oid,
            "dropping stash@{1} leaves refs/stash alone, so restoring refs alone cannot bring it back")

    let reports = try JournalUndo.undo(in: ctx)

    #expect(try stashList(in: repo) == before)
    #expect(reports.first?.restored.contains(.stash) == true)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func undoOfADroppedTopStashKeepsItsMessage(format: FixtureRepository.RefFormat) throws {
    let repo = try stashedRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let before = try stashList(in: repo)

    try JournalCheckpoint.checkpoint(operation: "stash-drop", in: ctx)
    try GitProcess().run(["stash", "drop", "-q"], workingDirectory: repo.url.path)

    try JournalUndo.undo(in: ctx)

    // Restoring refs/stash alone lists `stash@{0}: ` with no message and
    // keeps the dropped line's successor twice (measured).
    #expect(try stashList(in: repo) == before)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func undoOfAStashPushOntoAnEmptyListLeavesNoStash(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\n"])])
    try repo.writeUntracked(["a.txt": "a\nedited\n"])
    let ctx = try WorktreeContext.resolve(path: repo.url.path)

    try JournalCheckpoint.checkpoint(operation: "stash", in: ctx)
    try GitProcess().run(["stash", "push", "-q"], workingDirectory: repo.url.path)
    #expect(try stashList(in: repo).count == 1)

    try JournalUndo.undo(in: ctx)

    #expect(try stashList(in: repo).isEmpty,
            "restore leaves a ref its snapshot did not record (decision 20), so the stash piece must")
    #expect(!(try repo.refNames().contains("refs/stash")))
    #expect(try String(contentsOf: repo.url.appendingPathComponent("a.txt"), encoding: .utf8)
            == "a\nedited\n", "the stashed edit is back in the worktree")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func redoAfterUndoDropDropsItAgain(format: FixtureRepository.RefFormat) throws {
    let repo = try stashedRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)

    try JournalCheckpoint.checkpoint(operation: "stash-drop", in: ctx)
    try GitProcess().run(["stash", "drop", "-q", "stash@{1}"], workingDirectory: repo.url.path)
    let afterDrop = try stashList(in: repo)
    try JournalUndo.undo(in: ctx)

    try JournalUndo.redo(in: ctx)

    #expect(try stashList(in: repo) == afterDrop)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func everyStashCommitIsAKeepAliveParent(format: FixtureRepository.RefFormat) throws {
    let repo = try stashedRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let oids = try stashList(in: repo).map(\.oid)

    let entry = try JournalCheckpoint.checkpoint(operation: "stash-drop", in: ctx)

    let parents = try GitProcess().run(
        ["rev-list", "--parents", "-n", "1", entry.commit], workingDirectory: repo.url.path)
        .lines.first?.split(separator: " ").dropFirst().map(String.init) ?? []
    for oid in oids {
        #expect(parents.contains(oid), "a dropped stash would be reachable from no entry")
    }
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func anEntryWithNoStashPieceLeavesTheListAlone(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\n"])])
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    // An entry as a pre-#0490 build wrote it: no `stash` tree entry.
    let old = try JournalCheckpoint.writeEntry(
        capturing: RefSnapshot.capture(in: ctx), operation: "old", in: ctx)
    try repo.writeUntracked(["a.txt": "a\nedited\n"])
    try GitProcess().run(["stash", "push", "-q"], workingDirectory: repo.url.path)

    let report = try JournalRestore.restore(old.id, in: ctx)

    #expect(try stashList(in: repo).count == 1)
    #expect(!report.restored.contains(.stash))
}

@Test
func serializationRoundTripsAndAnEmptyListIsAnEmptyBlob() throws {
    let snapshot = StashSnapshot(entries: [
        .init(oid: String(repeating: "a", count: 40), message: "On main: two words"),
        .init(oid: String(repeating: "b", count: 40), message: ""),
    ])
    #expect(try StashSnapshot(serialized: snapshot.serialized()) == snapshot)
    #expect(StashSnapshot(entries: []).serialized().isEmpty)
    #expect(throws: StashSnapshot.Error.malformedLine("nonsense")) {
        try StashSnapshot(serialized: Data("nonsense\n".utf8))
    }
}
