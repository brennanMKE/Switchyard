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

// MARK: - #0470: Discard (guide §11 decision 34)

@Test func discardIsOfferedOnUnstagedRowsExceptIntentToAdd() {
    let changes = WorkingChanges(status: WorktreeStatus(entries: [
        entry("both.txt", .modified, .modified),
        entry("new.txt", .unmodified, .untracked),
        entry("ita.txt", .unmodified, .added),
        entry("gone.txt", .unmodified, .deleted),
        entry("staged.txt", .added, .unmodified),
        entry("fight.txt", .conflicted, .unmerged),
    ]))

    #expect(changes.discardableRows.map(\.path) == ["both.txt", "new.txt", "gone.txt"])
    #expect(!WorkingChanges.canDiscard(changes.staged[0]), "a staged row offers no discard")
    #expect(!WorkingChanges.canDiscard(changes.conflicted[0]), "a conflicted row offers no discard")
}

@Test func aFileDiscardConfirmationNamesTheFilesAndSaysWhatHappens() {
    let modified = WorkingChanges.Row(side: .unstaged, path: "a.txt", state: .modified)
    let untracked = WorkingChanges.Row(side: .unstaged, path: "new.txt", state: .untracked)

    let one = DiscardConfirmation(rows: [modified])
    #expect(one.title == "Discard changes to a.txt?")
    #expect(one.message == "a.txt\n\nUnstaged changes are thrown away. "
        + "Staged changes stay. Edit ▸ Undo Discard brings them back.")
    #expect(one.change == .discardFiles(["a.txt"]))

    let two = DiscardConfirmation(rows: [modified, untracked])
    #expect(two.title == "Discard changes to 2 files?")
    #expect(two.message == "a.txt\nnew.txt\n\nUnstaged changes are thrown away and untracked "
        + "files are deleted. Staged changes stay. Edit ▸ Undo Discard brings them back.")
    #expect(two.change == .discardFiles(["a.txt", "new.txt"]))
}

@Test func aLongDiscardListNamesTenFilesAndCountsTheRest() {
    let rows = (1...12).map {
        WorkingChanges.Row(side: .unstaged, path: "f\($0).txt", state: .modified)
    }
    let confirmation = DiscardConfirmation(rows: rows)
    #expect(confirmation.title == "Discard changes to 12 files?")
    #expect(confirmation.message.hasPrefix((1...10).map { "f\($0).txt" }.joined(separator: "\n")
        + "\nand 2 more\n\n"))
    #expect(!confirmation.message.contains("f11.txt"))
    #expect(confirmation.change == .discardFiles(rows.map(\.path)))
}

@Test func aHunkDiscardConfirmationNamesTheFileAndTheLine() {
    let hunk = Hunk(id: "abc123", path: "t.txt", oldStart: 20, oldCount: 1, newStart: 18,
                    newCount: 1, header: "@@ -20 +18 @@", body: ["-line 18", "+line 18 edited"])
    let confirmation = DiscardConfirmation(hunk: hunk)
    #expect(confirmation.title == "Discard this change to t.txt?")
    #expect(confirmation.message == "The change at line 18 goes back to the staged version. "
        + "Edit ▸ Undo Discard brings it back.")
    #expect(confirmation.change == .discardHunk(id: "abc123"))
}

@Test func discardHasItsOwnProgressLabelAlertTitleAndUndoTitle() {
    let refusal = DiscardChanges.Refusal.nestedRepository(path: "inner/")
    #expect(WorkingChange.discardFiles(["a"]).progressLabel == "Discarding…")
    #expect(WorkingChange.discardHunk(id: "x").progressLabel == "Discarding…")
    let failure = WorkingChange.discardFiles(["inner/"]).failure(for: refusal)
    #expect(failure.title == "Couldn’t Discard")
    #expect(failure.message == refusal.description)
    #expect(WorkingChange.discardHunk(id: "x").failure(for: refusal).title == "Couldn’t Discard")
    #expect(JournalMenuTitles.undo(operation: "discard") == "Undo Discard")
    #expect(JournalMenuTitles.redo(operation: "discard") == "Redo Discard")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func performDiscardsAFileAndAHunk(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    let lines = (1...20).map { String(format: "line %02d\n", $0) }
    try repo.build([.init("base", files: ["t.txt": lines.joined(), "a.txt": "a\n"])])
    var edited = lines
    edited[1] = "line 02 edited\n"
    edited[17] = "line 18 edited\n"
    try repo.writeUntracked(["t.txt": edited.joined(), "a.txt": "a edited\n", "new.txt": "new\n"])
    let path = repo.url.path

    try await performWorkingChange(.discardFiles(["a.txt", "new.txt"]), at: path)
    let afterFiles = WorkingChanges(status: try await gitStatus(at: path))
    #expect(afterFiles.unstaged.map(\.path) == ["t.txt"])
    #expect(afterFiles.staged.isEmpty, "discard staged the files instead")
    #expect(try String(contentsOf: repo.url.appendingPathComponent("a.txt"), encoding: .utf8) == "a\n")

    let first = try #require(try await loadWorkingDiffs(at: path).file("t.txt", staged: false)?.hunks.first)
    try await performWorkingChange(.discardHunk(id: first.id), at: path)
    let hunks = try #require(try await loadWorkingDiffs(at: path).file("t.txt", staged: false)?.hunks)
    #expect(hunks.count == 1)
    #expect(hunks.first?.body.contains("+line 18 edited") == true)
    #expect(try await loadWorkingDiffs(at: path).staged.isEmpty, "discard staged the hunk instead")
}

