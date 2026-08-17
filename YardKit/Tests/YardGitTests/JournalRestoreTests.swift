// JournalRestoreTests.swift — guarded snapshot application with an honest report (#0168)
//
// Deliberately NOT @testable: restore is called by #0169 and M3's wiring as
// a public caller, so a member silently dropping to internal must fail here
// at compile time (the #0116 failure class).

import Foundation
import Testing
import YardGit

struct JournalRestoreTests {

    private let git = GitProcess()

    private func context(of repo: FixtureRepository) throws -> WorktreeContext {
        try WorktreeContext.resolve(path: repo.url.path)
    }

    /// The entry's decoded metadata, via the same cat-file path #0030 uses.
    private func metadata(
        of entry: JournalAnchor.Entry, in ctx: WorktreeContext
    ) throws -> JournalEntryMetadata {
        try JournalEntryMetadata(
            serialized: JournalAnchor.metadata(for: entry.id, in: ctx))
    }

    /// A commit reachable from nothing, with unique content — mirrors
    /// `JournalCheckpointTests` (private there, cannot be shared).
    private func unreachableCommit(in repo: FixtureRepository, marker: String) throws -> String {
        let blob = try #require(try git.run(
            ["hash-object", "-w", "--stdin"], workingDirectory: repo.url.path,
            standardInput: Data("victim \(marker)\n".utf8)).lines.first)
        let tree = try #require(try git.run(
            ["mktree"], workingDirectory: repo.url.path,
            standardInput: Data("100644 blob \(blob)\tv.txt\n".utf8)).lines.first)
        return try #require(try git.run(
            ["commit-tree", tree, "-m", "victim \(marker)"],
            workingDirectory: repo.url.path,
            extraEnvironment: ["GIT_AUTHOR_NAME": "v", "GIT_AUTHOR_EMAIL": "v@invalid",
                               "GIT_COMMITTER_NAME": "v", "GIT_COMMITTER_EMAIL": "v@invalid"])
            .lines.first)
    }

    /// Expires every reflog and prunes immediately — the most aggressive
    /// reclamation ordinary maintenance can perform. Test-fixture plumbing;
    /// `switchyard` itself never runs `git gc`.
    private func aggressivelyCollect(_ repo: FixtureRepository) throws {
        try git.run(["reflog", "expire", "--expire=now", "--expire-unreachable=now", "--all"],
                    workingDirectory: repo.url.path)
        try git.run(["gc", "--aggressive", "--prune=now", "--quiet"],
                    workingDirectory: repo.url.path)
    }

    /// A repository whose per-worktree chain stands on an entry, with a ref
    /// another tool moved afterwards: c1 captured, `feature` created, c2
    /// captured, an undo-style restore back onto c1, then `refs/heads/rogue`
    /// created behind the journal's back.
    private func standingOnAnEntryWithARogueRef(
        format: FixtureRepository.RefFormat
    ) throws -> (repo: FixtureRepository, ctx: WorktreeContext,
                 redoTarget: JournalAnchor.Entry, redoState: RefSnapshot,
                 rogueOid: String) {
        var repo = try FixtureRepository.linear(refFormat: format)
        let ctx = try context(of: repo)
        let c1 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try repo.branch("feature")
        let redoState = try RefSnapshot.capture(in: ctx)
        let c2 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try JournalRestore.restore(
            c1.id, operation: "undo",
            traversal: .init(restored: c1.id, resultingPosition: c1.id), in: ctx)
        let rogueOid = try #require(repo.oids["a"])
        try git.run(["update-ref", "refs/heads/rogue", rogueOid],
                    workingDirectory: repo.url.path)
        return (repo, ctx, c2, redoState, rogueOid)
    }

    // MARK: - The round trip

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func restoringACheckpointRoundTripsRefsAndHead(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let before = try RefSnapshot.capture(in: ctx)
        try #require(!before.refs.isEmpty)  // vacuity guard
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        // Wreck the state with raw git: a branch created, a branch moved,
        // and HEAD detached — the cross-tool mutations restore must revert.
        try repo.branch("created-after", at: "a")
        try git.run(["update-ref", "refs/heads/main", try #require(repo.oids["a"])],
                    workingDirectory: repo.url.path)
        try repo.checkoutDetached(try #require(repo.oids["b"]))

        // From present the chain claims nothing about the live state, so the
        // guard has nothing to verify and the restore proceeds unforced.
        let report = try JournalRestore.restore(entry.id, in: ctx)

        #expect(try RefSnapshot.capture(in: ctx) == before)
        // The union restore deleted the branch that did not exist at capture.
        #expect(try ctx.resolveRef("refs/heads/created-after", inWorktree: nil) == nil)
        #expect(report.entry == entry)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func restoreItselfIsUndoableThroughItsPreRestoreCheckpoint(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        try repo.branch("later-work")
        let beforeRestore = try RefSnapshot.capture(in: ctx)

        let report = try JournalRestore.restore(entry.id, in: ctx)
        try #require(try RefSnapshot.capture(in: ctx) != beforeRestore)

        // Restoring the pre-restore entry returns exactly the replaced state.
        try JournalRestore.restore(report.checkpoint.id, in: ctx)
        #expect(try RefSnapshot.capture(in: ctx) == beforeRestore)
    }

    // MARK: - The honest report

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func theReportNamesEveryPieceNotRestoredWithItsReason(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        let report = try JournalRestore.restore(entry.id, in: ctx)

        // #0171 flipped these flags: a checkpoint now captures the index and
        // the worktree, so restore puts them back and the report says so. Only
        // the sequencer remains uncaptured — #0174 built the primitive and
        // nothing wires it yet.
        #expect(report.restored == [.refs, .head, .index, .worktree, .untracked])
        #expect(report.notRestored == [
            .init(piece: .sequencer, reason: .notCaptured),
        ])
        // A restored piece must NOT also appear as an omission: a report that
        // claims both is how honesty degrades into noise.
        #expect(Set(report.restored).isDisjoint(with: Set(report.notRestored.map(\.piece))))
        #expect(report.checkpoint.id > entry.id)
        #expect(try JournalAnchor.list(in: ctx).map(\.id) == [entry.id, report.checkpoint.id])
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aFullerEntrysUnappliablePiecesReadRestoreUnavailable(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)

        // An entry as a post-#0171 build would write it: real refs blob,
        // `captured` claiming index, worktree, and untracked. This build
        // must apply the refs and report the rest as restore-unavailable,
        // never as not-captured — the entry has them; the build does not.
        let snapshot = try RefSnapshot.capture(in: ctx)
        let blob = try #require(try git.run(
            ["hash-object", "-w", "--stdin"], workingDirectory: repo.url.path,
            standardInput: snapshot.serialized()).lines.first)
        let id = JournalEntryID.generate()
        let full = JournalEntryMetadata(
            id: id, operation: "checkpoint", timestamp: Date(),
            worktree: .init(name: nil, path: try #require(ctx.topLevel)),
            captured: .init(refs: true, head: true, index: .tree,
                            worktree: .stash, untracked: true))
        try JournalAnchor.write(
            .init(metadataJSON: full.serialized(), refsBlob: blob), id: id, in: ctx)

        let report = try JournalRestore.restore(id, in: ctx)

        #expect(report.restored == [.refs, .head])
        #expect(report.notRestored == [
            .init(piece: .index, reason: .restoreUnavailable),
            .init(piece: .worktree, reason: .restoreUnavailable),
            .init(piece: .untracked, reason: .restoreUnavailable),
            .init(piece: .sequencer, reason: .notCaptured),
        ])
    }

    // MARK: - The pre-restore entry

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func thePreRestoreEntryRecordsItsOperationAndKind(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let c1 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        // A traversal restore, as #0169 calls it.
        let traversal = JournalChain.Traversal(restored: c1.id, resultingPosition: c1.id)
        let undone = try JournalRestore.restore(
            c1.id, operation: "undo", command: "switchyard undo",
            agent: .init(name: "claude-code", session: "s-1"),
            traversal: traversal, in: ctx)
        let undoMeta = try metadata(of: undone.checkpoint, in: ctx)
        #expect(undoMeta.operation == "undo")
        #expect(undoMeta.command == "switchyard undo")
        #expect(undoMeta.agent == .init(name: "claude-code", session: "s-1"))
        #expect(undoMeta.traversal == traversal)
        // #0200: the pre-restore entry now captures index and worktree
        // alongside refs, at the same step-3 moment the restore's own
        // checks run against — no longer refsOnly, since undo/redo/restore
        // are about to overwrite exactly those pieces.
        #expect(undoMeta.captured == JournalEntryMetadata.Captured(
            refs: true, head: true, index: .tree, worktree: .stash,
            untracked: true, sequencer: .notCaptured))

        // An explicit restore writes a NORMAL entry — the truncation that
        // resets this worktree's cursor to present (#0034 decision 2). The
        // cursor stands on c1 here, so this restore also proves the guard
        // ignores the journal's own anchor writes: the traversal entry above
        // added an anchor ref since c1's capture, and no divergence fired.
        let explicit = try JournalRestore.restore(c1.id, in: ctx)
        #expect(try metadata(of: explicit.checkpoint, in: ctx).traversal == nil)
    }

    // MARK: - The cross-tool guard

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func anotherToolsMoveRefusesRestoreWhileTheChainStandsOnAnEntry(format: FixtureRepository.RefFormat) throws {
        let (repo, ctx, redoTarget, _, rogueOid) =
            try standingOnAnEntryWithARogueRef(format: format)
        defer { repo.destroy() }
        let countBefore = try JournalAnchor.list(in: ctx).count
        let stateBefore = try RefSnapshot.capture(in: ctx)

        let thrown = #expect(throws: CrossToolGuard.Error.self) {
            try JournalRestore.restore(redoTarget.id, in: ctx)
        }
        let error = try #require(thrown)
        #expect(error == .repositoryChanged(divergences: [
            .init(ref: "refs/heads/rogue", expected: nil, actual: rogueOid),
        ]))
        // Nothing was written: no entry, no ref moved.
        #expect(try JournalAnchor.list(in: ctx).count == countBefore)
        #expect(try RefSnapshot.capture(in: ctx) == stateBefore)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func bypassGuardSkipsTheGuardAndNothingElse(format: FixtureRepository.RefFormat) throws {
        let (repo, ctx, redoTarget, redoState, _) =
            try standingOnAnEntryWithARogueRef(format: format)
        defer { repo.destroy() }

        try JournalRestore.restore(redoTarget.id, bypassGuard: true, in: ctx)

        // The target snapshot applied whole: feature is back, rogue —
        // created after the target's capture — is deleted by the union
        // restore, exactly what the skipped guard existed to point out.
        #expect(try RefSnapshot.capture(in: ctx) == redoState)
    }

    // MARK: - The worktree gate

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func anotherWorktreesEntryRefusesRestoreNamingBothWorktrees(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let wtURL = try repo.addWorktree(named: "agent", branch: "agent-branch")
        let wtCtx = try WorktreeContext.resolve(path: wtURL.path)
        let name = try #require(wtCtx.worktreeName)
        let path = try #require(wtCtx.topLevel)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: wtCtx)

        let mainCtx = try context(of: repo)
        let stateBefore = try RefSnapshot.capture(in: mainCtx)
        let thrown = #expect(throws: JournalRestore.Error.self) {
            try JournalRestore.restore(entry.id, in: mainCtx)
        }
        let error = try #require(thrown)
        #expect(error == .differentWorktree(
            recordedName: name, recordedPath: path,
            calling: nil, recordedStillExists: true))
        // Nothing was written.
        #expect(try JournalAnchor.list(in: mainCtx) == [entry])
        #expect(try RefSnapshot.capture(in: mainCtx) == stateBefore)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aDeadRecordedWorktreeIsReportedAsGone(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let wtURL = try repo.addWorktree(named: "agent", branch: "agent-branch")
        let wtCtx = try WorktreeContext.resolve(path: wtURL.path)
        let name = try #require(wtCtx.worktreeName)
        let path = try #require(wtCtx.topLevel)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: wtCtx)
        let mainCtx = try context(of: repo)

        // Directory gone, claim surviving: git's porcelain still honors a
        // prunable worktree's claim, and so does the gate.
        try FileManager.default.removeItem(at: wtURL)
        let prunableThrown = #expect(throws: JournalRestore.Error.self) {
            try JournalRestore.restore(entry.id, in: mainCtx)
        }
        #expect(try #require(prunableThrown) == .differentWorktree(
            recordedName: name, recordedPath: path,
            calling: nil, recordedStillExists: true))

        // Pruned: the claim is released and the gate reports the recorded
        // worktree as gone — name and path from the metadata, dereferencing
        // nothing.
        try git.run(["worktree", "prune"], workingDirectory: repo.url.path)
        let goneThrown = #expect(throws: JournalRestore.Error.self) {
            try JournalRestore.restore(entry.id, in: mainCtx)
        }
        let gone = try #require(goneThrown)
        #expect(gone == .differentWorktree(
            recordedName: name, recordedPath: path,
            calling: nil, recordedStillExists: false))
        #expect(String(describing: gone).contains("no longer exists"))
        #expect(String(describing: gone).contains(path))
    }

    // MARK: - The sibling-disturbance check

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func restoreRefusesToDisturbASiblingsCheckout(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let wtURL = try repo.addWorktree(named: "agent", branch: "agent-branch")
        let wtPath = try #require(try WorktreeContext.resolve(path: wtURL.path).topLevel)
        let ctx = try context(of: repo)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        // Move the sibling's branch with plumbing — which git allows
        // silently at exit 0 (#0044). Restore would move it back.
        let moved = try #require(repo.oids["a"])
        let target = try #require(repo.oids["c"])
        try git.run(["update-ref", "refs/heads/agent-branch", moved],
                    workingDirectory: repo.url.path)
        let countBefore = try JournalAnchor.list(in: ctx).count
        let stateBefore = try RefSnapshot.capture(in: ctx)

        let thrown = #expect(throws: WorktreeDisturbance.Error.self) {
            try JournalRestore.restore(entry.id, in: ctx)
        }
        let error = try #require(thrown)
        #expect(error == .wouldDisturb(disturbances: [
            .init(worktreePath: wtPath, branch: "refs/heads/agent-branch",
                  current: moved, target: target, prunable: false),
        ]))
        // Nothing was written.
        #expect(try JournalAnchor.list(in: ctx).count == countBefore)
        #expect(try RefSnapshot.capture(in: ctx) == stateBefore)
    }

    // MARK: - The unrestorable-object surface

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aReclaimedTagObjectRefusesRestoreBeforeAnythingMutates(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let victim = try unreachableCommit(in: repo, marker: "tag \(format.rawValue)")
        try git.run(["tag", "-a", "doomed", "-m", "annotated", victim],
                    workingDirectory: repo.url.path,
                    extraEnvironment: ["GIT_COMMITTER_NAME": "v",
                                       "GIT_COMMITTER_EMAIL": "v@invalid"])
        let tagObject = try #require(try git.run(
            ["rev-parse", "refs/tags/doomed"], workingDirectory: repo.url.path).lines.first)
        try #require(tagObject != victim)  // annotated: the ref holds a tag object

        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try git.run(["tag", "-d", "doomed"], workingDirectory: repo.url.path)
        try aggressivelyCollect(repo)
        let countBefore = try JournalAnchor.list(in: ctx).count
        let stateBefore = try RefSnapshot.capture(in: ctx)

        // The keep-alive parent preserved the peeled commit; nothing can
        // preserve the tag object (#0167 decision 4). The refusal must come
        // before any mutation — found afterwards, the refs transaction is
        // rejected whole at exit 128 with HEAD already applied (measured).
        let thrown = #expect(throws: JournalRestore.Error.self) {
            try JournalRestore.restore(entry.id, in: ctx)
        }
        let error = try #require(thrown)
        #expect(error == .unrestorableObjects(missing: [
            .init(ref: "refs/tags/doomed", oid: tagObject),
        ]))
        // Nothing was written: no entry, no ref moved, HEAD untouched.
        #expect(try JournalAnchor.list(in: ctx).count == countBefore)
        #expect(try RefSnapshot.capture(in: ctx) == stateBefore)
    }

    // MARK: - The pruned-cursor degradation

    /// #0179 — the cursor points at an entry that pruning has since deleted.
    /// With the `entries.contains(where:)` guard, restore should skip the
    /// cross-tool check entirely rather than refuse against an unfetchable
    /// snapshot. No test existed before this issue; mutation row 3 is the kill.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func prunedCursorSkipsTheGuard(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)

        // Two entries in the journal, with an undo on top that drives the
        // cursor to c0 — then c0's anchor is removed from disk so it no
        // longer appears in `JournalAnchor.list`, and a third tool moves
        // refs behind the journal's back. Without the degradation clause,
        // restore would refuse with repositoryChanged against the now-
        // missing snapshot; with it, restore proceeds.
        let c0 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        // Advance the working state so a redo-style undo has something to
        // restore from. Capture present as an explicit undo entry: a
        // traversal whose resultingPosition is c0.id.
        let undone = try JournalRestore.restore(
            c0.id, operation: "undo",
            traversal: .init(restored: c0.id, resultingPosition: c0.id), in: ctx)
        let undoneId = undone.checkpoint.id

        // Stand the cursor on c0's id by driving a traversal that targets it.
        try git.run(["update-ref", "refs/heads/main", try #require(repo.oids["b"])],
                    workingDirectory: repo.url.path)

        // Drop c0's anchor from disk — JournalAnchor.list will no longer
        // return it, but the traversal entry's resultingPosition still
        // names c0.id, driving the cursor to a missing id. The guard then
        // skips instead of fetching a snapshot that does not exist.
        try git.run(["update-ref", "-d", JournalAnchor.refName(for: c0.id)],
                    workingDirectory: repo.url.path)

        let countBefore = try JournalAnchor.list(in: ctx).count
        #expect(try !JournalAnchor.list(in: ctx).map(\.id).contains(c0.id))

        // Restore the traversal entry itself: it names a present anchor and
        // its snapshot is fetchable; only the cross-tool check should
        // degrade. The rogue ref move above would normally be a divergence,
        // but the pruned-cursor path runs no diff at all.
        try JournalRestore.restore(undoneId, in: ctx)

        // The journal was extended (redo saved a new entry on top of this
        // restore), but nothing went to the side: only the expected anchors.
        #expect(try JournalAnchor.list(in: ctx).count > countBefore)
    }

    // MARK: - The lock wraps the whole flow

    /// Single format on purpose: the lock is `flock(2)` on a file under the
    /// common dir — filesystem behavior, nothing the ref backend touches.
    @Test func restoreContendsForTheJournalLockAndFailsTyped() throws {
        let repo = try FixtureRepository.linear(refFormat: .files)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        try JournalLock(context: ctx).withLock {
            #expect(throws: JournalLockError.self) {
                try JournalRestore.restore(
                    entry.id, lockTimeout: .milliseconds(50), in: ctx)
            }
        }
        // Nothing was written while the lock was held, and a released lock
        // lets the same call through.
        #expect(try JournalAnchor.list(in: ctx) == [entry])
        try JournalRestore.restore(entry.id, in: ctx)
        #expect(try JournalAnchor.list(in: ctx).count == 2)
    }
}
