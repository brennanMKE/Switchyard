// ConflictHandoffTests.swift — the conflict hand-off's Abort and Continue
// (#0394)
//
// Each fixture test drives the REAL engine operation into its measured
// `.blockedOnConflicts` stop, asserts the stop through `whereAmI(path:)` —
// the same probe the header renders — and only then runs
// `ConflictHandoff.runAbort`/`.runContinue` against it. The five Abort tests
// decide the facts section's unverified claim empirically: the journal undo
// alone cannot clear a merge/revert/pick stop (JournalRestore steps 8–8c
// restore the rebase layouts only), and the operation's own `--abort` after
// the undo must remove every state file the `whereAmI` flags read.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

private let git = GitProcess()

/// Whether `name`'s state file exists — via `rev-parse --git-path` +
/// `fileExists`, the raw probe `runAbort` itself uses and the raw probe the
/// issue's plan names. Asks git where the file lives rather than assuming
/// `.git/`, so the check is worktree- and reftable-correct.
private func stateFileExists(_ name: String, in repo: FixtureRepository) -> Bool {
    guard let out = try? git.run(
        ["rev-parse", "--path-format=absolute", "--git-path", name],
        workingDirectory: repo.url.path),
        let path = out.lines.first, !path.isEmpty
    else { return false }
    return FileManager.default.fileExists(atPath: path)
}

/// Resolves the index's conflict by writing `files`' content and staging it
/// — the step between the `.blockedOnConflicts` stop and a Continue, exactly
/// what the resolve pane's Submit stages.
private func resolveByStaging(
    _ files: [String: String], in repo: FixtureRepository
) throws {
    try repo.writeUntracked(files)
    try git.run(["add", "-A"], workingDirectory: repo.url.path, extraEnvironment: hermetic)
}

// MARK: - Abort clears each conflicted operation

@Test func abortClearsConflictedMerge() throws {
    // `c1 → c2` on `main` plus `f1` off `c1` on `feature` — both sides
    // rewrite line 3, so a --no-ff merge stops on f.txt.
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nA3\nl4\nl5\n"]),
        .init("f1", parents: ["c1"], files: ["f.txt": "l1\nl2\nB3\nl4\nl5\n"]),
    ])
    try repo.branch("feature", at: "f1")
    try repo.checkout("main")
    let mainBefore = try repo.revParse("refs/heads/main")

    let thrown = #expect(throws: MergeError.self) {
        _ = try Merge.run(
            branch: "feature", intent: .noFastForward, at: repo.url.path,
            extraEnvironment: hermetic)
    }
    guard case .blockedOnConflicts = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    // The stop, seen through the probe the header renders.
    let stopped = try whereAmI(path: repo.url.path)
    #expect(stopped.isMidMerge, "MERGE_HEAD is the resumable state the stop leaves")
    #expect(stopped.hasConflicts)
    #expect(stateFileExists("MERGE_HEAD", in: repo))

    try ConflictHandoff.runAbort(at: repo.url.path)

    let after = try whereAmI(path: repo.url.path)
    #expect(!after.isMidMerge, "the abort clears the state the undo alone leaves")
    #expect(!after.isMidRebase)
    #expect(!after.isMidCherryPick)
    #expect(!after.isMidRevert)
    #expect(!after.hasConflicts)
    #expect(!stateFileExists("MERGE_HEAD", in: repo), "MERGE_HEAD is gone from disk")
    #expect(try repo.revParse("refs/heads/main") == mainBefore, "the tip is restored")
    #expect(try repo.revParse("HEAD") == mainBefore, "HEAD is re-attached")
    #expect(after.branch == "main")
}

@Test func abortClearsConflictedRevert() throws {
    // Every commit rewrites line 3 of the same file: reverting c2 (which
    // set it to T3) while the tip's tree carries c3's Z3 collides on the
    // very line the inverse change restores.
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nT3\nl4\nl5\n"]),
        .init("c3", files: ["f.txt": "l1\nl2\nZ3\nl4\nl5\n"]),
    ])
    let c2 = try #require(repo.oids["c2"])
    let mainBefore = try repo.revParse("refs/heads/main")

    let thrown = #expect(throws: ReplayError.self) {
        _ = try Replay.revert(commit: c2, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case .blockedOnConflicts = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    let stopped = try whereAmI(path: repo.url.path)
    #expect(stopped.isMidRevert)
    #expect(stopped.hasConflicts)
    #expect(stateFileExists("REVERT_HEAD", in: repo))

    try ConflictHandoff.runAbort(at: repo.url.path)

    let after = try whereAmI(path: repo.url.path)
    #expect(!after.isMidRevert, "the abort clears REVERT_HEAD")
    #expect(!after.isMidMerge)
    #expect(!after.isMidCherryPick)
    #expect(!after.isMidRebase)
    #expect(!after.hasConflicts)
    #expect(!stateFileExists("REVERT_HEAD", in: repo), "REVERT_HEAD is gone from disk")
    #expect(try repo.revParse("refs/heads/main") == mainBefore, "the tip is restored")
    #expect(try repo.revParse("HEAD") == mainBefore)
    #expect(after.branch == "main")
}

