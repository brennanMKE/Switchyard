// JournalRestore.swift — guarded snapshot application with an honest report (#0168)

import Foundation

/// The restore flow: apply a journal entry's snapshot to the repository,
/// guarded, honestly reported — the engine behind `restore <checkpoint>`, and
/// the core undo/redo (#0169) traverse through. The verbs are M3; this is the
/// engine function only.
///
/// **The order, inside one `JournalLock.withLock` (#0032) — nothing mutates
/// before step 7:**
///
/// 1. Resolve the target entry and decode every entry's metadata (#0155) —
///    one pass yields the target, its refs blob (#0165), and the scoped
///    chain nodes the guard needs.
/// 2. **The worktree gate** (#0034 decision 5): the entry's recorded
///    worktree must be the calling context's. It runs before every other
///    check because a `RefSnapshot` capture is a per-worktree artifact —
///    `for-each-ref` lists the capture worktree's `refs/worktree/*` and
///    `refs/rewritten/*` under plain names — so nothing downstream is
///    coherent against another worktree's snapshot (#0044 decision 3).
/// 3. One `RefSnapshot.capture` of the present: the state every following
///    check inspects and the pre-restore entry records. One capture, one
///    truth — the guard, the disturbance check, and the entry can never
///    disagree about what "now" was.
/// 4. **The cross-tool guard** (#0031), unless `bypassGuard`. The reference
///    is the **scoped chain cursor's** snapshot — the entry this worktree's
///    journal says the repository currently matches (#0166, scoped per
///    #0044/#0172) — never the target's: the diff between the target and now
///    is the journal's own recorded history, which restore exists to
///    traverse. At present (cursor nil) the journal claims nothing about the
///    live state and there is no recorded belief to verify, so the guard has
///    nothing to check; the pre-restore entry is what makes that safe.
/// 5. **The sibling-disturbance check** (#0173) on the snapshot being
///    applied, regardless of `bypassGuard` — it answers a question the guard
///    cannot (it names the worktree), and `update-ref` would wreck the
///    sibling silently at exit 0 (#0044 decision 2).
/// 6. **Every oid the snapshot writes must still exist.** A deleted
///    annotated tag's object outlives capture only until maintenance — the
///    keep-alive parent preserves its peeled commit, never the tag object
///    (#0167 decision 4) — and without this check the failure surfaces
///    *after* the `HEAD` transaction: `update-ref --stdin` rejects the refs
///    batch whole at exit 128, no ref moves, but `HEAD` has already been
///    applied (measured). Refusing here keeps "nothing half-applied" true.
/// 7. The pre-restore entry, via `JournalCheckpoint.writeEntry` from step
///    3's capture — restore is itself a mutation, so it is itself undoable.
///    Normal for explicit restore (resetting the caller's cursor to present,
///    #0034 decision 2 truncation); a traversal entry when #0169 passes its
///    record.
/// 8. `RefSnapshot.restore` (#0027): `HEAD` first alone, then every other
///    ref in one atomic transaction.
/// 9. The `Report`: what was restored, what was not and why, and the
///    pre-restore entry.
///
/// **When any step refuses, nothing has been written** — no entry, no ref
/// moved. Every refusal is typed, carries `ExitClass.repositoryError` (6),
/// and names what whoever hit it needs: the divergent refs, the holding
/// worktree, the recorded worktree, or the missing objects.
public enum JournalRestore {

    /// A piece of repository state a journal entry can carry.
    public enum Piece: String, Sendable, Equatable, CaseIterable {
        case refs, head, index, worktree, untracked, sequencer
    }

    /// Why a piece was not restored. The distinction is the honesty contract
    /// (#0034 decision 3): an omission must say whether the *entry* lacked
    /// the piece or *this build* cannot apply it.
    public enum OmissionReason: String, Sendable, Equatable {
        /// The entry never captured the piece — every checkpoint until #0171
        /// wires the index and worktree snapshots in, and every entry until
        /// #0174 captures the rebase sequencer.
        case notCaptured
        /// The entry captured the piece, but this build cannot apply it — an
        /// entry written by a post-#0171 build restored by this one.
        case restoreUnavailable
    }

