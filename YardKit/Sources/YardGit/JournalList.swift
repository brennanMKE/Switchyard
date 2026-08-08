// JournalList.swift — journal listing and the prune composition (#0170)

import Foundation

/// The journal as an agent reads it, and the one place pruning learns which
/// entries are live (#0034 decisions 2 and 6, #0044 decision 5). The engine
/// behind the `journal` and `journal --prune` verbs; the verbs are M3.
///
/// **The listing reads refs, never the cache.** `JournalRebuild.rebuild`
/// (#0030) recovers every entry from the anchor namespace and the object
/// database alone — skip-and-report, never fatal — so the listing is correct
/// on a repository whose `journal.json` was deleted, never written (#0156
/// does not exist yet), or is stale. When the cache lands it may serve reads
/// under #0033's invariant (it may under-report, never over-report); that is
/// an optimization for a later issue, not a correctness input here.
///
/// **Listing takes no lock.** `JournalAnchor.write` creates the anchor ref
/// as its final step, after the metadata blob, tree, and snapshot commit all
/// exist — so any ref `for-each-ref` reports resolves to a complete entry,
/// and a read concurrent with a write sees the journal before or after that
/// entry, never a torn one. `prune` mutates and therefore runs under the
/// repository's journal lock (#0032).
///
/// **The chain state is the calling worktree's** (#0044 decision 1): the
/// journal lists every worktree's entries, but the cursor, targets, and
/// positions are evaluated over the calling worktree's subsequence
/// (`JournalWorktreeScope`, #0172). Pruning is repository-wide, so its
/// protected set is the union over every live worktree — derived here from
/// `worktreeList` minus prunable entries, which is what makes a deleted
/// worktree's chain expire instead of pinning entries forever.
public enum JournalList {

    /// Where one entry stands relative to the calling worktree's cursor.
    public enum ChainPosition: Sendable, Equatable {
        /// The entry the repository currently matches.
        case cursor
        /// Below the cursor: reachable by undo.
        case history
        /// A normal entry above the cursor: reachable by redo.
        case redoTail
        /// An undo/redo entry — restorable explicitly, never walked.
        case traversal
        /// Recorded in a worktree other than the calling one; its position
        /// belongs to that worktree's chain. `metadata.worktree` names it.
        case otherWorktree
    }

    /// One listed entry. `position` is nil exactly when `defect` is non-nil:
    /// a defective entry cannot be placed on any chain, and hiding it would
    /// hide exactly the state an agent needs to see (#0030's contract).
    public struct Item: Sendable, Equatable {
        /// The anchor: entry id and the commit its ref points at.
        public let entry: JournalAnchor.Entry
        /// Decoded metadata, when the entry's `metadata.json` decodes as
        /// #0155's schema and agrees with the anchor. May be present beside
        /// a `defect` (an id mismatch decodes fine and is still defective).
        public let metadata: JournalEntryMetadata?
        /// Why the entry is defective, in #0030's and #0155's vocabulary
        /// (`Defect.description` / `SerializationError.description`), or nil
        /// for a well-formed entry.
        public let defect: String?
        /// The entry's chain position, nil when defective.
        public let position: ChainPosition?

        public init(
            entry: JournalAnchor.Entry,
            metadata: JournalEntryMetadata?,
            defect: String?,
            position: ChainPosition?
        ) {
            self.entry = entry
            self.metadata = metadata
            self.defect = defect
            self.position = position
        }
    }

    /// What `list` returns: every anchored entry oldest-first, the refs
    /// squatting in the journal namespace, and the calling worktree's chain
    /// state.
    public struct Listing: Sendable, Equatable {
        /// Every id-carrying anchor, ascending by id — the journal's order.
        public let items: [Item]
        /// Refs under the journal namespace whose last component is not an
        /// entry id (#0030's `foreignRef` defects). They hold no id, so they
        /// cannot be items; reported so an agent knows the namespace is not
        /// clean.
        public let foreignRefs: [String]
        /// The calling worktree's chain state, over its well-formed entries.
        public let state: JournalChain.State

        public init(items: [Item], foreignRefs: [String], state: JournalChain.State) {
            self.items = items
            self.foreignRefs = foreignRefs
            self.state = state
        }
    }

    // MARK: - Listing