@Test func abortClearsConflictedCherryPick() throws {
    // `c1 → c2` on `main` plus a side commit off `c1` that rewrites the
    // same line c2 rewrites: picking the side commit onto `main` conflicts.
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nA3\nl4\nl5\n"]),
        .init("side", parents: ["c1"], files: ["f.txt": "l1\nl2\nS3\nl4\nl5\n"]),
    ])
    try repo.branch("main", at: "c2")
    try repo.checkout("main")
    let side = try #require(repo.oids["side"])
    let mainBefore = try repo.revParse("refs/heads/main")

    let thrown = #expect(throws: ReplayError.self) {
        _ = try Replay.cherryPick(commit: side, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case .blockedOnConflicts = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    let stopped = try whereAmI(path: repo.url.path)
    #expect(stopped.isMidCherryPick)
    #expect(stopped.hasConflicts)
    #expect(stateFileExists("CHERRY_PICK_HEAD", in: repo))

    try ConflictHandoff.runAbort(at: repo.url.path)

    let after = try whereAmI(path: repo.url.path)
    #expect(!after.isMidCherryPick, "the abort clears CHERRY_PICK_HEAD")
    #expect(!after.isMidMerge)
    #expect(!after.isMidRevert)
    #expect(!after.isMidRebase)
    #expect(!after.hasConflicts)
    #expect(!stateFileExists("CHERRY_PICK_HEAD", in: repo),
            "CHERRY_PICK_HEAD is gone from disk")
    #expect(try repo.revParse("refs/heads/main") == mainBefore, "the tip is restored")
    #expect(try repo.revParse("HEAD") == mainBefore)
    #expect(after.branch == "main")
}

@Test func abortClearsConflictedFixupRebase() throws {
    // c1 → c2 → c3 each rewriting f.txt; the staged "z" fixup into c2
    // cannot apply cleanly, so the autosquash rebase stops and leaves
    // `rebase-merge/` live.
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1", files: ["f.txt": "a\n"]),
        .init("c2", files: ["f.txt": "b\n"]),
        .init("c3", files: ["f.txt": "c\n"]),
    ])
    let target = try #require(repo.oids["c2"])
    let before = try repo.revParse("HEAD")

    try resolveByStaging(["f.txt": "z\n"], in: repo)

    let thrown = #expect(throws: FixupError.self) {
        _ = try Fixup.run(target: target, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case .blockedOnConflicts = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    let stopped = try whereAmI(path: repo.url.path)
    #expect(stopped.isMidRebase, "the rebase must be left resumable, not aborted")
    #expect(stopped.hasConflicts)
    #expect(stateFileExists("rebase-merge", in: repo))

    try ConflictHandoff.runAbort(at: repo.url.path)

    let after = try whereAmI(path: repo.url.path)
    #expect(!after.isMidRebase,
            "the undo restores the pre-op state with no rebase layout, so nothing aborts")
    #expect(!after.isMidMerge)
    #expect(!after.isMidCherryPick)
    #expect(!after.isMidRevert)
    #expect(!after.hasConflicts)
    #expect(!stateFileExists("rebase-merge", in: repo))
    #expect(!stateFileExists("rebase-apply", in: repo))
    #expect(try repo.revParse("refs/heads/main") == before, "the tip is restored")
    #expect(try repo.revParse("HEAD") == before)
    #expect(after.branch == "main")
}

@Test func abortClearsConflictedRewriteReplay() throws {
    // c1 → c2 → c3 all rewrite line 3: reordering c3 before c2 makes the
    // replay's FIRST pick (c3 onto c1) conflict, and the replay is a
    // MULTI-commit pick — the todo still holds the second pick, so
    // `.git/sequencer` is live beside `CHERRY_PICK_HEAD`, exactly the
    // Rewrite-family state the undo alone cannot clear.
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nT3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"]),
        .init("c3", files: ["f.txt": "l1\nl2\nZ3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"]),
    ])
    let c2 = try #require(repo.oids["c2"])
    let c3 = try #require(repo.oids["c3"])
    let mainBefore = try repo.revParse("refs/heads/main")

    let thrown = #expect(throws: RewriteError.self) {
        _ = try Rewrite.reorder(
            commit: c3, position: .before, reference: c2,
            at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case .blockedOnConflicts = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    let stopped = try whereAmI(path: repo.url.path)
    #expect(stopped.isMidCherryPick, "the replay's pick is in progress")
    #expect(stopped.hasConflicts)
    #expect(stopped.branch == nil, "HEAD is detached on the replay's base")
    #expect(stateFileExists("CHERRY_PICK_HEAD", in: repo))
    #expect(stateFileExists("sequencer", in: repo),
            "the multi-pick replay leaves .git/sequencer live — the undo cannot clear it")

    try ConflictHandoff.runAbort(at: repo.url.path)

    let after = try whereAmI(path: repo.url.path)
    #expect(!after.isMidCherryPick, "the abort clears the replay's pick state")
    #expect(!after.isMidMerge)
    #expect(!after.isMidRevert)
    #expect(!after.isMidRebase)
    #expect(!after.hasConflicts)
    #expect(!stateFileExists("CHERRY_PICK_HEAD", in: repo))
    #expect(!stateFileExists("sequencer", in: repo),
            "the replay's .git/sequencer is gone — the undo alone never removes it")
    #expect(after.branch == "main", "the branch is attached again")
    #expect(try repo.revParse("refs/heads/main") == mainBefore, "the tip is restored")
    #expect(try repo.revParse("HEAD") == mainBefore)
}

