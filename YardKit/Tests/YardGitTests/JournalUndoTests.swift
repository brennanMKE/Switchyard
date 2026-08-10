// JournalUndoTests.swift — undo and redo: traversal over the journal chain (#0169)
//
// Deliberately NOT @testable: undo and redo are M3's public-caller surface,
// so a member silently dropping to internal must fail here at compile time
// (the #0116 failure class).

import Foundation
import Testing
import YardGit

struct JournalUndoTests {

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

    /// The chain state this context's worktree sees — the same replay the
    /// engine performs, built from the merged #0166/#0172 primitives.
    private func scopedState(in ctx: WorktreeContext) throws -> JournalChain.State {
        var nodes: [JournalWorktreeScope.Node] = []
        for entry in try JournalAnchor.list(in: ctx) {
            let decoded = try metadata(of: entry, in: ctx)
            nodes.append(.init(node: decoded.chainNode, worktree: decoded.worktree.name))
        }
        return try JournalWorktreeScope.state(of: nodes, in: ctx.worktreeName)
    }

    /// A commit reachable from nothing, with unique content — mirrors
    /// `JournalRestoreTests` (private there, cannot be shared).
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

    // MARK: - The round trip

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func undoRestoresTheCheckpointAndRedoReturnsByteExactly(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let atCheckpoint = try RefSnapshot.capture(in: ctx)
        let c1 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try repo.branch("feature")
        let present = try RefSnapshot.capture(in: ctx)
        try #require(present != atCheckpoint)  // vacuity guard

        // Unforced: from present the chain claims nothing about the live
        // state, so the cross-tool guard has nothing to verify (#0168
        // decision 1) and the undo proceeds without any force path.
        let undone = try JournalUndo.undo(in: ctx)
        #expect(undone.map(\.entry.id) == [c1.id])
        #expect(try RefSnapshot.capture(in: ctx) == atCheckpoint)
        #expect(try ctx.resolveRef("refs/heads/feature", inWorktree: nil) == nil)
        // Honesty rides through each step's report. Since #0171 the index and
        // worktree ARE captured and restored, so only the sequencer is left.
        #expect(undone[0].notRestored.map(\.piece) == [.sequencer])
        #expect(undone[0].restored.contains(.index))
        #expect(undone[0].restored.contains(.worktree))

        let redone = try JournalUndo.redo(in: ctx)
        #expect(redone.count == 1)
        #expect(try RefSnapshot.capture(in: ctx) == present)
        #expect(try ctx.resolveRef("refs/heads/feature", inWorktree: nil) != nil)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func twoUndosThenTwoRedosReplayTheChainAndReturnToTheExactPresent(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let stateAtC1 = try RefSnapshot.capture(in: ctx)
        let c1 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try repo.branch("first")
        let stateAtC2 = try RefSnapshot.capture(in: ctx)
        let c2 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try repo.branch("second")
        let present = try RefSnapshot.capture(in: ctx)

        // Undo walks operations newest-first: c2, then c1.
        #expect(try JournalUndo.undo(in: ctx).map(\.entry.id) == [c2.id])
        #expect(try RefSnapshot.capture(in: ctx) == stateAtC2)
        #expect(try JournalUndo.undo(in: ctx).map(\.entry.id) == [c1.id])
        #expect(try RefSnapshot.capture(in: ctx) == stateAtC1)

        // Two undos then one redo land mid-chain: the cursor stands on c2
        // and the repository matches c2's capture (#0166's semantics).
        #expect(try JournalUndo.redo(in: ctx).map(\.entry.id) == [c2.id])
        #expect(try RefSnapshot.capture(in: ctx) == stateAtC2)
        #expect(try scopedState(in: ctx).cursor == c2.id)

        // The final redo restores the active run's FIRST traversal capture —
        // the present as the first undo left it — byte-exactly. The run's
        // NEWEST traversal entry captured stateAtC1 and would be wrong
        // (#0034 decision 2's honesty line; mutation M1).
        try JournalUndo.redo(in: ctx)
        #expect(try RefSnapshot.capture(in: ctx) == present)
        #expect(try scopedState(in: ctx).cursor == nil)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func stepsTwoEqualsTwoSingleSteps(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let c1 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try repo.branch("first")
        let c2 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try repo.branch("second")

        let batch = try JournalUndo.undo(steps: 2, in: ctx)
        #expect(batch.map(\.entry.id) == [c2.id, c1.id])
        let afterBatch = try RefSnapshot.capture(in: ctx)

        // Walk back to the present, then take the same two steps singly.
        #expect(try JournalUndo.redo(steps: 2, in: ctx).count == 2)
        try JournalUndo.undo(in: ctx)
        try JournalUndo.undo(in: ctx)
        #expect(try RefSnapshot.capture(in: ctx) == afterBatch)
    }

    // MARK: - The boundaries are ordinary

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func undoPastTheOldestEntryRefusesTypedWithNothingWritten(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)