    /// Lists the journal for the calling worktree.
    public static func list(
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> Listing {
        let recovery = try recover(in: context, git: git)
        let state = try JournalWorktreeScope.state(
            of: recovery.scopedNodes, in: context.worktreeName)

        let items = recovery.records.map { record -> Item in
            guard record.defect == nil, let metadata = record.metadata else {
                return Item(entry: record.entry, metadata: record.metadata,
                            defect: record.defect, position: nil)
            }
            let position: ChainPosition
            if metadata.worktree.name != context.worktreeName {
                position = .otherWorktree
            } else if metadata.traversal != nil {
                position = .traversal
            } else if metadata.id == state.cursor {
                position = .cursor
            } else if let cursor = state.cursor, metadata.id > cursor {
                position = .redoTail
            } else {
                // Below the cursor — or, at present (cursor nil), any
                // normal entry: all of them are reachable by undo.
                position = .history
            }
            return Item(entry: record.entry, metadata: metadata,
                        defect: nil, position: position)
        }
        return Listing(items: items, foreignRefs: recovery.foreignRefs, state: state)
    }

    // MARK: - Pruning

    /// Plans and executes a prune with the live chains protected: the
    /// protected set is `JournalWorktreeScope.protectedIDs` unioned over
    /// every live worktree (#0044 decision 5), where live means listed by
    /// `git worktree list` and not prunable. Runs under the journal lock
    /// (#0032); `lockTimeout` bounds the wait for callers with a budget.
    /// Returns what was deleted, oldest first.
    @discardableResult
    public static func prune(
        policy: JournalPrune.Policy,
        now: Date = Date(),
        lockTimeout: Duration = .seconds(10),
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> [JournalAnchor.Entry] {
        try JournalLock(context: context).withLock(timeout: lockTimeout) {
            let recovery = try recover(in: context, git: git)
            let protected = try JournalWorktreeScope.protectedIDs(
                of: recovery.scopedNodes,
                live: try liveWorktreeNames(in: context, git: git))
            let deletions = JournalPrune.plan(
                recovery.records.map(\.entry),
                policy: policy, protected: protected, now: now)
            try JournalPrune.execute(deletions, in: context, git: git)
            return deletions
        }
    }

    // MARK: - The shared read

    /// One anchor as recovered and decoded: always the anchor itself, plus
    /// either decoded metadata or the defect that prevented it.
    private struct Record {
        let entry: JournalAnchor.Entry
        let metadata: JournalEntryMetadata?
        let defect: String?
    }

    private struct Recovery {
        /// Every id-carrying anchor, ascending by id.
        let records: [Record]
        /// Namespace squatters, verbatim from #0030.
        let foreignRefs: [String]
        /// The chain nodes of the well-formed records only — a defective
        /// entry is on nobody's chain and protects nothing.
        var scopedNodes: [JournalWorktreeScope.Node] {
            records.compactMap { record in
                guard record.defect == nil, let metadata = record.metadata else { return nil }
                return JournalWorktreeScope.Node(
                    node: metadata.chainNode, worktree: metadata.worktree.name)
            }
        }
    }

    /// Rebuilds from refs (#0030), decodes each entry's metadata (#0155),
    /// and folds the id-carrying rebuild defects back into id order.
    private static func recover(
        in context: WorktreeContext,
        git: GitProcess
    ) throws -> Recovery {
        let rebuilt = try JournalRebuild.rebuild(in: context, git: git)

        var records: [Record] = []
        for recovered in rebuilt.entries {
            let entry = JournalAnchor.Entry(id: recovered.id, commit: recovered.commit)
            do {
                let metadata = try JournalEntryMetadata(serialized: recovered.metadataJSON)
                if metadata.id == recovered.id {
                    records.append(Record(entry: entry, metadata: metadata, defect: nil))
                } else {
                    // Without this check one doctored blob would sink the
                    // whole listing: `chainNode` carries the metadata's id,
                    // and a duplicate or out-of-place id makes the chain
                    // throw `.unordered` — a fatal error from a single bad
                    // entry, the opposite of skip-and-report.
                    records.append(Record(
                        entry: entry, metadata: metadata,
                        defect: "journal entry \(recovered.id): metadata carries id "
                            + "\(metadata.id), which does not match its anchor"))
                }
            } catch {
                records.append(Record(
                    entry: entry, metadata: nil, defect: String(describing: error)))
            }
        }

        var foreignRefs: [String] = []
        for defect in rebuilt.defects {
            switch defect {
            case let .foreignRef(name):
                foreignRefs.append(name)
            case let .missingSnapshotCommit(id, commit),
                 let .missingMetadata(id, commit):
                records.append(Record(
                    entry: JournalAnchor.Entry(id: id, commit: commit),
                    metadata: nil, defect: defect.description))
            case let .anchorNotACommit(id, oid, _):
                records.append(Record(
                    entry: JournalAnchor.Entry(id: id, commit: oid),
                    metadata: nil, defect: defect.description))
            }
        }
        records.sort { $0.entry.id < $1.entry.id }
        return Recovery(records: records, foreignRefs: foreignRefs)
    }

    /// The worktrees whose chains still protect: every `worktree list`
    /// record that is not prunable — nil for the main worktree, the resolved
    /// `worktreeName` for each surviving linked worktree. A worktree whose
    /// directory is gone is `prunable` in porcelain (measured, #0044
    /// decision 5) and drops out here, which is exactly how a dead agent
    /// checkout stops pinning journal entries. A *locked* worktree is never
    /// prunable, so a locked-but-deleted checkout keeps protecting until it
    /// is unlocked — git's own prune rule, adopted deliberately.
    private static func liveWorktreeNames(
        in context: WorktreeContext,
        git: GitProcess
    ) throws -> Set<String?> {
        let base = context.topLevel ?? context.gitDir
        var names: Set<String?> = []
        for entry in try worktreeList(path: base, git: git) where !entry.prunable {
            if entry.isMainWorktree {
                names.insert(nil)
            } else if let path = entry.path {
                names.insert(try WorktreeContext.resolve(path: path, git: git).worktreeName)
            }
        }
        return names
    }
}
