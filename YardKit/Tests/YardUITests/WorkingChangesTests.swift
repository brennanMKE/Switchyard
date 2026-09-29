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

// MARK: - #0465: Amend (guide §11 decision 33)

private func whereAmI(
    merge: Bool = false, rebase: Bool = false, cherryPick: Bool = false, revert: Bool = false
) -> WhereAmI {
    WhereAmI(
        branch: "main", upstream: nil, ahead: nil, behind: nil,
        isMidRebase: rebase, isMidMerge: merge, isMidCherryPick: cherryPick,
        isMidRevert: revert, stashCount: 0, untrackedCount: 0, unstagedCount: 0,
        stagedCount: 0, hasConflicts: false, conflictCount: 0,
        headOID: "a1b2c3d", rawHead: "a1b2c3d")
}

@Test func turningAmendOnShowsHeadsMessageAndTurningItOffRestoresTheDraft() {
    var draft = CommitDraft(message: "half-written")
    #expect(draft.change == .commit(message: "half-written"))

    draft.setAmending(true, headMessage: "Last commit\n\nIts body.")
    #expect(draft.isAmending)
    #expect(draft.message == "Last commit\n\nIts body.")
    draft.message += " Fixed."
    #expect(draft.change == .amend(message: "Last commit\n\nIts body. Fixed."))

    draft.setAmending(true, headMessage: "ignored")
    #expect(draft.message == "Last commit\n\nIts body. Fixed.", "setting the current value changes nothing")

    draft.setAmending(false, headMessage: "ignored")
    #expect(!draft.isAmending)
    #expect(draft.message == "half-written")
    #expect(draft.change == .commit(message: "half-written"))
}

@Test func amendNeedsNoStagedChangeButIsBlockedByConflictsABlankMessageOrAnUnavailableHead() {
    let clean = WorkingChanges(staged: [], unstaged: [], conflicted: [])
    let conflicted = WorkingChanges(
        staged: [], unstaged: [],
        conflicted: [.init(side: .conflicted, path: "c.txt", state: .conflicted)])
    var draft = CommitDraft()
    draft.setAmending(true, headMessage: "Last commit")

    #expect(draft.blockedReason(for: clean, amendUnavailable: nil) == nil, "a message-only amend")
    #expect(draft.blockedReason(for: conflicted, amendUnavailable: nil) == "Resolve the conflicted files first")
    #expect(draft.blockedReason(for: clean, amendUnavailable: "pushed") == "pushed")
    draft.message = " \n"
    #expect(draft.blockedReason(for: clean, amendUnavailable: nil) == "Write a commit message")

    draft.setAmending(false, headMessage: "")
    #expect(draft.blockedReason(for: clean, amendUnavailable: nil) == "Stage a change to commit")
}

@Test func theAmendCheckboxIsUnavailableDuringAnOperationWhileLoadingAndWhenRefused() {
    let ok = AmendHead.Target(oid: "abc", message: "m", refusal: nil)
    let pushed = AmendHead.Target(oid: "abc", message: "m", refusal: .pushed(remoteRef: "origin/main"))

    #expect(WorkingChanges.amendUnavailableReason(target: ok, whereAmI: whereAmI()) == nil)
    #expect(WorkingChanges.amendUnavailableReason(target: nil, whereAmI: whereAmI()) == "Reading the last commit…")
    #expect(WorkingChanges.amendUnavailableReason(target: pushed, whereAmI: whereAmI())
        == AmendHead.Refusal.pushed(remoteRef: "origin/main").description)
    #expect(WorkingChanges.amendUnavailableReason(target: ok, whereAmI: whereAmI(merge: true))
        == "Finish or abort the merge first")
    #expect(WorkingChanges.amendUnavailableReason(target: ok, whereAmI: whereAmI(rebase: true))
        == "Finish or abort the rebase first")
    #expect(WorkingChanges.amendUnavailableReason(target: ok, whereAmI: whereAmI(cherryPick: true))
        == "Finish or abort the cherry-pick first")
    #expect(WorkingChanges.amendUnavailableReason(target: ok, whereAmI: whereAmI(revert: true))
        == "Finish or abort the revert first")
}

@Test func amendHasItsOwnProgressLabelAlertTitleAndUndoTitle() {
    #expect(WorkingChange.amend(message: "m").progressLabel == "Amending…")
    let hook = GitProcess.Failure.exited(code: 1, stderr: "lint: no\n", arguments: ["commit", "--amend"])
    let failure = WorkingChange.amend(message: "m").failure(for: hook)
    #expect(failure.title == "Couldn’t Amend")
    #expect(failure.message == "lint: no")
    #expect(JournalMenuTitles.undo(operation: "amend") == "Undo Amend")
    #expect(JournalMenuTitles.redo(operation: "amend") == "Redo Amend")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func theLoaderAndPerformAmendHead(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([
        .init("base", files: ["a.txt": "one\n"]),
        .init("second", files: ["b.txt": "bee\n"]),
    ])
    let path = repo.url.path
    let parent = try repo.revParse("HEAD~1")

    let target = try await loadAmendTarget(at: path)
    #expect(target.oid == (try repo.revParse("HEAD")))
    #expect(target.message == "second")
    #expect(target.refusal == nil)

    try await performWorkingChange(.amend(message: "second, amended"), at: path)
    #expect(try repo.revParse("HEAD~1") == parent)
    #expect(try await loadAmendTarget(at: path).message == "second, amended")
}
