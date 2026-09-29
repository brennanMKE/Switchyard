// StashChangesTests.swift — Stash Changes… in the Changes view (#0494)

import Foundation
import Testing
@testable import YardGit
@testable import YardUI

private func entry(
    _ path: String, _ staged: WorktreeStatusEntry.State, _ worktree: WorktreeStatusEntry.State
) -> WorktreeStatusEntry {
    var entry = WorktreeStatusEntry(path: path)
    entry.staged = staged
    entry.worktree = worktree
    return entry
}

@Test func stashChangesIsBlockedByConflictsAndByAnEmptyTree() {
    let clean = WorkingChanges(status: WorktreeStatus(entries: []))
    #expect(clean.stashBlockedReason == "There are no changes to stash")

    let conflicted = WorkingChanges(status: WorktreeStatus(entries: [
        entry("fight.txt", .conflicted, .unmerged), entry("a.txt", .modified, .unmodified),
    ]))
    #expect(conflicted.stashBlockedReason == "Resolve the conflicted files first")

    let untrackedOnly = WorkingChanges(status: WorktreeStatus(entries: [
        entry("new.txt", .unmodified, .untracked),
    ]))
    #expect(untrackedOnly.stashBlockedReason == nil, "Include untracked files is on by default")
    #expect(untrackedOnly.hasUntracked)

    let stagedOnly = WorkingChanges(status: WorktreeStatus(entries: [
        entry("a.txt", .modified, .unmodified),
    ]))
    #expect(stagedOnly.stashBlockedReason == nil)
    #expect(!stagedOnly.hasUntracked)
}

@Test func stashHasItsProgressLabelAlertTitleAndEveryStashUndoTitle() {
    let change = WorkingChange.stash(message: nil, includeUntracked: true)
    #expect(change.progressLabel == "Stashing…")
    let failure = change.failure(for: Stash.Refusal.nothingToStash)
    #expect(failure.title == "Couldn’t Stash Changes")
    #expect(failure.message == "There are no changes to stash.")
    #expect(JournalMenuTitles.undo(operation: Stash.pushOperation) == "Undo Stash Changes")
    #expect(JournalMenuTitles.redo(operation: Stash.pushOperation) == "Redo Stash Changes")
    #expect(JournalMenuTitles.undo(operation: Stash.applyOperation) == "Undo Apply Stash")
    #expect(JournalMenuTitles.undo(operation: Stash.popOperation) == "Undo Pop Stash")
    #expect(JournalMenuTitles.undo(operation: Stash.dropOperation) == "Undo Drop Stash")
    #expect(JournalMenuTitles.undo(operation: "drop") == "Undo Delete Commit",
            "the stash must not take over Delete Commit's operation string")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func performStashesWithAMessageAndTheUntrackedFiles(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\n"])])
    try repo.writeUntracked(["a.txt": "a\nedited\n", "new.txt": "new\n"])
    let path = repo.url.path

    try await performWorkingChange(.stash(message: "half done", includeUntracked: true), at: path)

    #expect(WorkingChanges(status: try await gitStatus(at: path)).isClean)
    let item = try #require(try await Stash.list(at: path).first)
    #expect(item.message == "On main: half done")
    #expect(item.includesUntracked)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func aBlankMessageStashesUnderGitsOwnName(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\n"])])
    try repo.writeUntracked(["a.txt": "a\nedited\n", "new.txt": "new\n"])
    let path = repo.url.path

    try await performWorkingChange(.stash(message: "  ", includeUntracked: false), at: path)

    #expect(try await Stash.list(at: path).first?.message.hasPrefix("WIP on main: ") == true)
    #expect(WorkingChanges(status: try await gitStatus(at: path)).unstaged.map(\.path) == ["new.txt"],
            "without Include untracked files the untracked file stays")
}