    /// One piece the restore did not apply, with its reason.
    public struct Omission: Sendable, Equatable {
        public let piece: Piece
        public let reason: OmissionReason

        public init(piece: Piece, reason: OmissionReason) {
            self.piece = piece
            self.reason = reason
        }
    }

    /// What the restore did: the entry applied, the pieces restored, every
    /// piece not restored with its reason, and the pre-restore entry that
    /// makes the restore itself undoable.
    public struct Report: Sendable, Equatable {
        public let entry: JournalAnchor.Entry
        public let restored: [Piece]
        public let notRestored: [Omission]
        /// The entry written immediately before applying the snapshot,
        /// capturing the state the restore replaced.
        public let checkpoint: JournalAnchor.Entry

        public init(entry: JournalAnchor.Entry, restored: [Piece],
                    notRestored: [Omission], checkpoint: JournalAnchor.Entry) {
            self.entry = entry
            self.restored = restored
            self.notRestored = notRestored
            self.checkpoint = checkpoint
        }
    }

    /// One recorded object the repository no longer contains. `ref` is the
    /// full ref name that recorded it, or `HEAD` for a detached head.
    public struct MissingObject: Sendable, Equatable {
        public let ref: String
        public let oid: String

        public init(ref: String, oid: String) {
            self.ref = ref
            self.oid = oid
        }
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible, Sendable {
        /// No journal entry has this id — never listed, or already pruned.
        case entryNotFound(JournalEntryID)
        /// The entry was recorded in another worktree (#0034 decision 5).
        /// `recordedStillExists` is false when the recorded worktree's
        /// administrative entry is gone (`git worktree prune` ran after its
        /// directory vanished); the name and path are the metadata's record
        /// and are never dereferenced (#0044 decision 5).
        case differentWorktree(recordedName: String?, recordedPath: String,
                               calling: String?, recordedStillExists: Bool)
        /// Objects the snapshot would write back no longer exist, so the ref
        /// transaction cannot apply. The one producer git maintenance
        /// creates on its own: an annotated tag deleted after capture — the
        /// journal keeps its peeled commit alive, but nothing can keep a tag
        /// *object* reachable (#0167 decision 4).
        case unrestorableObjects(missing: [MissingObject])

        public var description: String {
            switch self {
            case let .entryNotFound(id):
                return "journal entry not found: \(id)"
            case let .differentWorktree(recordedName, recordedPath, calling, recordedStillExists):
                let recorded = recordedName.map { "worktree '\($0)'" } ?? "the main worktree"
                let caller = calling.map { "worktree '\($0)'" } ?? "the main worktree"
                if recordedStillExists {
                    return "entry was recorded in \(recorded) at \(recordedPath), "
                        + "not in \(caller); a snapshot applies only in the worktree "
                        + "that recorded it"
                }
                return "entry was recorded in \(recorded) at \(recordedPath), "
                    + "which no longer exists"
            case let .unrestorableObjects(missing):
                let details = missing
                    .map { "\($0.ref) → \($0.oid)" }
                    .joined(separator: "; ")
                return "cannot restore: \(missing.count) recorded object(s) no longer "
                    + "exist in the repository (reclaimed by maintenance after their "
                    + "refs were deleted): \(details)"
            }
        }
    }

    // MARK: - The flow

