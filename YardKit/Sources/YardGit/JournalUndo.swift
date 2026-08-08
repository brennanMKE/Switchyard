// JournalUndo.swift — undo and redo: traversal over the journal chain (#0169)

import Foundation

/// Undo and redo: move this worktree's cursor along the journal chain
/// (#0166), restoring each step through the restore flow (#0168) and
/// recording each move as a traversal entry — the engine behind
/// `undo [--steps N]` and `redo [--steps N]`. The verbs are M3; this is the
/// engine only.
///
/// **One walk, two directions.** Each step resolves this worktree's chain
/// state — the scoped subsequence of entries recorded here (#0044/#0172) —
/// and traverses:
///
/// - **Undo** restores `undoTarget`, the newest *normal* entry below the
///   cursor (traversal entries are skipped: undo steps back through
///   operations, not through past undos), recording
///   `Traversal(restored: target, resultingPosition: target)` — the cursor
///   now stands on the restored entry.
/// - **Redo** restores `redoTarget`: `.entry(T)` records
///   `Traversal(restored: T, resultingPosition: T)`;
///   `.present(capturedBy: F)` restores the *traversal* entry F — the active
///   run's first, whose snapshot is the present state as undo first left
///   it — recording `Traversal(restored: F, resultingPosition: nil)`: the
///   cursor returns to present. Restoring the run's **first** capture, never
///   its newest, is what makes redo-after-undo byte-exact (#0034
///   decision 2).
///
/// Undo at the oldest entry and redo at the present are ordinary, not
/// exceptional: the chain reports no target, and the walk refuses typed with
/// nothing written — no traversal entry, no ref moved. So does a `steps`
/// count larger than what remains: availability is checked for the whole
/// walk before any step mutates.
///
/// **One lock acquisition for the whole traversal.** Planning and execution
/// run inside a single `JournalLock.withLock` (#0032): resolving a target
/// and restoring it must be atomic — a concurrent writer between the two
/// could move the chain and make the walk restore an entry the chain no
/// longer names — so each step goes through
/// `JournalRestore.restoreAssumingLock`; the public `restore` takes the same
/// lock, and a nested `withLock` self-deadlocks until its timeout (#0168
/// Given 1). A concurrent undo in a sibling worktree blocks until this
/// traversal finishes, or fails typed (`JournalLockError.timedOut`) when its
/// own `lockTimeout` expires first; its chain is unaffected either way,
/// because these traversal entries are recorded in this worktree and scoped
/// out of the sibling's walk.
///
/// **The plan is the same replay the entries will perform.** Availability is
/// simulated with `JournalChain.state(of:)` over the scoped nodes, appending
/// one synthetic traversal node per step — the same function the written
/// entries replay through afterwards, so the plan and the outcome cannot
/// disagree. A mid-walk *refusal* is still possible where planning cannot
/// see it — an unrestorable target (#0168 step 6) or a cross-tool divergence
/// — and then the typed error propagates with the walk stopped coherently:
/// each completed step wrote its traversal entry, so the cursor rests where
/// the walk stopped, and the refused step itself wrote nothing.
public enum JournalUndo {

    public enum Error: Swift.Error, Equatable, CustomStringConvertible, Sendable {
        /// No normal entry lies below the cursor on this worktree's chain —
        /// the journal is empty, never checkpointed in this worktree, or the
        /// cursor already stands on the oldest entry — or `steps` asked for
        /// more than remain.
        case nothingToUndo(requested: Int, available: Int)
        /// The cursor is at present, a new checkpoint truncated the redo
        /// tail (logically: the entries stay listed and restorable by id,
        /// #0034 decision 2), or `steps` asked for more than remain.
        case nothingToRedo(requested: Int, available: Int)

        public var description: String {
            switch self {
            case let .nothingToUndo(requested, available):
                "nothing to undo: \(requested) step(s) requested, \(available) available"
            case let .nothingToRedo(requested, available):
                "nothing to redo: \(requested) step(s) requested, \(available) available"
            }
        }
    }