// MARK: - Continue completes the operations git owns

@Test func continueCompletesAConflictedMerge() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nA3\nl4\nl5\n"]),
        .init("f1", parents: ["c1"], files: ["f.txt": "l1\nl2\nB3\nl4\nl5\n"]),
    ])
    try repo.branch("feature", at: "f1")
    try repo.checkout("main")

    let thrown = #expect(throws: MergeError.self) {
        _ = try Merge.run(
            branch: "feature", intent: .noFastForward, at: repo.url.path,
            extraEnvironment: hermetic)
    }
    guard case .blockedOnConflicts = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }

    try resolveByStaging(["f.txt": "l1\nl2\nM3\nl4\nl5\n"], in: repo)

    let head = try ConflictHandoff.runContinue(kind: .merge, at: repo.url.path)

    // The merge completed as the commit git was stopped from making, with
    // git's own MERGE_MSG — the branch moved to it.
    #expect(try repo.revParse("refs/heads/main") == head, "the branch moved to the commit")
    #expect(try repo.revParse("HEAD") == head)
    let parents = try git.run(
        ["rev-list", "--parents", "-n", "1", head],
        workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).lines.first?.split(separator: " ").dropFirst().count ?? 0
    #expect(parents == 2, "a merge commit with two parents actually exists")
    let after = try whereAmI(path: repo.url.path)
    #expect(!after.isMidMerge, "the merge is no longer in progress")
    #expect(!after.hasConflicts)
    #expect(try git.run(
        ["show", "main:f.txt"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).text == "l1\nl2\nM3\nl4\nl5\n", "the human's resolution is what was committed")
}

@Test func continueCompletesAConflictedCherryPickOnTheBranch() throws {
    // The plan's confirmation point: `cherry-pick --continue` rides the
    // same porcelain `revert --continue` was measured on — here with the
    // #0060 explicit flag spelled, `.noSign`.
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nA3\nl4\nl5\n"]),
        .init("side", parents: ["c1"], files: ["f.txt": "l1\nl2\nS3\nl4\nl5\n"]),
    ])
    try repo.branch("main", at: "c2")
    try repo.checkout("main")
    let side = try #require(repo.oids["side"])

    let thrown = #expect(throws: ReplayError.self) {
        _ = try Replay.cherryPick(commit: side, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case .blockedOnConflicts = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }

    try resolveByStaging(["f.txt": "l1\nl2\nS3\nl4\nl5\n"], in: repo)

    let head = try ConflictHandoff.runContinue(
        kind: .cherryPick, signing: .noSign, at: repo.url.path)

    #expect(try repo.revParse("refs/heads/main") == head, "the branch moved to the pick")
    #expect(try repo.revParse("HEAD") == head)
    #expect(try git.run(
        ["log", "--format=%s", "-n", "1"], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).lines.first == "side", "the pick commits with the picked commit's own message")
    let after = try whereAmI(path: repo.url.path)
    #expect(!after.isMidCherryPick)
    #expect(!after.hasConflicts)
    #expect(try git.run(
        ["show", "main:f.txt"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).text == "l1\nl2\nS3\nl4\nl5\n", "the picked change is on the branch")
}

@Test func continueCompletesAConflictedRevert() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nT3\nl4\nl5\n"]),
        .init("c3", files: ["f.txt": "l1\nl2\nZ3\nl4\nl5\n"]),
    ])
    let c2 = try #require(repo.oids["c2"])

    let thrown = #expect(throws: ReplayError.self) {
        _ = try Replay.revert(commit: c2, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case .blockedOnConflicts = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }

    try resolveByStaging(["f.txt": "l1\nl2\nl3\nl4\nl5\n"], in: repo)

    let head = try ConflictHandoff.runContinue(kind: .revert, at: repo.url.path)

    #expect(try repo.revParse("refs/heads/main") == head, "the branch moved to the revert")
    #expect(try repo.revParse("HEAD") == head)
    let after = try whereAmI(path: repo.url.path)
    #expect(!after.isMidRevert)
    #expect(!after.hasConflicts)
    #expect(try git.run(
        ["show", "main:f.txt"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).text == "l1\nl2\nl3\nl4\nl5\n", "the inverse change is on the branch")
}