    /// Applies the entry's snapshot, guarded, and reports honestly.
    ///
    /// `operation`, `command`, `agent`, and `traversal` are recorded on the
    /// pre-restore entry. `traversal` is non-nil exactly when undo/redo
    /// (#0169) is restoring — entry kind is decided by its presence, never by
    /// matching `operation` (#0034 decision 7). `bypassGuard` skips step 4
    /// and nothing else; whether and to whom it surfaces (`--force`,
    /// human-only) is M3's decision — the engine only carries the parameter.
    @discardableResult
    public static func restore(
        _ id: JournalEntryID,
        operation: String = "restore",
        command: String? = nil,
        agent: JournalEntryMetadata.Agent? = nil,
        traversal: JournalChain.Traversal? = nil,
        bypassGuard: Bool = false,
        lockTimeout: Duration = .seconds(10),
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> Report {
        try JournalLock(context: context).withLock(timeout: lockTimeout) {
            try restoreAssumingLock(
                id,
                operation: operation,
                command: command,
                agent: agent,
                traversal: traversal,
                bypassGuard: bypassGuard,
                in: context,
                git: git)
        }
    }

    /// The restore flow's steps 1–9, assuming the caller already holds the
    /// journal lock (#0032).
    ///
    /// The seam exists for undo/redo (#0169), which resolve a step's target
    /// from the chain and apply it under one lock acquisition. Traversal
    /// cannot call `restore` for either half of that: a nested `withLock` on
    /// the journal's lock file self-deadlocks until its timeout — `flock(2)`
    /// denies a second exclusive lock through a second descriptor even in
    /// the same process (measured on macOS: `EWOULDBLOCK`, #0168 Given 1) —
    /// and resolving a target outside the lock would let another process
    /// move the chain between the resolution and the restore it was
    /// resolved for.
    static func restoreAssumingLock(
        _ id: JournalEntryID,
        operation: String = "restore",
        command: String? = nil,
        agent: JournalEntryMetadata.Agent? = nil,
        traversal: JournalChain.Traversal? = nil,
        bypassGuard: Bool = false,
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> Report {
        let base = context.topLevel ?? context.gitDir

        // 1. The journal, decoded once: the target, its snapshot, and
        // the scoped chain nodes.
        let entries = try JournalAnchor.list(in: context, git: git)
        guard let entry = entries.first(where: { $0.id == id }) else {
            throw Error.entryNotFound(id)
        }
        var nodes: [JournalWorktreeScope.Node] = []
        var targetMetadata: JournalEntryMetadata?
        for listed in entries {
            let decoded = try JournalEntryMetadata(
                serialized: JournalAnchor.metadata(for: listed.id, in: context, git: git))
            nodes.append(.init(node: decoded.chainNode, worktree: decoded.worktree.name))
            if listed.id == id { targetMetadata = decoded }
        }
        guard let metadata = targetMetadata else {
            throw Error.entryNotFound(id)
        }
        let recorded = try refsSnapshot(of: id, at: base, git: git)

        // 2. The worktree gate — before everything else (#0044).
        guard metadata.worktree.name == context.worktreeName else {
            // `worktrees/<name>/HEAD` resolves while the recorded
            // worktree's administrative entry survives — including
            // prunable, directory-gone worktrees, whose claim git's own
            // porcelain still honors — and stops resolving once
            // `git worktree prune` releases it (measured).
            let recordedStillExists = try context.resolveRef(
                "HEAD", inWorktree: metadata.worktree.name, git: git) != nil
            throw Error.differentWorktree(
                recordedName: metadata.worktree.name,
                recordedPath: metadata.worktree.path,
                calling: context.worktreeName,
                recordedStillExists: recordedStillExists)
        }

        // 3. One capture of the present.
        let current = try RefSnapshot.capture(in: context, git: git)

        // 4. The cross-tool guard, against the cursor's snapshot. A
        // cursor naming a pruned entry (possible only once its chain's
        // protection expired, #0044 decision 5) has no snapshot left to
        // verify and degrades to the present case.
        if !bypassGuard,
           let cursor = try JournalWorktreeScope.state(
               of: nodes, in: context.worktreeName).cursor,
           entries.contains(where: { $0.id == cursor }) {
            let believed = try refsSnapshot(of: cursor, at: base, git: git)
            let divergences = CrossToolGuard.diff(recorded: believed, current: current)
            guard divergences.isEmpty else {
                throw CrossToolGuard.Error.repositoryChanged(divergences: divergences)
            }
        }

        // 5. The sibling-disturbance check, on the snapshot being
        // applied, regardless of bypassGuard.
        let disturbances = WorktreeDisturbance.disturbances(
            restoring: recorded,
            current: current,
            worktrees: try worktreeList(path: base, git: git),
            callerPath: context.topLevel)
        guard disturbances.isEmpty else {
            throw WorktreeDisturbance.Error.wouldDisturb(disturbances: disturbances)
        }

        // 6. Every recorded oid must still exist, or the refusal comes
        // after HEAD has already moved (measured — see the type comment).
        let missing = try missingObjects(in: recorded, at: base, git: git)
        guard missing.isEmpty else {
            throw Error.unrestorableObjects(missing: missing)
        }

        // 7. The pre-restore entry, from the same capture the checks ran
        // against. `writeEntry`, not `checkpoint`: a nested `withLock`
        // self-deadlocks (measured), and a second capture could describe
        // a state the guard never saw.
        let checkpoint = try JournalCheckpoint.writeEntry(
            capturing: current,
            operation: operation,
            command: command,
            agent: agent,
            traversal: traversal,
            in: context,
            git: git)

        // 8. Apply.
        try recorded.restore(in: context, git: git)

        // 9. Report honestly.
        return Report(
            entry: entry,
            restored: [.refs, .head],
            notRestored: omissions(of: metadata.captured),
            checkpoint: checkpoint)
    }

    // MARK: - Pieces

    /// The entry's refs blob, parsed — the snapshot restore writes back.
    static func refsSnapshot(
        of id: JournalEntryID,
        at base: String,
        git: GitProcess
    ) throws -> RefSnapshot {
        try RefSnapshot(serialized: git.run(
            ["cat-file", "blob",
             JournalAnchor.refName(for: id) + ":" + JournalAnchor.refsTreeEntryName],
            workingDirectory: base).standardOutput)
    }

    /// Every oid the snapshot would write that the repository no longer
    /// contains. One `cat-file --batch-check` pass: an existing oid comes
    /// back with its type, a reclaimed one as `<oid> missing` at exit 0
    /// (measured — the same parse #0167's keep-alive peeling uses).
    static func missingObjects(
        in snapshot: RefSnapshot,
        at base: String,
        git: GitProcess
    ) throws -> [MissingObject] {
        var oidsByRef: [(ref: String, oid: String)] = []
        if case let .detached(oid) = snapshot.head {
            oidsByRef.append((ref: "HEAD", oid: oid))
        }
        oidsByRef += snapshot.refs.map { (ref: $0.name, oid: $0.oid) }
        guard !oidsByRef.isEmpty else { return [] }

        var seen: Set<String> = []
        let unique = oidsByRef.map(\.oid).filter { seen.insert($0).inserted }
        let output = try git.run(
            ["cat-file", "--batch-check=%(objectname) %(objecttype)"],
            workingDirectory: base,
            standardInput: Data(unique.map { $0 + "\n" }.joined().utf8))

        var missingOids: Set<String> = []
        for line in output.lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count >= 2 else {
                throw JournalAnchor.Error.malformedPlumbingOutput(
                    command: "cat-file", line: line)
            }
            if fields[1] == "missing" { missingOids.insert(String(fields[0])) }
        }
        return oidsByRef
            .filter { missingOids.contains($0.oid) }
            .map { MissingObject(ref: $0.ref, oid: $0.oid) }
    }

    /// The report's omission list for what the entry's `captured` map says.
    /// This build applies refs and `HEAD` only; a piece the entry carries
    /// beyond that is `.restoreUnavailable`, a piece it never captured is
    /// `.notCaptured`, and the sequencer is `.notCaptured` on every entry
    /// until #0174 exists to capture it.
    static func omissions(of captured: JournalEntryMetadata.Captured) -> [Omission] {
        [
            Omission(piece: .index,
                     reason: captured.index == .notCaptured ? .notCaptured : .restoreUnavailable),
            Omission(piece: .worktree,
                     reason: captured.worktree == .notCaptured ? .notCaptured : .restoreUnavailable),
            Omission(piece: .untracked,
                     reason: captured.untracked ? .restoreUnavailable : .notCaptured),
            Omission(piece: .sequencer, reason: .notCaptured),
        ]
    }
}

// MARK: - §6 exit class (#0141)

/// Every refusal is a repository-state failure — guide §6 code 6, the same
/// class as the guard and disturbance refusals it stands beside.
extension JournalRestore.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}

// MARK: - Wire encoding (#0130)

/// A missing object rides the wire inside the structured error payload the
/// same way a guard divergence does: agents branch on `ref`/`oid`, so the
/// shape is contract, not prose.
extension JournalRestore.MissingObject: Encodable {
    /// Stable wire keys, identical to the member names; no raw values. The
    /// enum is rename-safety; byte pinning lands with the undo envelope (M3).
    private enum CodingKeys: String, CodingKey {
        case ref, oid
    }
}
