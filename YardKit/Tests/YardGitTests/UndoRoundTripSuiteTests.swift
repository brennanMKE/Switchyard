// UndoRoundTripSuiteTests.swift — the undo round-trip suite (#0035)
//
// M2's exit criterion: "undo round-trips every mutating command, including
// with an unmerged index." Each case wrecks a distinct kind of state, restores,
// and compares. Every case proves its own wreck took effect first — a
// round-trip test whose wreck was a no-op passes without restoring anything.

import Foundation
import Testing
@testable import YardGit

struct UndoRoundTripSuiteTests {

    private let git = GitProcess()

    /// Everything a round trip must preserve, read back from the repository.
    private struct State: Equatable {
        var refs: RefSnapshot
        var stages: String        // `ls-files -s`: paths, modes, and conflict stages
        var tracked: [String: String]
        var untracked: [String]
    }

    private func read(_ repo: FixtureRepository, _ ctx: WorktreeContext) throws -> State {
        let stages = try git.run(["ls-files", "-s"], workingDirectory: repo.url.path).text
        let names = try git.run(["ls-files"], workingDirectory: repo.url.path).lines
            .filter { !$0.isEmpty }
        var tracked: [String: String] = [:]
        for name in names {
            let url = repo.url.appendingPathComponent(name)
            tracked[name] = (try? String(contentsOf: url, encoding: .utf8)) ?? "<absent>"
        }
        let untracked = try git.run(["ls-files", "--others", "--exclude-standard"],
                                    workingDirectory: repo.url.path).lines
            .filter { !$0.isEmpty }.sorted()
        return State(refs: try RefSnapshot.capture(in: ctx), stages: stages,
                     tracked: tracked, untracked: untracked)
    }

    /// Checkpoint, wreck, restore, compare. `wreck` must actually change
    /// something — asserted, not assumed.
    private func roundTrip(
        _ repo: FixtureRepository,
        wreck: (FixtureRepository, WorktreeContext) throws -> Void
    ) throws {
        let ctx = try WorktreeContext.resolve(path: repo.url.path)
        let before = try read(repo, ctx)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        try wreck(repo, ctx)
        let wrecked = try read(repo, ctx)
        #expect(wrecked != before, "the wreck must change something, or this proves nothing")

        let report = try JournalRestore.restore(entry.id, in: ctx)
        #expect(report.restored.contains(.refs))

        let after = try read(repo, ctx)
        #expect(after.stages == before.stages, "index stages must round-trip")
        #expect(after.tracked == before.tracked, "tracked file contents must round-trip")
        #expect(after.untracked == before.untracked, "untracked files must round-trip")
        #expect(after.refs == before.refs, "refs must round-trip")
    }

    // MARK: - The cases

