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

    /// A repository whose per-worktree chain stands on an entry, with
    /// `refs/heads/sidecar` created and recorded by the redo target's own
    /// snapshot: c1 captured, `feature` and `sidecar` (at "a") created, c2
    /// (`redoState`) captured, an undo-style restore back onto c1. Left at
    /// "a" — deliberately NOT moved here. A caller that wants the guard to
    /// have an opinion about `sidecar` must move it to a third value
    /// *after* whatever snapshot it is comparing against was itself
    /// captured — for `redoTarget` (c2) that means any time after this
    /// helper returns, but for a **foreign** entry captured later in a
    /// linked worktree, moving it here would already be captured by that
    /// entry's own snapshot, leaving nothing for the guard to catch
    /// (#0248: this is exactly how #0230's original order test went dead
    /// under #0232). Callers that also need a ref recorded by *neither*
    /// side (`rogue`, pre-#0248's shape) add it themselves too.
    private func standingOnAnEntryWithARogueRef(
        format: FixtureRepository.RefFormat
    ) throws -> (repo: FixtureRepository, ctx: WorktreeContext,
                 redoTarget: JournalAnchor.Entry, redoState: RefSnapshot,
                 believed: RefSnapshot) {
        var repo = try FixtureRepository.linear(refFormat: format)
        let ctx = try context(of: repo)
        let c1 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        // c1's own recorded state — before `feature`/`sidecar` exist — is
        // exactly what the scoped chain cursor believes once the restore
        // below lands on it. Captured here, not reconstructed later.
        let believed = try RefSnapshot.capture(in: ctx)
        try repo.branch("feature")
        try repo.branch("sidecar", at: "a")
        let redoState = try RefSnapshot.capture(in: ctx)
        let c2 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try JournalRestore.restore(
            c1.id, operation: "undo",
            traversal: .init(restored: c1.id, resultingPosition: c1.id), in: ctx)
        return (repo, ctx, c2, redoState, believed)
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

        let after = try RefSnapshot.capture(in: ctx)
        #expect(after.head == before.head)
        // Every ref the checkpoint recorded round-trips, including `main`,
        // which the wreck moved.
        #expect(before.refs.allSatisfy { want in
            after.refs.contains(where: { $0.name == want.name && $0.oid == want.oid })
        })
        // `created-after` did not exist at capture, so restore under option A
        // (guide §11 decision 20) leaves it alone rather than deleting it as
        // an "extra" ref.
        #expect(try ctx.resolveRef("refs/heads/created-after", inWorktree: nil)
            == repo.oids["a"])
        #expect(report.entry == entry)
        // No sibling in sight -- HEAD adopts, and nothing was given up.
        #expect(report.detachedFrom == nil)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func restoreItselfIsUndoableThroughItsPreRestoreCheckpoint(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        // Move `main` rather than create a new branch: a branch created here
        // would survive the restore below untouched either way (guide §11
        // decision 20), so it would no longer make the vacuity check below
        // true -- moving a recorded ref still does.
        let a = try #require(repo.oids["a"])
        try git.run(["update-ref", "refs/heads/main", a], workingDirectory: repo.url.path)
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
        let (repo, ctx, redoTarget, redoState, _) =
            try standingOnAnEntryWithARogueRef(format: format)
        defer { repo.destroy() }
        // `feature` (created inside the fixture, before its internal
        // undo-style restore back to c1) is NOT a divergence here (#0232):
        // the redo target's own capture (`redoState`, taken when `feature`
        // already existed) recorded it at the same value it still has, so
        // believed (c1, lacking `feature`) and applied (the target,
        // recording it) disagree about this name -- exactly the ordinary
        // history this restore is walking, not foreign interference.
        try #require(redoState.refs.contains { $0.name == "refs/heads/feature" })
        try #require(redoState.refs.contains { $0.name == "refs/heads/sidecar" && $0.oid == repo.oids["a"] })

        // `sidecar` is different: `redoState`/the target recorded it at
        // "a", and it is now moved -- AFTER the target's own capture -- to
        // a THIRD value neither c1's belief (absent) nor the target ever
        // recorded, so the guard still refuses (#0248: a name recorded by
        // *neither* side, like the old `rogue` shape, no longer would).
        let driftedOid = try #require(repo.oids["b"])
        try git.run(["update-ref", "refs/heads/sidecar", driftedOid],
                    workingDirectory: repo.url.path)
        let countBefore = try JournalAnchor.list(in: ctx).count
        let stateBefore = try RefSnapshot.capture(in: ctx)

        let thrown = #expect(throws: CrossToolGuard.Error.self) {
            try JournalRestore.restore(redoTarget.id, in: ctx)
        }
        let error = try #require(thrown)
        #expect(error == .repositoryChanged(divergences: [
            .init(ref: "refs/heads/sidecar", expected: nil, actual: driftedOid),
        ]))
        // Nothing was written: no entry, no ref moved.
        #expect(try JournalAnchor.list(in: ctx).count == countBefore)
        #expect(try RefSnapshot.capture(in: ctx) == stateBefore)
    }

    // Renamed from `bypassGuardSkipsTheGuardAndNothingElse` (#0203): this
    // fixture has no sibling worktree, so it can only pin that bypassGuard
    // skips step 4, the cross-tool guard. It cannot see whether step 5, the
    // sibling-disturbance check, still runs — that half of the "and nothing
    // else" claim is what `restoreRefusesToDisturbASiblingsCheckoutEvenWithBypassGuard`
    // pins below.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func bypassGuardSkipsTheCrossToolGuard(format: FixtureRepository.RefFormat) throws {
        let (repo, ctx, redoTarget, redoState, _) =
            try standingOnAnEntryWithARogueRef(format: format)
        defer { repo.destroy() }

        // `rogue`: created after the target's capture, recorded by neither
        // c1 (believed) nor c2/redoState (the target) -- the shape this
        // test needs to pin decision 20's "leaves alone" behaviour under
        // bypassGuard, independent of the fixture's own `sidecar` case.
        let rogueOid = try #require(repo.oids["a"])
        try git.run(["update-ref", "refs/heads/rogue", rogueOid],
                    workingDirectory: repo.url.path)

        try JournalRestore.restore(redoTarget.id, bypassGuard: true, in: ctx)

        // The target snapshot's own refs round-trip -- feature is back.
        let after = try RefSnapshot.capture(in: ctx)
        #expect(after.head == redoState.head)
        #expect(redoState.refs.allSatisfy { want in
            after.refs.contains(where: { $0.name == want.name && $0.oid == want.oid })
        })
        // `rogue` was created after the target's capture, so it survives:
        // restore under option A (guide §11 decision 20) deletes only refs
        // the snapshot itself recorded -- skipping the cross-tool guard no
        // longer implies deleting refs the guard would have flagged.
        #expect(try ctx.resolveRef("refs/heads/rogue", inWorktree: nil) == rogueOid)
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

    /// Pins #0044 decision 3: the worktree gate (step 2) must run before the
    /// cross-tool guard (step 4). Composes `standingOnAnEntryWithARogueRef`
    /// — the main worktree stands on a non-nil scoped cursor, with
    /// `sidecar` recorded (at "a") by whatever this restore's own target
    /// snapshot will be — with a linked worktree carrying a foreign entry.
    /// `sidecar` is moved to a third value ONLY AFTER the foreign entry's
    /// own checkpoint captures it, so the foreign entry's `applied`
    /// snapshot still says "a" while the repository now says otherwise —
    /// the guard would catch that if it ran (#0248: moving it any earlier
    /// makes the foreign checkpoint's own capture already match, leaving
    /// nothing to catch — exactly how #0230's original version of this
    /// test went dead once #0232 landed). A foreign entry restored without
    /// `allowDifferentWorktree` must report `differentWorktree` even when
    /// the guard's own divergence is present and, under the gate/guard
    /// reorder this issue exists to catch, would otherwise fire first and
    /// report `repositoryChanged` instead — an error the caller cannot act
    /// on, naming neither worktree.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aForeignEntryStillReportsTheWorktreeGateEvenWhenTheGuardWouldFire(
        format: FixtureRepository.RefFormat
    ) throws {
        let (repo, ctx, _, _, believed) = try standingOnAnEntryWithARogueRef(format: format)
        defer { repo.destroy() }

        let wtURL = try repo.addWorktree(named: "agent", branch: "agent-branch")
        let wtCtx = try WorktreeContext.resolve(path: wtURL.path)
        let name = try #require(wtCtx.worktreeName)
        let path = try #require(wtCtx.topLevel)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: wtCtx)
        // The foreign entry's own captured state — what `applied` would be
        // if this restore ever reached step 4.
        let target = try RefSnapshot.capture(in: wtCtx)

        // Move `sidecar` only now, after the foreign entry's own capture:
        // its `applied` snapshot still says "a", the repository now says
        // "b" — a real divergence for the guard to catch if the gate ever
        // ran after it.
        let driftedOid = try #require(repo.oids["b"])
        try git.run(["update-ref", "refs/heads/sidecar", driftedOid],
                    workingDirectory: repo.url.path)
        let now = try RefSnapshot.capture(in: ctx)

        // Vacuity guard (#0257): if the guard would NOT have fired on this
        // fixture, the assertion below that the gate's error comes out
        // instead of the guard's proves nothing. #0230's original version of
        // this test went dead exactly this way — the fixture's own
        // divergence quietly stopped existing while the test kept passing.
        try #require(!CrossToolGuard.diff(recorded: believed, applied: target, current: now).isEmpty)

        let thrown = #expect(throws: JournalRestore.Error.self) {
            try JournalRestore.restore(entry.id, in: ctx)
        }
        let error = try #require(thrown)
        #expect(error == .differentWorktree(
            recordedName: name, recordedPath: path,
            calling: nil, recordedStillExists: true))
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

    // Renamed from `restoreRefusesToDisturbASiblingsCheckout` (#0251, guide
    // §11 decision 23): the refusal it pinned is gone. A live sibling's held
    // branch is left at its current value instead, and the restore succeeds.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func restoreLeavesALiveSiblingsCheckoutAloneAndReportsIt(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let wtURL = try repo.addWorktree(named: "agent", branch: "agent-branch")
        let wtPath = try #require(try WorktreeContext.resolve(path: wtURL.path).topLevel)
        let ctx = try context(of: repo)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        // Move the sibling's branch with plumbing — which git allows
        // silently at exit 0 (#0044). Restoring the checkpoint verbatim
        // would move it back; decision 23 leaves it alone instead.
        let moved = try #require(repo.oids["a"])
        try git.run(["update-ref", "refs/heads/agent-branch", moved],
                    workingDirectory: repo.url.path)

        let report = try JournalRestore.restore(entry.id, in: ctx)

        #expect(report.leftAlone == ["refs/heads/agent-branch"])
        // The branch is exactly where the sibling's own move put it, not
        // the checkpoint's recorded value.
        #expect(try ctx.resolveRef("refs/heads/agent-branch", inWorktree: nil) == moved)
        // The sibling's checkout stays consistent with the branch it holds.
        #expect(try git.run(["rev-parse", "HEAD"], workingDirectory: wtPath).lines.first == moved)
    }

    // Renamed from `restoreRefusesToDisturbASiblingsCheckoutEvenWithBypassGuard`
    // (#0251, guide §11 decision 23): same rename as above, and it still
    // pins that bypassGuard skips only step 4, never step 5 — the
    // disturbance check runs, and leaves the branch alone, either way.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func restoreLeavesALiveSiblingsCheckoutAloneEvenWithBypassGuard(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let wtURL = try repo.addWorktree(named: "agent", branch: "agent-branch")
        let wtPath = try #require(try WorktreeContext.resolve(path: wtURL.path).topLevel)
        let ctx = try context(of: repo)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        // Move the sibling's branch with plumbing — which git allows
        // silently at exit 0 (#0044).
        let moved = try #require(repo.oids["a"])
        try git.run(["update-ref", "refs/heads/agent-branch", moved],
                    workingDirectory: repo.url.path)

        // bypassGuard skips step 4, the cross-tool guard, never step 5, the
        // sibling-disturbance check (#0044 decision 3) — the check still
        // runs, and still leaves the branch alone, with the guard bypassed.
        let report = try JournalRestore.restore(entry.id, bypassGuard: true, in: ctx)

        #expect(report.leftAlone == ["refs/heads/agent-branch"])
        #expect(try ctx.resolveRef("refs/heads/agent-branch", inWorktree: nil) == moved)
        #expect(try git.run(["rev-parse", "HEAD"], workingDirectory: wtPath).lines.first == moved)
    }

    // MARK: - #0251's headline: a sibling's ordinary commit no longer
    // blocks the caller's undo (guide §11 decision 23)

    /// The measured probe from #0251 itself: agent A checkpoints and works;
    /// agent B makes one ordinary commit in its own worktree, on its own
    /// branch. Before decision 23, A's undo refused outright, and because
    /// every checkpoint captures every ref, A's entire history before B's
    /// commit became permanently unreachable. A's undo now succeeds, B's
    /// commit survives at its new value, and the branch is named in the
    /// report rather than silently overwritten or silently refused.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aSiblingsOrdinaryCommitLeavesTheCallersUndoReachable(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let wtURL = try repo.addWorktree(named: "agent-b", branch: "agent-branch")
        let ctx = try context(of: repo)

        // A checkpoints, then does its own work.
        let checkpoint = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        let mainAtCheckpoint = try #require(
            try git.run(["rev-parse", "refs/heads/main"], workingDirectory: repo.url.path).lines.first)
        try "a work\n".write(to: repo.url.appendingPathComponent("a.txt"),
                             atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "a's work"], workingDirectory: repo.url.path)

        // B makes one ordinary commit in its own worktree, on its own
        // branch — no sibling casualty from B's side of it.
        try "b work\n".write(to: wtURL.appendingPathComponent("b.txt"),
                             atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], workingDirectory: wtURL.path)
        try git.run(["commit", "-qm", "b's work"], workingDirectory: wtURL.path)
        let bsCommit = try #require(try git.run(
            ["rev-parse", "refs/heads/agent-branch"], workingDirectory: repo.url.path).lines.first)

        // A's undo succeeds rather than refusing.
        let report = try JournalRestore.restore(
            checkpoint.id, operation: "undo",
            traversal: .init(restored: checkpoint.id, resultingPosition: checkpoint.id), in: ctx)

        #expect(report.leftAlone == ["refs/heads/agent-branch"])
        // A's own branch is genuinely back — the undo happened, not merely
        // "did not throw".
        #expect(try git.run(
            ["rev-parse", "refs/heads/main"], workingDirectory: repo.url.path).lines.first == mainAtCheckpoint)
        // B's commit survives untouched.
        #expect(try git.run(
            ["rev-parse", "refs/heads/agent-branch"], workingDirectory: repo.url.path).lines.first == bsCommit)
    }

    /// A's entire history before B's commit stays reachable, not merely one
    /// step of it — the property #0251 exists for. Before decision 23, a
    /// fresh checkpoint bought exactly one undo step and truncated the redo
    /// tail; the underlying entries recorded before B's commit stayed
    /// permanently unreachable because every one of them carried B's
    /// pre-commit value for `agent-branch`.
    ///
    /// Both restores pass `bypassGuard: true`: the point of this test is
    /// the disturbance check recurring across two traversal steps, not the
    /// cross-tool guard's own chain-cursor bookkeeping, which is exercised
    /// elsewhere.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aSecondUndoPastTheSiblingsCommitAlsoSucceeds(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let wtURL = try repo.addWorktree(named: "agent-b", branch: "agent-branch")
        let ctx = try context(of: repo)

        let c0 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        let mainAtC0 = try #require(
            try git.run(["rev-parse", "refs/heads/main"], workingDirectory: repo.url.path).lines.first)

        try "a1\n".write(to: repo.url.appendingPathComponent("a1.txt"),
                         atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "a work 1"], workingDirectory: repo.url.path)
        let c1 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        let mainAtC1 = try #require(
            try git.run(["rev-parse", "refs/heads/main"], workingDirectory: repo.url.path).lines.first)

        try "a2\n".write(to: repo.url.appendingPathComponent("a2.txt"),
                         atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "a work 2"], workingDirectory: repo.url.path)

        // B commits once, after both of A's checkpoints -- both c0 and c1
        // recorded agent-branch at its pre-commit value. Content deliberately
        // differs from fixture commit "b"'s own "b.txt" ("b\n"), or `git add`
        // stages nothing and the commit below fails with exit 1.
        try "b sibling work\n".write(to: wtURL.appendingPathComponent("b-sibling.txt"),
                                     atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], workingDirectory: wtURL.path)
        try git.run(["commit", "-qm", "b work"], workingDirectory: wtURL.path)
        let bsCommit = try #require(try git.run(
            ["rev-parse", "refs/heads/agent-branch"], workingDirectory: repo.url.path).lines.first)

        // First undo: back to c1.
        let report1 = try JournalRestore.restore(
            c1.id, operation: "undo",
            traversal: .init(restored: c1.id, resultingPosition: c1.id),
            bypassGuard: true, in: ctx)
        #expect(report1.leftAlone == ["refs/heads/agent-branch"])
        #expect(try git.run(
            ["rev-parse", "refs/heads/main"], workingDirectory: repo.url.path).lines.first == mainAtC1)
        #expect(try git.run(
            ["rev-parse", "refs/heads/agent-branch"], workingDirectory: repo.url.path).lines.first == bsCommit)

        // Second undo: back past B's commit, to c0. This is the step that
        // was permanently unreachable before #0251.
        let report2 = try JournalRestore.restore(
            c0.id, operation: "undo",
            traversal: .init(restored: c0.id, resultingPosition: c0.id),
            bypassGuard: true, in: ctx)
        #expect(report2.leftAlone == ["refs/heads/agent-branch"])
        #expect(try git.run(
            ["rev-parse", "refs/heads/main"], workingDirectory: repo.url.path).lines.first == mainAtC0)
        #expect(try git.run(
            ["rev-parse", "refs/heads/agent-branch"], workingDirectory: repo.url.path).lines.first == bsCommit)
    }

    // MARK: - Liveness, not refusal: prunable and the caller's own branch

    /// A prunable holder holds nothing (guide §11 decision 23, same liveness
    /// key #0211's `detachingHeldHead` reads): its branch is written back
    /// like any other recorded ref, not left alone and not refused.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aPrunableHoldersBranchIsStillRestoredNotLeftAlone(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let wtURL = try repo.addWorktree(named: "agent", branch: "agent-branch")
        let ctx = try context(of: repo)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        // Move the branch with plumbing, then the sibling's directory
        // vanishes without `git worktree remove` — its administrative entry
        // survives until `git worktree prune` (#0044 decision 5), but it
        // holds nothing a live agent is standing on.
        let moved = try #require(repo.oids["a"])
        let target = try #require(repo.oids["c"])
        try git.run(["update-ref", "refs/heads/agent-branch", moved],
                    workingDirectory: repo.url.path)
        try FileManager.default.removeItem(at: wtURL)

        let report = try JournalRestore.restore(entry.id, in: ctx)

        #expect(report.leftAlone.isEmpty)
        #expect(try ctx.resolveRef("refs/heads/agent-branch", inWorktree: nil) == target)
    }

    /// The restore end of `theCallersOwnCheckedOutBranchIsNotADisturbance`
    /// (`WorktreeDisturbanceTests.swift`), which covers the detection side
    /// only: the caller's own checked-out branch is genuinely restored to
    /// its recorded value, never left alone — moving it back is what
    /// undoing one's own operation *is*.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func theCallersOwnCheckedOutBranchIsStillRestored(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        let captured = try #require(repo.oids["c"])

        // Move the caller's own branch after the checkpoint.
        let a = try #require(repo.oids["a"])
        try git.run(["update-ref", "refs/heads/main", a], workingDirectory: repo.url.path)

        let report = try JournalRestore.restore(entry.id, in: ctx)

        #expect(report.leftAlone.isEmpty)
        #expect(try ctx.resolveRef("refs/heads/main", inWorktree: nil) == captured)
    }

    // MARK: - The trap: dropping a left-alone branch must not blind the guard

    /// #0251's trap: dropping a disturbed branch from the snapshot BEFORE
    /// step 4's cross-tool guard runs would also drop it from the guard's
    /// scope, hiding a foreign move to a third value. The drop happens only
    /// after step 4 (a comment on `JournalRestore.swift` says why), so a
    /// foreign move on a branch that step 5 will otherwise leave alone is
    /// still refused.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aForeignMoveOnABranchThatWillBeLeftAloneIsStillRefusedByTheGuard(
        format: FixtureRepository.RefFormat
    ) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        try repo.addWorktree(named: "agent", branch: "agent-branch")
        let ctx = try context(of: repo)

        // c1: agent-branch is "c" here (its start point).
        let c1 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        let cOid = try #require(repo.oids["c"])
        // Ordinary history: move agent-branch, then record it at the new
        // value in c2's own capture — the traversal this restore walks.
        let b = try #require(repo.oids["b"])
        try git.run(["update-ref", "refs/heads/agent-branch", b],
                    workingDirectory: repo.url.path)
        let c2 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        // Undo-style restore back to c1, standing the chain's cursor there.
        // agent-branch is a live sibling's branch, so it is left alone —
        // still at "b" afterward, not moved back to "c".
        try JournalRestore.restore(
            c1.id, operation: "undo",
            traversal: .init(restored: c1.id, resultingPosition: c1.id), in: ctx)

        // A foreign move, AFTER c1's restore, to a THIRD value neither c1's
        // belief ("c") nor c2's target ("b") ever recorded.
        let a = try #require(repo.oids["a"])
        try git.run(["update-ref", "refs/heads/agent-branch", a],
                    workingDirectory: repo.url.path)
        let countBefore = try JournalAnchor.list(in: ctx).count
        let stateBefore = try RefSnapshot.capture(in: ctx)

        // Redo to c2: agent-branch is still a live sibling's branch, so
        // step 5 would leave it alone — but step 4's guard runs first,
        // against the undropped snapshot, and still catches the foreign
        // move.
        let thrown = #expect(throws: CrossToolGuard.Error.self) {
            try JournalRestore.restore(c2.id, in: ctx)
        }
        let error = try #require(thrown)
        #expect(error == .repositoryChanged(divergences: [
            .init(ref: "refs/heads/agent-branch", expected: cOid, actual: a),
        ]))
        // Nothing was written: no entry, no ref moved.
        #expect(try JournalAnchor.list(in: ctx).count == countBefore)
        #expect(try RefSnapshot.capture(in: ctx) == stateBefore)
    }

    // MARK: - A sibling's newly created ref survives a restore (#0231)

    /// The issue's own probe, guide §11 decision 20: a linked worktree
    /// creates a branch after the main worktree's checkpoint, while standing
    /// on its own branch -- ordinary plumbing, not a checkout. Main's
    /// restore must leave the branch alone rather than deleting it as an
    /// "extra" ref absent from the snapshot. Measured before the fix:
    /// `exit=128 fatal: Needed a single revision` reading the branch back,
    /// because restore had deleted it.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aSiblingsNewlyCreatedBranchSurvivesARestore(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let wtURL = try repo.addWorktree(named: "agent", branch: "agent-branch")
        let wtCtx = try WorktreeContext.resolve(path: wtURL.path)
        let ctx = try context(of: repo)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        let target = try #require(repo.oids["c"])
        try git.run(["branch", "sibling-wip", target],
                    workingDirectory: wtCtx.topLevel ?? wtCtx.gitDir)

        try JournalRestore.restore(entry.id, in: ctx)

        #expect(try ctx.resolveRef("refs/heads/sibling-wip", inWorktree: nil) == target)
    }

    /// The same probe with a tag -- the issue measured that `git tag
    /// sibling-tag` was deleted identically to the branch case.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aSiblingsNewlyCreatedTagSurvivesARestore(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let wtURL = try repo.addWorktree(named: "agent", branch: "agent-branch")
        let wtCtx = try WorktreeContext.resolve(path: wtURL.path)
        let ctx = try context(of: repo)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        let target = try #require(repo.oids["c"])
        try git.run(["tag", "sibling-tag", target],
                    workingDirectory: wtCtx.topLevel ?? wtCtx.gitDir)

        try JournalRestore.restore(entry.id, in: ctx)

        #expect(try ctx.resolveRef("refs/tags/sibling-tag", inWorktree: nil) == target)
    }

    /// A ref the snapshot DOES carry is still restored to its recorded
    /// value, including one that moved since the capture -- the assertion
    /// that stops the fix from becoming "restore stopped writing refs".
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aRecordedRefIsStillRestoredToItsCaptureEvenAfterItMoved(
        format: FixtureRepository.RefFormat
    ) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        let recordedOid = try #require(repo.oids["c"])

        let movedTo = try #require(repo.oids["a"])
        try git.run(["update-ref", "refs/heads/main", movedTo], workingDirectory: repo.url.path)
        try #require(try ctx.resolveRef("refs/heads/main", inWorktree: nil) == movedTo)

        try JournalRestore.restore(entry.id, in: ctx)

        #expect(try ctx.resolveRef("refs/heads/main", inWorktree: nil) == recordedOid)
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

    // MARK: - Cross-worktree restore (#0175)

    /// A linked worktree with a checkpoint recorded in it and per-worktree
    /// `refs/worktree/probe-*` refs planted on both sides — the fixture the
    /// cross-worktree tests need to prove that the applied snapshot carries
    /// the caller's own per-worktree refs through and drops the recorded
    /// worktree's.
    private func crossWorktreeFixture(
        format: FixtureRepository.RefFormat
    ) throws -> (repo: FixtureRepository, mainCtx: WorktreeContext, wtCtx: WorktreeContext,
                 entry: JournalAnchor.Entry, recorded: RefSnapshot, mainProbe: String) {
        let repo = try FixtureRepository.linear(refFormat: format)
        let wtURL = try repo.addWorktree(named: "agent", branch: "agent-branch")
        let wtCtx = try WorktreeContext.resolve(path: wtURL.path)
        let mainCtx = try context(of: repo)

        let mainProbe = try #require(repo.oids["a"])
        let linkedProbe = try #require(repo.oids["b"])
        try git.run(["update-ref", "refs/worktree/probe-main", mainProbe],
                    workingDirectory: mainCtx.topLevel ?? mainCtx.gitDir)
        try git.run(["update-ref", "refs/worktree/probe-linked", linkedProbe],
                    workingDirectory: wtCtx.topLevel ?? wtCtx.gitDir)

        // Captured immediately before the checkpoint, which itself captures
        // the same present — nothing else touches refs in between, so this
        // is what the entry's own recorded snapshot holds.
        let recorded = try RefSnapshot.capture(in: wtCtx, git: git)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: wtCtx)
        return (repo, mainCtx, wtCtx, entry, recorded, mainProbe)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aForeignEntryRestoresUnderTheOverrideAndLeavesOurPrivateRefsAlone(
        format: FixtureRepository.RefFormat
    ) throws {
        let (repo, mainCtx, _, entry, recorded, mainProbe) = try crossWorktreeFixture(format: format)
        defer { repo.destroy() }

        let report = try JournalRestore.restore(entry.id, allowDifferentWorktree: true, in: mainCtx)
        #expect(report.entry == entry)

        // The shared refs match the recorded snapshot. Before #0211, HEAD
        // applied as recorded -- symbolic to `agent-branch` -- which dual-
        // claimed the branch, because `crossWorktreeFixture`'s "agent"
        // worktree is still live and holds it. Now HEAD detaches at the
        // recorded branch's oid instead of adopting it (#0211, guide §11
        // decision 16): the recorded commit is reached either way, but only
        // one worktree ends up claiming the branch.
        // Compare `.refs` only: `withoutPerWorktreeRefs` carries `head`
        // through unchanged, and head is exactly what this issue changes.
        let after = try RefSnapshot.capture(in: mainCtx)
        #expect(after.withoutPerWorktreeRefs.refs == recorded.withoutPerWorktreeRefs.refs)
        let branchOid = try #require(
            recorded.refs.first(where: { $0.name == "refs/heads/agent-branch" })?.oid)
        #expect(after.head == .detached(oid: branchOid))
        // The report names what was given up, rather than doing it silently.
        #expect(report.detachedFrom == "refs/heads/agent-branch")

        // The caller's own refs/worktree/probe-main still exists with its
        // original oid — untouched by a cross-worktree application.
        let survivor = try git.capture(
            ["rev-parse", "--verify", "--quiet", "refs/worktree/probe-main"],
            workingDirectory: mainCtx.topLevel ?? mainCtx.gitDir)
        #expect(survivor.exitCode == 0)
        #expect(survivor.lines.first == mainProbe)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func theRecordedWorktreesPrivateRefsAreNotWrittenIntoOurs(
        format: FixtureRepository.RefFormat
    ) throws {
        let (repo, mainCtx, _, entry, _, _) = try crossWorktreeFixture(format: format)
        defer { repo.destroy() }

        try JournalRestore.restore(entry.id, allowDifferentWorktree: true, in: mainCtx)

        // The recorded worktree's own refs/worktree/probe-linked must not
        // appear in the caller's namespace.
        let imported = try git.capture(
            ["rev-parse", "--verify", "--quiet", "refs/worktree/probe-linked"],
            workingDirectory: mainCtx.topLevel ?? mainCtx.gitDir)
        #expect(imported.exitCode != 0)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func withoutTheOverrideAForeignEntryStillRefuses(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let wtURL = try repo.addWorktree(named: "agent", branch: "agent-branch")
        let wtCtx = try WorktreeContext.resolve(path: wtURL.path)
        let name = try #require(wtCtx.worktreeName)
        let path = try #require(wtCtx.topLevel)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: wtCtx)

        let mainCtx = try context(of: repo)
        let thrown = #expect(throws: JournalRestore.Error.self) {
            try JournalRestore.restore(entry.id, in: mainCtx)
        }
        let error = try #require(thrown)
        #expect(error == .differentWorktree(
            recordedName: name, recordedPath: path,
            calling: nil, recordedStillExists: true))
    }

    /// Renamed from
    /// `restoreRefusesToDisturbASiblingsCheckoutEvenUnderTheCrossWorktreeOverride`
    /// (#0251, guide §11 decision 23). #0210: the "agent" worktree from
    /// `crossWorktreeFixture` is itself the sibling relative to the caller
    /// (`mainCtx`) here, so moving its checked-out branch after the entry
    /// was recorded — the same `update-ref` plumbing as the bypassGuard
    /// variant above — makes the cross-worktree apply a disturbance. It is
    /// also the entry's own recorded `HEAD` target (`crossWorktreeFixture`
    /// captures inside the "agent" worktree), so `detachedFrom` and
    /// `leftAlone` name the same branch for two different reasons: `HEAD`
    /// gives it up rather than dual-claiming it (#0211), and the ref entry
    /// that would otherwise move it is dropped (#0251).
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func restoreLeavesALiveSiblingsCheckoutAloneEvenUnderTheCrossWorktreeOverride(
        format: FixtureRepository.RefFormat
    ) throws {
        let (repo, mainCtx, wtCtx, entry, _, _) = try crossWorktreeFixture(format: format)
        defer { repo.destroy() }
        let wtPath = try #require(wtCtx.topLevel)

        // Move the sibling's checked-out branch with plumbing after the
        // entry was recorded — which git allows silently at exit 0 (#0044).
        let moved = try #require(repo.oids["a"])
        try git.run(["update-ref", "refs/heads/agent-branch", moved],
                    workingDirectory: repo.url.path)

        let report = try JournalRestore.restore(entry.id, allowDifferentWorktree: true, in: mainCtx)

        #expect(report.leftAlone == ["refs/heads/agent-branch"])
        #expect(report.detachedFrom == "refs/heads/agent-branch")
        // The branch is exactly where the sibling's own move put it, even
        // under the cross-worktree override.
        #expect(try mainCtx.resolveRef("refs/heads/agent-branch", inWorktree: nil) == moved)
        #expect(try git.run(["rev-parse", "HEAD"], workingDirectory: wtPath).lines.first == moved)
    }

    // MARK: - Detach on collision, not only under the override (#0211)

    /// Caller stands on `feature`, checkpoints, moves off; a sibling then
    /// checks out `feature`; the caller restores its own checkpoint. No
    /// `allowDifferentWorktree` override in sight -- this is the collision
    /// #0211 measured same-worktree, and it is the test that proves the fix
    /// keys on a live holder, not on the override.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aLiveSiblingCheckingOutOurOwnRecordedBranchDetachesInsteadOfDualClaiming(
        format: FixtureRepository.RefFormat
    ) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)

        try repo.branch("feature")
        try repo.checkout("feature")
        let featureOid = try #require(
            try git.run(["rev-parse", "feature"], workingDirectory: repo.url.path).lines.first)

        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        // The caller moves off `feature` -- restoring back onto it is what
        // undoing its own operation IS, not a sibling casualty.
        try repo.checkout("main")

        // A sibling checks out the SAME branch the caller's checkpoint
        // recorded -- an existing branch, not `-b`, so no exclusivity
        // conflict at add time.
        let siblingPath = repo.url.deletingLastPathComponent()
            .appendingPathComponent("\(repo.url.lastPathComponent)-wt-sibling")
        try git.run(["worktree", "add", "-q", siblingPath.path, "feature"],
                    workingDirectory: repo.url.path)
        defer { try? FileManager.default.removeItem(at: siblingPath) }

        let report = try JournalRestore.restore(entry.id, in: ctx)
        #expect(report.entry == entry)

        // HEAD comes back at the recorded commit, detached -- not the dual
        // claim git's own porcelain refuses to create.
        let after = try RefSnapshot.capture(in: ctx)
        #expect(after.head == .detached(oid: featureOid))
        // The report names what was given up, rather than doing it silently.
        #expect(report.detachedFrom == "refs/heads/feature")

        // `feature` itself is untouched: the sibling still holds it, alone.
        let branchOid = try #require(
            try git.run(["rev-parse", "refs/heads/feature"],
                        workingDirectory: repo.url.path).lines.first)
        #expect(branchOid == featureOid)
    }

    /// The dead-agent recovery case #0175 exists for, exercised end to end
    /// through `JournalRestore` rather than only through the pure function:
    /// the worktree that recorded the checkpoint has its directory removed
    /// WITHOUT `git worktree remove` or `git worktree prune` -- so porcelain
    /// still lists it, with `prunable`, exactly like
    /// `aDeadRecordedWorktreeIsReportedAsGone`'s first stage. It holds
    /// nothing live, so HEAD adopts `agent-branch` as recorded --
    /// `detachedFrom` stays nil, the ordinary case. (Running `git worktree
    /// prune` first would drop the entry from the listing entirely and let
    /// this pass for the wrong reason -- the mutation below is what proves
    /// the `prunable` guard, not just entry absence, is load-bearing here.)
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aPrunedRecordingWorktreeStillAdoptsItsBranchOnRestore(
        format: FixtureRepository.RefFormat
    ) throws {
        let (repo, mainCtx, wtCtx, entry, recorded, _) = try crossWorktreeFixture(format: format)
        defer { repo.destroy() }
        let wtPath = try #require(wtCtx.topLevel)

        // The agent's directory vanishes without `git worktree remove`. Its
        // administrative entry -- and its claim on `agent-branch` -- survive
        // until `git worktree prune`, so porcelain still lists it as
        // `prunable` rather than dropping it.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: wtPath))

        let report = try JournalRestore.restore(
            entry.id, allowDifferentWorktree: true, in: mainCtx)
        #expect(report.entry == entry)
        #expect(report.detachedFrom == nil)

        // HEAD adopts the recorded branch -- the prunable claim is not a
        // live one.
        let after = try RefSnapshot.capture(in: mainCtx)
        #expect(after.head == recorded.head)
    }

    /// End to end: after such a restore, `git worktree list` shows the
    /// recorded branch claimed exactly once. The wreckage in #0211's
    /// reproduction was visible exactly here -- `git worktree list` showing
    /// BOTH worktrees as `[agent-branch]`.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aRestoredBranchIsClaimedByExactlyOneWorktreeAfterward(
        format: FixtureRepository.RefFormat
    ) throws {
        let (repo, mainCtx, _, entry, _, _) = try crossWorktreeFixture(format: format)
        defer { repo.destroy() }

        try JournalRestore.restore(entry.id, allowDifferentWorktree: true, in: mainCtx)

        let base = try #require(mainCtx.topLevel)
        let listing = try git.run(
            ["worktree", "list", "--porcelain"], workingDirectory: base)
        let claims = listing.lines.filter { $0 == "branch refs/heads/agent-branch" }
        #expect(claims.count == 1)
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
