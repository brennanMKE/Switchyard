// WorkingChangesTests.swift — the Changes view's data layer (#0441)

import Foundation
import Testing
@testable import YardGit
@testable import YardUI

private func entry(
    _ path: String, _ staged: WorktreeStatusEntry.State, _ worktree: WorktreeStatusEntry.State,
    originalPath: String? = nil
) -> WorktreeStatusEntry {
    var entry = WorktreeStatusEntry(path: path)
    entry.staged = staged
    entry.worktree = worktree
    entry.originalPath = originalPath
    return entry
}

@Test func thePartitionPutsEachSideOfAnEntryInItsOwnListAndConflictsApart() {
    let status = WorktreeStatus(entries: [
        entry("both.txt", .modified, .modified),
        entry("staged.txt", .added, .unmodified),
        entry("new.txt", .unmodified, .untracked),
        entry("gone.txt", .unmodified, .deleted),
        entry("r2.txt", .modified, .unmodified, originalPath: "r.txt"),
        entry("fight.txt", .conflicted, .unmerged),
    ])

    let changes = WorkingChanges(status: status)

    #expect(changes.staged.map(\.path) == ["both.txt", "staged.txt", "r2.txt"])
    #expect(changes.staged.map(\.state) == [.modified, .added, .modified])
    #expect(changes.staged.last?.originalPath == "r.txt")
    #expect(changes.unstaged.map(\.path) == ["both.txt", "new.txt", "gone.txt"])
    #expect(changes.unstaged.map(\.state) == [.modified, .untracked, .deleted])
    #expect(changes.conflicted.map(\.path) == ["fight.txt"])
    // An `MM` file is a row in both lists; the two must not share an id.
    #expect(changes.staged[0].id != changes.unstaged[0].id)
    #expect(!changes.isClean)
    #expect(WorkingChanges(status: WorktreeStatus(entries: [])).isClean)
}

@Test func unstagingARenameNamesBothOfItsPaths() {
    let rows = [
        WorkingChanges.Row(side: .staged, path: "r2.txt", originalPath: "r.txt", state: .modified),
        WorkingChanges.Row(side: .staged, path: "m.txt", state: .modified),
    ]
    #expect(WorkingChanges.unstagePaths(for: rows) == ["r2.txt", "r.txt", "m.txt"])
}

@Test func commitIsBlockedByConflictsThenAnEmptyIndexThenABlankMessage() {
    let staged = WorkingChanges.Row(side: .staged, path: "a.txt", state: .modified)
    let conflict = WorkingChanges.Row(side: .conflicted, path: "c.txt", state: .conflicted)

    let conflicted = WorkingChanges(staged: [staged], unstaged: [], conflicted: [conflict])
    #expect(conflicted.commitBlockedReason(message: "msg") == "Resolve the conflicted files first")
    let empty = WorkingChanges(staged: [], unstaged: [], conflicted: [])
    #expect(empty.commitBlockedReason(message: "msg") == "Stage a change to commit")
    let ready = WorkingChanges(staged: [staged], unstaged: [], conflicted: [])
    #expect(ready.commitBlockedReason(message: " \n ") == "Write a commit message")
    #expect(ready.commitBlockedReason(message: "Fix it") == nil)
}

@Test func aGitRefusalShowsGitsStderrNotTheArgumentVector() {
    let hook = GitProcess.Failure.exited(
        code: 1, stderr: "lint: trailing whitespace in a.txt\n",
        arguments: ["commit", "-m", "a long message"])

    let failure = WorkingChange.commit(message: "a long message").failure(for: hook)

    #expect(failure.title == "Couldn’t Commit")
    #expect(failure.message == "lint: trailing whitespace in a.txt")
    #expect(WorkingChange.stageHunk(id: "x").failure(for: hook).title == "Couldn’t Stage")
    #expect(WorkingChange.unstageFiles(["a"]).failure(for: hook).title == "Couldn’t Unstage")
    #expect(WorkingChange.commit(message: "m").progressLabel == "Committing…")
    #expect(WorkingChange.stageFiles(["a"]).progressLabel == "Staging…")
}

@Test func aSigningFailureSaysNothingWasCommitted() {
    let failure = WorkingChange.commit(message: "m")
        .failure(for: CommitCreate.Failure.signingFailed(reason: "no key"))
    #expect(failure.message.hasPrefix("signing failed: no key"))
    #expect(failure.message.hasSuffix(
        "Nothing was committed. Check that your signing key or agent is available, then try again."))
}

@Test func theChangesViewsOperationsHaveUndoTitles() {
    #expect(JournalMenuTitles.undo(operation: "stage") == "Undo Stage")
    #expect(JournalMenuTitles.undo(operation: "unstage") == "Undo Unstage")
    #expect(JournalMenuTitles.redo(operation: "commit") == "Redo Commit")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func theLoaderAndPerformerStageAHunkAndCommitIt(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    try repo.writeUntracked(["a.txt": "one\ntwo\n", "new.txt": "new\n"])
    let path = repo.url.path

    let before = try await loadWorkingDiffs(at: path)
    #expect(before.file("new.txt", staged: false) == nil, "git diff lists no untracked file")
    let hunk = try #require(before.file("a.txt", staged: false)?.hunks.first)

    try await performWorkingChange(.stageHunk(id: hunk.id), at: path)
    let after = try await loadWorkingDiffs(at: path)
    #expect(after.file("a.txt", staged: true)?.hunks.map(\.id) == [hunk.id])
    #expect(after.file("a.txt", staged: false) == nil)

    let head = try repo.revParse("HEAD")
    try await performWorkingChange(.commit(message: "two"), at: path)
    #expect(try repo.revParse("HEAD~1") == head)
    #expect(try await loadWorkingDiffs(at: path).staged.isEmpty)
}
