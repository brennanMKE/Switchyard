// JournalChain.swift — the undo/redo cursor over the journal's entry list (#0166)

import Foundation

/// Where undo and redo stand, derived purely from the ordered journal entry
/// list — no cursor file, no side state, nothing to lose or rebuild. The
/// entries the cursor is derived from live in anchored snapshot commits
/// (#0028), so the chain survives a process exit, a reboot, and a deleted
/// metadata cache exactly as well as the journal itself does.
///
/// The model:
///
/// - Every journal entry snapshots the repository state at its own capture
///   moment. **Normal** entries are checkpoints and the pre-operation
///   captures mutating commands write; **traversal** entries are written by
///   undo and redo, each recording which entry it restored and where the
///   cursor stood afterwards.
/// - The **cursor** names the entry whose snapshot the repository currently
///   matches, or `nil` for *present* — the live state, beyond every entry.
/// - **Undo** moves the cursor to the newest normal entry below it (from
///   present: the newest normal entry), restoring that entry's snapshot.
///   Traversal entries are skipped when walking: undo steps back through
///   *operations*, not through past undos.
/// - **Redo** moves the cursor to the oldest normal entry above it. Above
///   the topmost normal entry, redo restores the snapshot captured by the
///   active run's first traversal entry — the present state as it was when
///   undo first left it.
/// - **A new normal entry resets the cursor to present.** The former redo
///   tail stays in the journal — restorable explicitly, prunable by #0033 —
///   but plain redo no longer reaches it: truncation is logical, never a
///   deletion.
///
/// Targets are computed by *order comparison*, not by adjacency, so a journal
/// with pruned holes still resolves: a cursor naming a pruned id undoes to
/// the newest surviving normal entry below it.
public enum JournalChain {

    /// What an undo or redo entry records about itself, from the entry's
    /// metadata. Explicit rather than derived: `resultingPosition` could be
    /// recomputed from `restored`'s kind, but only while `restored` survives
    /// pruning — the explicit field keeps replay working over holes.
    public struct Traversal: Sendable, Equatable {
        /// The entry whose snapshot the traversal restored.
        public let restored: JournalEntryID
        /// Where the cursor stood after it: a normal entry's id, or nil for
        /// present (the redo that restored the run's opening capture).
        public let resultingPosition: JournalEntryID?

        public init(restored: JournalEntryID, resultingPosition: JournalEntryID?) {
            self.restored = restored
            self.resultingPosition = resultingPosition
        }
    }

    /// One journal entry as the chain sees it: its id, and its traversal
    /// record when the entry was written by undo or redo (nil = normal).
    public struct Node: Sendable, Equatable {
        public let id: JournalEntryID
        public let traversal: Traversal?

        public init(id: JournalEntryID, traversal: Traversal? = nil) {
            self.id = id
            self.traversal = traversal
        }
    }

    /// What redo would restore.
    public enum RedoStep: Sendable, Equatable {
        /// Restore this normal entry's snapshot; the cursor moves onto it.
        case entry(JournalEntryID)
        /// Restore this *traversal* entry's snapshot — the present state it
        /// captured when the active run's first undo ran — and the cursor
        /// returns to present.
        case present(capturedBy: JournalEntryID)
    }

    /// The resolved chain state. `undoTarget`/`redoTarget` nil means the
    /// respective step is unavailable — the flow layer reports that, it is
    /// not an error here.
    public struct State: Sendable, Equatable {
        /// Entry whose snapshot the repository currently matches; nil =
        /// present.
        public let cursor: JournalEntryID?
        /// The normal entry undo would restore next.
        public let undoTarget: JournalEntryID?
        /// What redo would restore next.
        public let redoTarget: RedoStep?
        /// Every entry id at or above the cursor — the live traversal run.
        /// Handed to `JournalPrune.plan(protected:)` (#0033): pruning any of
        /// these would sever the redo path or the cursor itself. Empty at
        /// present, where only #0033's own newest-entry rule applies.
        public let protectedIDs: Set<JournalEntryID>

        public init(
            cursor: JournalEntryID?,
            undoTarget: JournalEntryID?,
            redoTarget: RedoStep?,
            protectedIDs: Set<JournalEntryID>
        ) {
            self.cursor = cursor
            self.undoTarget = undoTarget
            self.redoTarget = redoTarget
            self.protectedIDs = protectedIDs
        }
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible, Sendable {
        /// The node list is not strictly ascending by id. The journal's
        /// listing is (ULIDs sort by creation; `for-each-ref` sorts by
        /// refname), so unordered input means the caller built the list some
        /// other way, and resolving it would answer a different question.
        case unordered(previous: JournalEntryID, next: JournalEntryID)

        public var description: String {
            switch self {
            case let .unordered(previous, next):
                "journal nodes out of order: \(next) after \(previous)"
            }
        }
    }

    /// Resolves the chain state of an entry list, oldest first — the order
    /// `JournalAnchor.list` returns.
    ///
    /// Replay: a normal entry resets the cursor to present; a traversal
    /// entry moves it to its recorded resulting position, and the traversal
    /// that *left* present is remembered as the active run's capture of the
    /// present state — the final redo target.
    public static func state(of nodes: [Node]) throws -> State {
        var cursor: JournalEntryID?
        var presentCapture: JournalEntryID?
        var previous: JournalEntryID?
        for node in nodes {
            if let previous, node.id <= previous {
                throw Error.unordered(previous: previous, next: node.id)
            }
            previous = node.id
            if let traversal = node.traversal {
                if cursor == nil { presentCapture = node.id }
                cursor = traversal.resultingPosition
            } else {
                cursor = nil
            }
        }

        let undoTarget: JournalEntryID?
        let redoTarget: RedoStep?
        if let cursor {
            undoTarget = nodes.last { $0.traversal == nil && $0.id < cursor }?.id
            if let next = nodes.first(where: { $0.traversal == nil && $0.id > cursor }) {
                redoTarget = .entry(next.id)
            } else if let presentCapture {
                redoTarget = .present(capturedBy: presentCapture)
            } else {
                // Unreachable while entries are written by the flows above
                // this layer; representable if pruning ever ate the capture.
                redoTarget = nil
            }
        } else {
            undoTarget = nodes.last { $0.traversal == nil }?.id
            redoTarget = nil
        }

        let protectedIDs: Set<JournalEntryID> = cursor.map { c in
            Set(nodes.lazy.map(\.id).filter { $0 >= c })
        } ?? []

        return State(
            cursor: cursor,
            undoTarget: undoTarget,
            redoTarget: redoTarget,
            protectedIDs: protectedIDs
        )
    }
}

// MARK: - §6 exit class (#0141)

/// A caller-built node list that is not the journal's order is a repository
/// state the engine cannot answer for — guide §6 code 6.
extension JournalChain.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