    /// The case M2's criterion names explicitly, and the one every design
    /// choice underneath was forced by.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func unmergedIndexRoundTrips(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.conflicted(refFormat: format)
        defer { repo.destroy() }
        #expect(!(try git.run(["ls-files", "-u"], workingDirectory: repo.url.path).text.isEmpty),
                "the fixture must be unmerged")
        try roundTrip(repo) { repo, _ in
            try self.git.run(["read-tree", "--empty"], workingDirectory: repo.url.path)
            try repo.writeUntracked(["f.txt": "clobbered\n"])
        }
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func detachedHeadRoundTrips(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        try repo.checkoutDetached(try #require(repo.oids["b"]))
        try roundTrip(repo) { repo, _ in
            try self.git.run(["checkout", "-q", "main"], workingDirectory: repo.url.path)
        }
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func untrackedFilesRoundTrip(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        try repo.writeUntracked(["notes.txt": "keep me\n", "scratch.log": "and me\n"])
        try roundTrip(repo) { repo, _ in
            try FileManager.default.removeItem(
                at: repo.url.appendingPathComponent("notes.txt"))
            try FileManager.default.removeItem(
                at: repo.url.appendingPathComponent("scratch.log"))
        }
    }

    /// Staged and unstaged changes to the same file — the mix that a
    /// tree-only capture silently flattens.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func stagedAndUnstagedMixRoundTrips(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        try repo.writeUntracked(["mix.txt": "staged\n"])
        try git.run(["add", "mix.txt"], workingDirectory: repo.url.path)
        try repo.writeUntracked(["mix.txt": "staged then modified\n"])

        try roundTrip(repo) { repo, _ in
            try self.git.run(["reset", "-q"], workingDirectory: repo.url.path)
            try repo.writeUntracked(["mix.txt": "clobbered\n"])
        }
    }

    /// Drives a real rebase to a conflict stop. Returns the repository with a
    /// rebase genuinely in progress. Copied from #0174's
    /// `SequencerSnapshotTests.swift:13-38`.
    private func repositoryStoppedMidRebase() throws -> FixtureRepository {
        let repo = try FixtureRepository.linear()
        // `linear` builds a, b, c each touching a DIFFERENT file, so a naive
        // fork conflicts with nothing and the rebase completes cleanly. Both
        // sides must edit the same path after the fork point.
        try repo.writeUntracked(["shared.txt": "base\n"])
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-q", "-m", "shared base"],
                    workingDirectory: repo.url.path)
        let fork = try repo.revParse("HEAD")

        try repo.writeUntracked(["shared.txt": "mainline\n"])
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-q", "-m", "mainline change"],
                    workingDirectory: repo.url.path)

        try git.run(["checkout", "-q", "-b", "side", fork],
                    workingDirectory: repo.url.path)
        try repo.writeUntracked(["shared.txt": "sidechange\n"])
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-q", "-m", "side change"],
                    workingDirectory: repo.url.path)

        // Expected to fail with the conflict — that is the point.
        _ = try? git.run(["rebase", "main"], workingDirectory: repo.url.path)
        return repo
    }

    /// The real round trip #0188 wires up: stop mid-rebase, checkpoint, wreck
    /// the sequencer directory, prove the wreck took effect, restore, resolve
    /// the conflict, and assert `git rebase --continue` exits 0.
    @Test func midRebaseSequencerRoundTripsThroughCheckpointAndRestore() throws {
        let repo = try repositoryStoppedMidRebase()
        defer { repo.destroy() }
        let ctx = try WorktreeContext.resolve(path: repo.url.path)

        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        let metadata = try JournalEntryMetadata(
            serialized: JournalAnchor.metadata(for: entry.id, in: ctx))
        #expect(metadata.captured.sequencer == .merge)

        let directory = try ctx.path(for: "rebase-merge")
        try FileManager.default.removeItem(atPath: directory)
        #expect(!FileManager.default.fileExists(atPath: directory),
                "the wreck must take effect")
        let interrupted = try? git.run(["rebase", "--continue"],
                                       workingDirectory: repo.url.path,
                                       extraEnvironment: ["GIT_EDITOR": "true"])
        #expect(interrupted?.exitCode != 0, "a removed sequencer cannot continue")

        _ = try JournalRestore.restore(entry.id, in: ctx)

        try repo.writeUntracked(["shared.txt": "resolved\n"])
        try git.run(["add", "shared.txt"], workingDirectory: repo.url.path)
        let resumed = try git.run(["rebase", "--continue"],
                                  workingDirectory: repo.url.path,
                                  extraEnvironment: ["GIT_EDITOR": "true"])
        #expect(resumed.exitCode == 0)
        #expect(try git.run(["status", "--porcelain=v2", "--branch"],
                            workingDirectory: repo.url.path)
            .text.contains("branch.head side"))
    }

    /// The honesty half: a round trip can pass while the report still lies
    /// about the sequencer being unrestored, so this asserts the report
    /// separately from the round trip itself.
    @Test func midRebaseCheckpointReportsTheSequencerAsRestored() throws {
        let repo = try repositoryStoppedMidRebase()
        defer { repo.destroy() }
        let ctx = try WorktreeContext.resolve(path: repo.url.path)

        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        let directory = try ctx.path(for: "rebase-merge")
        try FileManager.default.removeItem(atPath: directory)

        let report = try JournalRestore.restore(entry.id, in: ctx)
        #expect(!report.notRestored.map(\.piece).contains(.sequencer))
    }

    // MARK: - #0200: the pre-restore entry must capture index and worktree
    // too, not refs alone — every undo, redo and explicit restore writes
    // one, and until it captures everything it overwrites, the work it
    // clobbers has nowhere to come back from.

    /// Dirties both the index (staged) and the worktree (unstaged) on the
    /// same file, undoes back to an earlier checkpoint — which overwrites
    /// that work — then redoes. Redo must restore the dirtied state
    /// byte-exact, which is only possible if undo's own traversal entry
    /// captured the index and worktree it was about to clobber.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func undoThenRedoRoundTripsStagedAndUnstagedIndexAndWorktree(
        format: FixtureRepository.RefFormat
    ) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try WorktreeContext.resolve(path: repo.url.path)

        // The checkpoint undo will step back to.
        _ = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        // Dirty the index and the worktree — staged, then modified again
        // unstaged — plus an untracked file, before undo runs.
        try repo.writeUntracked(["mix.txt": "staged\n", "loose.txt": "unstaged only\n"])
        try git.run(["add", "mix.txt"], workingDirectory: repo.url.path)
        try repo.writeUntracked(["mix.txt": "staged then modified\n"])
        let dirty = try read(repo, ctx)

        let undone = try JournalUndo.undo(in: ctx)
        let afterUndo = try read(repo, ctx)
        #expect(afterUndo != dirty,
                "undo must actually overwrite the staged/unstaged work, or this proves nothing")

        // The traversal entry undo just wrote must hold what it is about to
        // let redo restore — not refs-only.
        let undoCheckpoint = try #require(undone.first).checkpoint
        let undoMeta = try JournalEntryMetadata(
            serialized: JournalAnchor.metadata(for: undoCheckpoint.id, in: ctx))
        #expect(undoMeta.captured.index != .notCaptured)
        #expect(undoMeta.captured.worktree != .notCaptured)

        let redone = try JournalUndo.redo(in: ctx)
        let redoneReport = try #require(redone.first)
        #expect(redoneReport.restored.contains(.index))
        #expect(redoneReport.restored.contains(.worktree))

        let afterRedo = try read(repo, ctx)
        #expect(afterRedo.stages == dirty.stages,
                "staged bytes must round-trip through undo then redo")
        #expect(afterRedo.tracked == dirty.tracked,
                "tracked file contents must round-trip through undo then redo")
        #expect(afterRedo.untracked == dirty.untracked,
                "untracked files must round-trip through undo then redo")
    }

    /// The claim at `JournalRestore.swift:47` — "restore is itself a
    /// mutation, so it is itself undoable" — exercised across index and
    /// worktree, not just refs: an explicit restore clobbers staged and
    /// unstaged work, and restoring its own `report.checkpoint` must bring
    /// that work back byte-exact.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func restoreOfARestoreRoundTripsStagedAndUnstagedIndexAndWorktree(
        format: FixtureRepository.RefFormat
    ) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try WorktreeContext.resolve(path: repo.url.path)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        // Dirty the index and the worktree, plus an untracked file, before
        // the explicit restore runs.
        try repo.writeUntracked(["mix.txt": "staged\n", "loose.txt": "unstaged only\n"])
        try git.run(["add", "mix.txt"], workingDirectory: repo.url.path)
        try repo.writeUntracked(["mix.txt": "staged then modified\n"])
        let dirty = try read(repo, ctx)

        let report = try JournalRestore.restore(entry.id, in: ctx)
        let afterRestore = try read(repo, ctx)
        #expect(afterRestore != dirty,
                "restore must actually overwrite the staged/unstaged work, or this proves nothing")

        let backReport = try JournalRestore.restore(report.checkpoint.id, in: ctx)
        #expect(backReport.restored.contains(.index))
        #expect(backReport.restored.contains(.worktree))

        let restoredBack = try read(repo, ctx)
        #expect(restoredBack.stages == dirty.stages,
                "staged bytes must round-trip through a restore of a restore")
        #expect(restoredBack.tracked == dirty.tracked,
                "tracked file contents must round-trip through a restore of a restore")
        #expect(restoredBack.untracked == dirty.untracked,
                "untracked files must round-trip through a restore of a restore")
    }

    // MARK: - #0204: the traversal entry undo writes must itself capture
    // the sequencer, not just index and worktree — otherwise redo restores
    // refs, index and worktree but the interrupted rebase is gone, with no
    // entry holding it (the same gap #0200 closed, one piece over).

    /// Steps back to before a rebase was attempted — so the traversal entry
    /// undo writes is the only place the interrupted rebase can still come
    /// from — then redoes and proves it the real way: `git rebase
    /// --continue` must still work afterward, the way
    /// `midRebaseSequencerRoundTripsThroughCheckpointAndRestore` proves it
    /// for plain checkpoint/restore.
    @Test func undoThenRedoRoundTripsMidRebaseSequencer() throws {
        let repo = try repositoryStoppedMidRebase()
        defer { repo.destroy() }
        let ctx = try WorktreeContext.resolve(path: repo.url.path)

        // Step back to before the rebase was attempted and checkpoint
        // there — the normal entry undo will target — then recreate the
        // identical conflict, so undo has a mid-rebase state to step away
        // from.
        try git.run(["rebase", "--abort"], workingDirectory: repo.url.path)
        let beforeRebase = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        let beforeMeta = try JournalEntryMetadata(
            serialized: JournalAnchor.metadata(for: beforeRebase.id, in: ctx))
        #expect(beforeMeta.captured.sequencer == .notCaptured,
                "no rebase is active yet, so there is nothing to capture")

        _ = try? git.run(["rebase", "main"], workingDirectory: repo.url.path)
        let sequencerDirectory = try ctx.path(for: "rebase-merge")
        #expect(FileManager.default.fileExists(atPath: sequencerDirectory),
                "the rebase must actually be interrupted again, or this proves nothing")

        // Undo steps back to `beforeRebase`. The traversal entry it writes
        // — from the state undo is about to overwrite — must hold the
        // interrupted rebase, or redo has nothing to hand back.
        let undone = try JournalUndo.undo(in: ctx)
        let undoCheckpoint = try #require(undone.first).checkpoint
        let undoMeta = try JournalEntryMetadata(
            serialized: JournalAnchor.metadata(for: undoCheckpoint.id, in: ctx))
        #expect(undoMeta.captured.sequencer != .notCaptured)

        // Redo restores that traversal entry's snapshot — the interrupted
        // rebase — and it must actually resume.
        let redone = try JournalUndo.redo(in: ctx)
        let redoneReport = try #require(redone.first)
        #expect(redoneReport.restored.contains(.sequencer))

        try repo.writeUntracked(["shared.txt": "resolved\n"])
        try git.run(["add", "shared.txt"], workingDirectory: repo.url.path)
        let resumed = try git.run(["rebase", "--continue"],
                                  workingDirectory: repo.url.path,
                                  extraEnvironment: ["GIT_EDITOR": "true"])
        #expect(resumed.exitCode == 0)
        #expect(try git.run(["status", "--porcelain=v2", "--branch"],
                            workingDirectory: repo.url.path)
            .text.contains("branch.head side"))
    }

    // MARK: - #0205: a restore whose target captured no sequencer must clear
    // a leftover one, not leave it standing describing an operation the
    // just-restored refs no longer match. Measured in the issue: left in
    // place, `git rebase --continue` fails to lock the ref, and the only
    // clean exit, `--abort`, silently reverts the restore.

    /// Checkpoints before a rebase is attempted (capturing no sequencer),
    /// drives the rebase to a real conflict stop, then restores that
    /// pre-rebase checkpoint. The stale `rebase-merge` directory must be
    /// removed and `git status` must no longer report a rebase in progress.
    @Test func restoringPreRebaseCheckpointClearsTheLeftoverSequencer() throws {
        let repo = try repositoryStoppedMidRebase()
        defer { repo.destroy() }
        let ctx = try WorktreeContext.resolve(path: repo.url.path)

        // Abort back to before the rebase and checkpoint there -- no
        // sequencer is active, so nothing is captured -- then recreate the
        // identical conflict so a live sequencer is standing when that
        // checkpoint is restored.
        try git.run(["rebase", "--abort"], workingDirectory: repo.url.path)
        let beforeRebase = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        let beforeMeta = try JournalEntryMetadata(
            serialized: JournalAnchor.metadata(for: beforeRebase.id, in: ctx))
        #expect(beforeMeta.captured.sequencer == .notCaptured,
                "no rebase is active yet, so there is nothing to capture")

        _ = try? git.run(["rebase", "main"], workingDirectory: repo.url.path)
        let sequencerDirectory = try ctx.path(for: "rebase-merge")
        #expect(FileManager.default.fileExists(atPath: sequencerDirectory),
                "the rebase must actually be interrupted again, or this proves nothing")

        let report = try JournalRestore.restore(beforeRebase.id, in: ctx)
        #expect(report.restored.contains(.sequencer),
                "the leftover was brought into line with the snapshot, which is what restored means")
        #expect(!FileManager.default.fileExists(atPath: sequencerDirectory),
                "the stale sequencer directory must be removed")
        let status = try git.run(["status", "--porcelain=v2", "--branch"],
                                 workingDirectory: repo.url.path).text
        #expect(status.contains("branch.head side"),
                "HEAD must be back on the branch, not detached mid-rebase")
    }

    /// The safety half, and the one that proves the deletion above is not a
    /// real loss: the pre-restore entry the clearing restore just wrote
    /// captured the live sequencer (#0200), so restoring *that* entry must
    /// bring the interrupted rebase all the way back -- resumable, not just
    /// present on disk.
    @Test func restoringThePreRestoreEntryBringsTheClearedRebaseBack() throws {
        let repo = try repositoryStoppedMidRebase()
        defer { repo.destroy() }
        let ctx = try WorktreeContext.resolve(path: repo.url.path)

        try git.run(["rebase", "--abort"], workingDirectory: repo.url.path)
        let beforeRebase = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        _ = try? git.run(["rebase", "main"], workingDirectory: repo.url.path)
        let sequencerDirectory = try ctx.path(for: "rebase-merge")
        #expect(FileManager.default.fileExists(atPath: sequencerDirectory),
                "the rebase must actually be interrupted again, or this proves nothing")

        let report = try JournalRestore.restore(beforeRebase.id, in: ctx)
        #expect(!FileManager.default.fileExists(atPath: sequencerDirectory),
                "sanity: the clearing restore must actually have cleared it")

        let restoredBack = try JournalRestore.restore(report.checkpoint.id, in: ctx)
        #expect(restoredBack.restored.contains(.sequencer))
        #expect(FileManager.default.fileExists(atPath: sequencerDirectory),
                "the pre-restore entry must bring the sequencer directory back")

        try repo.writeUntracked(["shared.txt": "resolved\n"])
        try git.run(["add", "shared.txt"], workingDirectory: repo.url.path)
        let resumed = try git.run(["rebase", "--continue"],
                                  workingDirectory: repo.url.path,
                                  extraEnvironment: ["GIT_EDITOR": "true"])
        #expect(resumed.exitCode == 0, "the restored rebase must actually be resumable")
        #expect(try git.run(["status", "--porcelain=v2", "--branch"],
                            workingDirectory: repo.url.path)
            .text.contains("branch.head side"))
    }

    // MARK: - #0206: a layout mismatch escapes both branches that clear a
    // leftover sequencer. `SequencerSnapshot.restore` only removes ITS OWN
    // destination, so restoring a captured `rebase-merge` snapshot while a
    // `rebase-apply` directory stands (or the reverse) left the wrong-layout
    // directory in place -- exactly the stale state decision 14 exists to
    // eliminate. #0205's clearing only ran when nothing was captured at all.
    //
    // A real `rebase-apply` state needs `git rebase --apply` or `git am`;
    // `FixtureRepository` has no helper for either (checked: only
    // `beginInterruptedRebase` exists, and it drives the default merge
    // backend). Verified by hand first, outside this file, that the same
    // divergence `repositoryStoppedMidRebase` builds also conflicts under
    // `git rebase --apply` after `--abort`, leaving a genuine
    // `.git/rebase-apply/` directory -- so this test drives a second, real
    // apply-backend rebase to the conflict rather than constructing the
    // directory by hand.
    @Test func restoringACapturedRebaseMergeClearsAStandingRebaseApply() throws {
        let repo = try repositoryStoppedMidRebase()
        defer { repo.destroy() }
        let ctx = try WorktreeContext.resolve(path: repo.url.path)

        // Capture while the real rebase-MERGE sequencer stands.
        let mergeCheckpoint = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        let mergeMeta = try JournalEntryMetadata(
            serialized: JournalAnchor.metadata(for: mergeCheckpoint.id, in: ctx))
        #expect(mergeMeta.captured.sequencer == .merge,
                "the checkpoint must actually capture the rebase-merge sequencer, or this proves nothing")

        // Clear that real state, then drive a second, real rebase -- this
        // time the apply backend -- on the identical divergence to a
        // genuine conflict stop, leaving a real `rebase-apply` directory
        // standing in place of the one just captured.
        try git.run(["rebase", "--abort"], workingDirectory: repo.url.path)
        _ = try? git.run(["rebase", "--apply", "main"], workingDirectory: repo.url.path)
        let mergeDirectory = try ctx.path(for: "rebase-merge")
        let applyDirectory = try ctx.path(for: "rebase-apply")
        #expect(!FileManager.default.fileExists(atPath: mergeDirectory))
        #expect(FileManager.default.fileExists(atPath: applyDirectory),
                "the apply-backend rebase must actually be interrupted, or this proves nothing")

        // Restore the rebase-MERGE checkpoint while the mismatched
        // rebase-apply directory stands. A captured layout must clear the
        // OTHER standing layout, not just materialise its own.
        let report = try JournalRestore.restore(mergeCheckpoint.id, in: ctx)
        #expect(report.restored.contains(.sequencer))
        #expect(FileManager.default.fileExists(atPath: mergeDirectory),
                "the captured rebase-merge layout must be materialised")
        #expect(!FileManager.default.fileExists(atPath: applyDirectory),
                "the mismatched rebase-apply directory must not survive the restore")
    }
}