    /// Undoes `steps` operations on this worktree's chain, returning one
    /// restore report per step, oldest target last. `command` and `agent`
    /// are recorded on each traversal entry — pass-throughs for M3's CLI;
    /// engine callers leave them nil. A non-positive `steps` performs
    /// nothing and returns an empty list.
    @discardableResult
    public static func undo(
        steps: Int = 1,
        command: String? = nil,
        agent: JournalEntryMetadata.Agent? = nil,
        lockTimeout: Duration = .seconds(10),
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> [JournalRestore.Report] {
        try traverse(.undo, steps: steps, command: command, agent: agent,
                     lockTimeout: lockTimeout, in: context, git: git)
    }

    /// Redoes `steps` steps toward the present, returning one restore report
    /// per step. The final step of a full walk restores the active run's
    /// first traversal capture and returns the cursor to present.
    @discardableResult
    public static func redo(
        steps: Int = 1,
        command: String? = nil,
        agent: JournalEntryMetadata.Agent? = nil,
        lockTimeout: Duration = .seconds(10),
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> [JournalRestore.Report] {
        try traverse(.redo, steps: steps, command: command, agent: agent,
                     lockTimeout: lockTimeout, in: context, git: git)
    }

    // MARK: - The walk

    private enum Direction {
        case undo, redo

        /// The `operation` recorded on the traversal entries. Display-only
        /// free text (#0034 decision 7): entry kind is decided by the
        /// `traversal` field's presence, never by matching this string.
        var operation: String {
            switch self {
            case .undo: "undo"
            case .redo: "redo"
            }
        }
    }

    private static func traverse(
        _ direction: Direction,
        steps: Int,
        command: String?,
        agent: JournalEntryMetadata.Agent?,
        lockTimeout: Duration,
        in context: WorktreeContext,
        git: GitProcess
    ) throws -> [JournalRestore.Report] {
        guard steps > 0 else { return [] }
        return try JournalLock(context: context).withLock(timeout: lockTimeout) {
            // This worktree's chain, replayed from the anchored entry list
            // alone — no cursor file (#0166). An entry whose metadata does
            // not decode throws typed here, before anything mutates: the
            // chain cannot be resolved while an entry's kind is unknown.
            // (#0170's read-only listing tolerates such an entry and shows
            // its defect; traversal refuses.)
            var scoped: [JournalChain.Node] = []
            for entry in try JournalAnchor.list(in: context, git: git) {
                let metadata = try JournalEntryMetadata(
                    serialized: JournalAnchor.metadata(for: entry.id, in: context, git: git))
                if metadata.worktree.name == context.worktreeName {
                    scoped.append(metadata.chainNode)
                }
            }

            // Plan the whole walk before mutating anything. The synthetic
            // ids only order the simulation; the real entries mint their own.
            var simulated = scoped
            var planned: [JournalChain.Traversal] = []
            while planned.count < steps {
                let state = try JournalChain.state(of: simulated)
                guard let traversal = nextTraversal(direction, state: state) else { break }
                simulated.append(.init(
                    id: JournalEntryID.generate(after: simulated.last?.id),
                    traversal: traversal))
                planned.append(traversal)
            }
            guard planned.count == steps else {
                switch direction {
                case .undo:
                    throw Error.nothingToUndo(requested: steps, available: planned.count)
                case .redo:
                    throw Error.nothingToRedo(requested: steps, available: planned.count)
                }
            }

            // Execute. Under the held lock the journal cannot move between
            // plan and application, so each step's target is exactly what a
            // fresh resolution would name. The traversal record rides
            // restore's `traversal:` parameter into the pre-restore entry
            // (#0168 step 7, `JournalCheckpoint.writeEntry`); this walk
            // never writes an entry itself.
            return try planned.map { traversal in
                try JournalRestore.restoreAssumingLock(
                    traversal.restored,
                    operation: direction.operation,
                    command: command,
                    agent: agent,
                    traversal: traversal,
                    in: context,
                    git: git)
            }
        }
    }

    /// The next step's traversal record, or nil when the chain reports no
    /// target in that direction.
    private static func nextTraversal(
        _ direction: Direction,
        state: JournalChain.State
    ) -> JournalChain.Traversal? {
        switch direction {
        case .undo:
            state.undoTarget.map { .init(restored: $0, resultingPosition: $0) }
        case .redo:
            switch state.redoTarget {
            case let .entry(id):
                .init(restored: id, resultingPosition: id)
            case let .present(capturedBy: id):
                .init(restored: id, resultingPosition: nil)
            case nil:
                nil
            }
        }
    }
}

// MARK: - §6 exit class (#0141)

/// Nothing to traverse is a repository-state answer — this repository's
/// journal has no entry in that direction — guide §6 code 6, the class every
/// other journal refusal carries.
extension JournalUndo.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