        // An empty journal has nothing to undo.
        let empty = #expect(throws: JournalUndo.Error.self) { try JournalUndo.undo(in: ctx) }
        #expect(try #require(empty) == .nothingToUndo(requested: 1, available: 0))

        // At the oldest entry, one more undo is ordinary refusal, not decay:
        // the successful undo above proves the verb works in this fixture.
        try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try repo.branch("feature")
        try JournalUndo.undo(in: ctx)
        let countBefore = try JournalAnchor.list(in: ctx).count
        let stateBefore = try RefSnapshot.capture(in: ctx)
        let thrown = #expect(throws: JournalUndo.Error.self) { try JournalUndo.undo(in: ctx) }
        #expect(try #require(thrown) == .nothingToUndo(requested: 1, available: 0))
        // Nothing was written: no traversal entry, no ref moved.
        #expect(try JournalAnchor.list(in: ctx).count == countBefore)
        #expect(try RefSnapshot.capture(in: ctx) == stateBefore)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func redoAtThePresentRefusesTypedWithNothingWritten(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try repo.branch("feature")
        let countBefore = try JournalAnchor.list(in: ctx).count
        let stateBefore = try RefSnapshot.capture(in: ctx)

        let thrown = #expect(throws: JournalUndo.Error.self) { try JournalUndo.redo(in: ctx) }
        #expect(try #require(thrown) == .nothingToRedo(requested: 1, available: 0))
        #expect(try JournalAnchor.list(in: ctx).count == countBefore)
        #expect(try RefSnapshot.capture(in: ctx) == stateBefore)

        // The refusal is about position, not a broken verb: one undo later,
        // the same call succeeds (mutation F2's fixture direction).
        try JournalUndo.undo(in: ctx)
        #expect(try JournalUndo.redo(in: ctx).count == 1)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aCheckpointAfterUndoTruncatesTheRedoTailLogically(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try repo.branch("first")
        let preUndo = try RefSnapshot.capture(in: ctx)
        try JournalUndo.undo(in: ctx)
        try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        // Plain redo no longer reaches the tail — the truncation (F1).
        let thrown = #expect(throws: JournalUndo.Error.self) { try JournalUndo.redo(in: ctx) }
        #expect(try #require(thrown) == .nothingToRedo(requested: 1, available: 0))

        // Logical, never physical: the traversal entry stays listed and its
        // snapshot stays restorable by explicit id (#0034 decision 2).
        let entries = try JournalAnchor.list(in: ctx)
        #expect(entries.count == 3)
        let tail = entries[1]
        #expect(try metadata(of: tail, in: ctx).traversal != nil)
        try JournalRestore.restore(tail.id, in: ctx)
        #expect(try RefSnapshot.capture(in: ctx) == preUndo)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func stepsBeyondAvailabilityRefuseWholeBeforeAnyStepApplies(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try repo.branch("first")
        try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try repo.branch("second")
        let countBefore = try JournalAnchor.list(in: ctx).count
        let stateBefore = try RefSnapshot.capture(in: ctx)