// MARK: - #0479: line actions (guide §11 decision 35)

@Test func aLineDiscardConfirmationCountsTheLines() {
    let hunk = Hunk(id: "abc123", path: "t.txt", oldStart: 1, oldCount: 2, newStart: 1,
                    newCount: 2, header: "@@ -1,2 +1,2 @@", body: ["-a", "+A", " b"])
    let one = DiscardConfirmation(lines: [1], of: hunk)
    #expect(one.title == "Discard 1 line of t.txt?")
    #expect(one.message == "The selected lines go back to the staged version. "
        + "Edit ▸ Undo Discard brings them back.")
    #expect(one.change == .discardLines(hunkID: "abc123", lines: [1]))
    #expect(DiscardConfirmation(lines: [0, 1], of: hunk).title == "Discard 2 lines of t.txt?")
}

@Test func theHunkButtonSendsTheHunkOrItsSelectedLines() {
    let hunk = Hunk(id: "abc123", path: "t.txt", oldStart: 1, oldCount: 1, newStart: 1,
                    newCount: 1, header: "@@ -1 +1 @@", body: ["-a", "+A"])
    #expect(WorkingChange.stageOrUnstage(hunk, lines: [], staged: false) == .stageHunk(id: "abc123"))
    #expect(WorkingChange.stageOrUnstage(hunk, lines: [], staged: true) == .unstageHunk(id: "abc123"))
    #expect(WorkingChange.stageOrUnstage(hunk, lines: [1], staged: false)
        == .stageLines(hunkID: "abc123", lines: [1]))
    #expect(WorkingChange.stageOrUnstage(hunk, lines: [0, 1], staged: true)
        == .unstageLines(hunkID: "abc123", lines: [0, 1]))
}

@Test func lineActionsShareTheirHunkActionsLabelsAndTitles() {
    let failure = GitProcess.Failure.exited(code: 1, stderr: "error: patch failed\n", arguments: ["apply"])
    #expect(WorkingChange.stageLines(hunkID: "x", lines: [1]).progressLabel == "Staging…")
    #expect(WorkingChange.unstageLines(hunkID: "x", lines: [1]).progressLabel == "Unstaging…")
    #expect(WorkingChange.discardLines(hunkID: "x", lines: [1]).progressLabel == "Discarding…")
    #expect(WorkingChange.stageLines(hunkID: "x", lines: [1]).failure(for: failure).title == "Couldn’t Stage")
    #expect(WorkingChange.unstageLines(hunkID: "x", lines: [1]).failure(for: failure).title == "Couldn’t Unstage")
    #expect(WorkingChange.discardLines(hunkID: "x", lines: [1]).failure(for: failure).title == "Couldn’t Discard")
    #expect(WorkingChange.stageLines(hunkID: "x", lines: [1]).failure(for: failure).message == "error: patch failed")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func performStagesUnstagesAndDiscardsLines(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["t.txt": "a\nb\nc\nd\ne\n"])])
    // One hunk: [" a", " b", "-c", "+C", "+X", " d", " e"].
    try repo.writeUntracked(["t.txt": "a\nb\nC\nX\nd\ne\n"])
    let path = repo.url.path
    let index = { try GitProcess().run(["show", ":t.txt"], workingDirectory: path).text }

    let unstaged = try #require(try await loadWorkingDiffs(at: path).file("t.txt", staged: false)?.hunks.first)
    try await performWorkingChange(.stageLines(hunkID: unstaged.id, lines: [2, 3]), at: path)
    #expect(try index() == "a\nb\nC\nd\ne\n")

    let staged = try #require(try await loadWorkingDiffs(at: path).file("t.txt", staged: true)?.hunks.first)
    #expect(staged.body == [" a", " b", "-c", "+C", " d", " e"])
    try await performWorkingChange(.unstageLines(hunkID: staged.id, lines: [3]), at: path)
    #expect(try index() == "a\nb\nd\ne\n")

    let rest = try #require(try await loadWorkingDiffs(at: path).file("t.txt", staged: false)?.hunks.first)
    let x = try #require(rest.body.firstIndex(of: "+X"))
    try await performWorkingChange(.discardLines(hunkID: rest.id, lines: [x]), at: path)
    #expect(try String(contentsOf: repo.url.appendingPathComponent("t.txt"), encoding: .utf8)
        == "a\nb\nC\nd\ne\n")
}

@Test func aSelectionFollowsItsFileToTheOtherSide() {
    let changes = WorkingChanges(status: WorktreeStatus(entries: [
        entry("both.txt", .modified, .modified),
        entry("staged.txt", .modified, .unmodified),
        entry("edited.txt", .unmodified, .modified),
    ]))
    // Still on its own side: stays.
    #expect(changes.sideShowing(path: "both.txt", staged: false) == false)
    #expect(changes.sideShowing(path: "both.txt", staged: true) == true)
    #expect(changes.sideShowing(path: "edited.txt", staged: false) == false)
    // Staged whole: selected as unstaged, now only staged.
    #expect(changes.sideShowing(path: "staged.txt", staged: false) == true)
    // Unstaged whole: selected as staged, now only unstaged.
    #expect(changes.sideShowing(path: "edited.txt", staged: true) == false)
    // Gone from both lists.
    #expect(changes.sideShowing(path: "committed.txt", staged: true) == nil)
}