        // Two normal entries exist; three steps must refuse whole — never
        // walk two and then throw.
        let thrown = #expect(throws: JournalUndo.Error.self) { try JournalUndo.undo(steps: 3, in: ctx) }
        #expect(try #require(thrown) == .nothingToUndo(requested: 3, available: 2))
        #expect(try JournalAnchor.list(in: ctx).count == countBefore)
        #expect(try RefSnapshot.capture(in: ctx) == stateBefore)
    }

    // MARK: - What a traversal entry records

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func traversalEntriesRecordOperationRestoredAndResultingPosition(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let c1 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try repo.branch("feature")

        let undone = try JournalUndo.undo(
            command: "switchyard undo",
            agent: .init(name: "claude-code", session: "s-1"), in: ctx)
        let undoEntry = undone[0].checkpoint
        let undoMeta = try metadata(of: undoEntry, in: ctx)
        #expect(undoMeta.operation == "undo")
        #expect(undoMeta.command == "switchyard undo")
        #expect(undoMeta.agent == .init(name: "claude-code", session: "s-1"))
        #expect(undoMeta.traversal == .init(restored: c1.id, resultingPosition: c1.id))
        #expect(undoMeta.captured == .refsOnly)

        // The full redo restored the run's first traversal entry — the one
        // undo just wrote — and the cursor returned to present: `restored`
        // names it, `resultingPosition` is absent.
        let redone = try JournalUndo.redo(in: ctx)
        #expect(redone.map(\.entry.id) == [undoEntry.id])
        let redoMeta = try metadata(of: redone[0].checkpoint, in: ctx)
        #expect(redoMeta.operation == "redo")
        #expect(redoMeta.traversal == .init(restored: undoEntry.id, resultingPosition: nil))
    }

    // MARK: - The chain is per-worktree

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func undoWalksOnlyThisWorktreesEntries(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let wtURL = try repo.addWorktree(named: "agent", branch: "agent-branch")
        let mainCtx = try context(of: repo)
        let wtCtx = try WorktreeContext.resolve(path: wtURL.path)
        let atC1 = try RefSnapshot.capture(in: mainCtx)
        let c1 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: mainCtx)
        let w1 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: wtCtx)
        try repo.branch("main-only")

        // The sibling's newer entry is not this worktree's undo target: the
        // walk scopes to entries recorded here (#0044 decision 1).
        let undone = try JournalUndo.undo(in: mainCtx)
        #expect(undone.map(\.entry.id) == [c1.id])
        #expect(try RefSnapshot.capture(in: mainCtx) == atC1)

        // And the sibling's chain is untouched by this traversal: its undo
        // still targets its own entry, and it has nothing to redo.
        let sibling = try scopedState(in: wtCtx)
        #expect(sibling.cursor == nil)
        #expect(sibling.undoTarget == w1.id)
        #expect(sibling.redoTarget == nil)
    }

    // MARK: - A defective or unrestorable target refuses cleanly

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func anUndoTargetWithReclaimedObjectsRefusesCleanly(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let victim = try unreachableCommit(in: repo, marker: "undo \(format.rawValue)")
        try git.run(["tag", "-a", "doomed", "-m", "annotated", victim],
                    workingDirectory: repo.url.path,
                    extraEnvironment: ["GIT_COMMITTER_NAME": "v",
                                       "GIT_COMMITTER_EMAIL": "v@invalid"])
        let tagObject = try #require(try git.run(
            ["rev-parse", "refs/tags/doomed"], workingDirectory: repo.url.path).lines.first)
        try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try git.run(["tag", "-d", "doomed"], workingDirectory: repo.url.path)
        try aggressivelyCollect(repo)
        let countBefore = try JournalAnchor.list(in: ctx).count
        let stateBefore = try RefSnapshot.capture(in: ctx)

        // The target's snapshot names a tag object nothing could keep alive
        // (#0167 decision 4). Restore's pre-check refuses before the
        // traversal entry is written and before any ref moves (#0168
        // step 6) — an undo aimed at it fails cleanly, never half-applies.
        let thrown = #expect(throws: JournalRestore.Error.self) { try JournalUndo.undo(in: ctx) }
        #expect(try #require(thrown) == .unrestorableObjects(missing: [
            .init(ref: "refs/tags/doomed", oid: tagObject),
        ]))
        #expect(try JournalAnchor.list(in: ctx).count == countBefore)
        #expect(try RefSnapshot.capture(in: ctx) == stateBefore)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aJournalEntryWhoseMetadataDoesNotDecodeRefusesTraversalTyped(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let c1 = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try repo.branch("feature")

        // Hand-anchor an entry whose metadata is not this schema — the state
        // #0170's listing shows per-item as a defect. Traversal cannot
        // resolve a chain over an entry of unknown kind (normal or
        // traversal changes the replay), so it refuses typed, before
        // anything mutates — even though the defective entry is not c1.
        let bad = JournalEntryID.generate(after: c1.id)
        try JournalAnchor.write(.init(metadataJSON: Data("not json\n".utf8)), id: bad, in: ctx)
        let stateBefore = try RefSnapshot.capture(in: ctx)

        #expect(throws: JournalEntryMetadata.SerializationError.self) {
            try JournalUndo.undo(in: ctx)
        }
        #expect(try JournalAnchor.list(in: ctx).count == 2)
        #expect(try RefSnapshot.capture(in: ctx) == stateBefore)
    }

    // MARK: - One lock, taken before anything is read

    /// Single format on purpose: the lock is `flock(2)` on a file under the
    /// common dir — filesystem behavior, nothing the ref backend touches.
    ///
    /// The journal is deliberately EMPTY: with the lock held the refusal
    /// must be the lock's, not the chain's — distinguishing
    /// `JournalLockError` from `nothingToUndo` is what proves the whole
    /// walk, including its plan, runs inside the lock (mutations M8/M9).
    @Test func theWholeTraversalContendsForTheJournalLockBeforeReadingAnything() throws {
        let repo = try FixtureRepository.linear(refFormat: .files)
        defer { repo.destroy() }
        let ctx = try context(of: repo)

        // `try #require` cannot nest inside the closure; assert on the
        // captured error after the lock is released.
        var undoThrown: JournalLockError?
        try JournalLock(context: ctx).withLock {
            undoThrown = #expect(throws: JournalLockError.self) {
                try JournalUndo.undo(lockTimeout: .milliseconds(50), in: ctx)
            }
            #expect(throws: JournalLockError.self) {
                try JournalUndo.redo(lockTimeout: .milliseconds(50), in: ctx)
            }
        }
        #expect(try #require(undoThrown) == .timedOut(
            path: JournalLock(context: ctx).lockFilePath,
            timeout: .milliseconds(50)))

        // Released, the same call reaches the chain and answers from it.
        let thrown = #expect(throws: JournalUndo.Error.self) { try JournalUndo.undo(in: ctx) }
        #expect(try #require(thrown) == .nothingToUndo(requested: 1, available: 0))
    }
}
