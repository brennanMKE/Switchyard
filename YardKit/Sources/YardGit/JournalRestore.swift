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
///    sibling silently at exit 0 (#0044 decision 2). A **live** sibling's
///    held branch is left alone rather than refusing the whole restore
///    (guide §11 decision 23): dropped from the snapshot actually applied
///    and named in the `Report`; a **prunable** holder holds nothing, so its
///    branch is written back like any other recorded ref.
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
        /// The branch `HEAD` did **not** adopt, because a live sibling worktree
        /// has it checked out — `HEAD` was detached at that branch's recorded
        /// oid instead (#0211, guide §11 decision 16). Nil when nothing was
        /// given up, which is the ordinary case.
        public let detachedFrom: String?
        /// Branches a live sibling worktree has checked out, which this
        /// restore left at their current values rather than moving (guide
        /// §11 decision 23). Empty in the ordinary case. `HEAD`'s own
        /// equivalent is `detachedFrom`.
        public let leftAlone: [String]

        public init(entry: JournalAnchor.Entry, restored: [Piece],
                    notRestored: [Omission], checkpoint: JournalAnchor.Entry,
                    detachedFrom: String? = nil, leftAlone: [String] = []) {
            self.entry = entry
            self.restored = restored
            self.notRestored = notRestored
            self.checkpoint = checkpoint
            self.detachedFrom = detachedFrom
            self.leftAlone = leftAlone
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
    /// `allowDifferentWorktree` lifts step 2's worktree gate for an entry
    /// recorded in another worktree and, under it, applies a snapshot
    /// constructed for the caller rather than the one recorded verbatim — see
    /// the applied-snapshot construction below (#0175).
    @discardableResult
    public static func restore(
        _ id: JournalEntryID,
        operation: String = "restore",
        command: String? = nil,
        agent: JournalEntryMetadata.Agent? = nil,
        traversal: JournalChain.Traversal? = nil,
        bypassGuard: Bool = false,
        allowDifferentWorktree: Bool = false,
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
                allowDifferentWorktree: allowDifferentWorktree,
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
        allowDifferentWorktree: Bool = false,
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

        // 2. The worktree gate — before everything else (#0044), unless the
        // caller opted into a cross-worktree application (#0175).
        guard metadata.worktree.name == context.worktreeName || allowDifferentWorktree else {
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

        // 3. One capture of the present — refs, index, worktree and
        // sequencer together, so the pre-restore entry written at step 7
        // from these same values can never describe less than what undo,
        // redo and explicit restore are about to overwrite (#0200).
        let current = try RefSnapshot.capture(in: context, git: git)
        let currentIndex = try IndexSnapshot.capture(in: context, git: git)
        let currentWorktree = try WorktreeSnapshot.capture(in: context, git: git)
        let currentSequencer = try SequencerSnapshot.capture(in: context, git: git)

        // Hoisted above `applied`: both the head-detach transformation below
        // and the disturbance check (step 5) need the same worktree listing,
        // and the transformation must run before step 5 sees the snapshot it
        // will actually inspect.
        let worktrees = try worktreeList(path: base, git: git)

        // Under the override the recorded snapshot cannot be applied
        // verbatim: `for-each-ref` lists the CAPTURING worktree's
        // `refs/worktree/*` and `refs/rewritten/*` under plain names, so
        // applying it here would write that worktree's private refs into
        // ours (measured, #0044). Strip them from the recorded refs; our own
        // per-worktree entries need no carry-through to survive, because
        // restore no longer deletes a ref its snapshot did not record (guide
        // §11 decision 20) — a name `candidate.refs` never lists is a name
        // this restore leaves exactly as it stands. (#0252: the carry-
        // through this comment used to describe was dead weight from before
        // decision 20, when restore's own deletion planning would otherwise
        // have removed our refs as "extras"; `theRecordedWorktreesPrivateRefs
        // AreNotWrittenIntoOurs` and `aForeignEntryRestoresUnderTheOverride
        // AndLeavesOurPrivateRefsAlone` cover both halves of this without it.)
        let candidate: RefSnapshot = allowDifferentWorktree && metadata.worktree.name != context.worktreeName
            ? recorded.withoutPerWorktreeRefs
            : recorded

        // Detach HEAD instead of adopting it when its branch is checked out
        // by a live sibling (#0211, guide §11 decision 16). Not keyed on
        // `allowDifferentWorktree`: the collision predates the override and
        // happens same-worktree too — a live sibling can check out the
        // caller's own recorded branch between checkpoint and restore.
        let headDetach = WorktreeDisturbance.detachingHeldHead(
            in: candidate, worktrees: worktrees, callerPath: context.topLevel)
        let applied = headDetach.snapshot

        // 4. The cross-tool guard, against the cursor's snapshot. A
        // cursor naming a pruned entry (possible only once its chain's
        // protection expired, #0044 decision 5) has no snapshot left to
        // verify and degrades to the present case.
        if !bypassGuard,
           let cursor = try JournalWorktreeScope.state(
               of: nodes, in: context.worktreeName).cursor,
           entries.contains(where: { $0.id == cursor }) {
            let believed = try refsSnapshot(of: cursor, at: base, git: git)

            // `applied` -- not just its ref names -- is what makes this
            // safe. A name `applied` never recorded is a name this restore
            // will not write at all (decision 20 leaves it alone), so no
            // live value for it is evidence of anything; a name it DOES
            // record is refused only when the live value matches neither
            // `believed` NOR `applied` -- matching `applied` means the write
            // is already a no-op, matching `believed` means nothing moved
            // since capture, and a THIRD value is the only shape a foreign
            // tool's move can take (#0232). Scoping by name alone is not
            // enough: a name both `believed` and `applied` record, but at
            // different values -- an ordinary ref the traversal is itself
            // carrying across checkpoints -- must still refuse if a foreign
            // tool set it to something neither checkpoint recorded, and a
            // name-only scope has no way to ask that (measured).
            let divergences = CrossToolGuard.diff(
                recorded: believed, applied: applied, current: current)
            guard divergences.isEmpty else {
                throw CrossToolGuard.Error.repositoryChanged(divergences: divergences)
            }
        }

        // 5. The sibling-disturbance check, on the snapshot being applied,
        // regardless of bypassGuard.
        //
        // Computed against `applied` -- the SAME snapshot step 4's guard
        // just diffed. Dropping a disturbed branch BEFORE the guard runs
        // would also drop it from the guard's scope, and a foreign move to
        // a third value on that branch would stop being reported (#0232,
        // #0248's trap) -- so the drop below happens only now, after step 4
        // has already seen every branch `applied` records.
        //
        // A live sibling's held branch is left alone rather than refusing
        // the whole restore (guide §11 decision 23): `leavingLiveDisturbances`
        // drops it from the snapshot about to be applied and returns it for
        // the `Report`. A prunable holder holds nothing -- its branch stays
        // in `toApply` and is written back like any other recorded ref.
        let disturbances = WorktreeDisturbance.disturbances(
            restoring: applied,
            current: current,
            worktrees: worktrees,
            callerPath: context.topLevel)
        let (toApply, leftAlone) = WorktreeDisturbance.leavingLiveDisturbances(
            disturbances, from: applied)

        // 6. Every recorded oid must still exist, or the refusal comes
        // after HEAD has already moved (measured — see the type comment).
        // Checked against `toApply`: an object a left-alone branch recorded
        // is not something this restore is about to write, so it must not
        // be able to refuse one.
        let missing = try missingObjects(in: toApply, at: base, git: git)
        guard missing.isEmpty else {
            throw Error.unrestorableObjects(missing: missing)
        }

        // 7. The pre-restore entry, from the same capture the checks ran
        // against. `writeEntry`, not `checkpoint`: a nested `withLock`
        // self-deadlocks (measured), and a second capture could describe
        // a state the guard never saw.
        let checkpoint = try JournalCheckpoint.writeEntry(
            capturing: current,
            index: currentIndex,
            worktree: currentWorktree,
            sequencer: currentSequencer,
            operation: operation,
            command: command,
            agent: agent,
            traversal: traversal,
            in: context,
            git: git)

        // 8. Apply — refs and HEAD, then the index, then the worktree.
        //
        // **The order between the index and the worktree is NOT load-bearing**,
        // and it is worth saying so rather than implying a constraint that does
        // not exist: `WorktreeSnapshot.restore` aims every index-mutating
        // command at a temporary index via `GIT_INDEX_FILE`, so it cannot
        // clobber the index just restored. Swapping the two changes nothing,
        // and no mutation catches it — measured, not assumed.
        try toApply.restore(in: context, git: git)

        var restored: [Piece] = [.refs, .head]
        let slots = try anchoredSlots(of: entry, at: base, git: git)
        switch metadata.captured.index {
        case .tree:
            if let oid = slots[JournalAnchor.indexTreeEntryName] {
                try IndexSnapshot.tree(oid: oid).restore(in: context, git: git)
                restored.append(.index)
            }
        case .raw:
            if let blob = slots[JournalAnchor.indexBlobTreeEntryName] {
                try IndexSnapshot.raw(blob: blob).restore(in: context, git: git)
                restored.append(.index)
            }
        case .notCaptured:
            break
        }
        if metadata.captured.worktree != .notCaptured,
           let untracked = slots[JournalAnchor.untrackedTreeEntryName],
           let commit = try worktreeCommit(of: entry, at: base, git: git) {
            try WorktreeSnapshot(commit: commit, untrackedTree: untracked)
                .restore(in: context, git: git)
            restored.append(.worktree)
            if metadata.captured.untracked { restored.append(.untracked) }
        }

        // 8b. Restore the sequencer state, if captured. The tree is stored as a
        // single tree object in the anchor; restore materialises it into the
        // sequencer directory byte-for-byte. `autoMerge` is a keep-alive
        // concern at capture time only -- restore never reads it -- so nil here
        // restores identically and adds no crash path.
        if let layout = metadata.captured.sequencer.layout,
           let oid = slots[JournalAnchor.sequencerTreeEntryName] {
            // Clear both layouts first (#0206). `SequencerSnapshot.restore`
            // only removes its own destination -- if the standing sequencer
            // is the OTHER layout (a `rebase-apply` directory while
            // restoring a `rebase-merge` snapshot, or the reverse), that
            // stale directory survives untouched and is exactly the state
            // decision 14 exists to eliminate. Clearing first is safe:
            // `clear` loops `Layout.allCases`, including the target's own,
            // but `restore` below removes+recreates its destination
            // unconditionally (it stages into a sibling directory and moves
            // it into place only after removing whatever is already there),
            // so pre-removing it here changes nothing about that step.
            try SequencerSnapshot.clear(in: context, git: git)
            try SequencerSnapshot(layout: layout, tree: oid, autoMerge: nil)
                .restore(in: context, git: git)
            restored.append(.sequencer)
        } else if metadata.captured.sequencer == .notCaptured,
                  try SequencerSnapshot.clear(in: context, git: git) {
            // 8c. The target never captured a sequencer, but one is
            // standing — left in place it describes an operation the
            // just-restored refs no longer match: `git rebase --continue`
            // fails to lock the ref, and the only clean exit, `--abort`,
            // silently reverts the restore (#0205, measured). Safe to
            // clear because step 7's pre-restore entry, written above,
            // already captured this live sequencer (#0200) — the
            // mid-rebase state stays recoverable by restoring it.
            restored.append(.sequencer)
        }

        // 9. Report honestly — only what was NOT put back, what HEAD gave up
        // rather than adopted, and every branch left alone for a live
        // sibling.
        return Report(
            entry: entry,
            restored: restored,
            notRestored: omissions(of: metadata.captured, restored: restored),
            checkpoint: checkpoint,
            detachedFrom: headDetach.detachedFrom,
            leftAlone: leftAlone)
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
    /// The anchor commit's tree entries, keyed by name. The artifacts ride
    /// in the tree beside `metadata.json`, so reading them back is one
    /// `ls-tree` rather than a second capture.
    static func anchoredSlots(
        of entry: JournalAnchor.Entry, at base: String, git: GitProcess
    ) throws -> [String: String] {
        let listing = try git.run(["ls-tree", entry.commit], workingDirectory: base)
        var slots: [String: String] = [:]
        for line in listing.lines where !line.isEmpty {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let fields = line[..<tab].split(separator: " ")
            guard fields.count >= 3 else { continue }
            slots[String(line[line.index(after: tab)...])] = String(fields[2])
        }
        return slots
    }

    /// The worktree snapshot's commit. It is *also* recorded as a parent of
    /// the anchor so it stays reachable (#0171), but that parent list is not
    /// where this reads from: this reads the commit's own tree entry,
    /// `JournalAnchor.worktreeCommitTreeEntryName` — a gitlink written by
    /// `JournalCheckpoint.writeEntry` alongside the keep-alive append.
    ///
    /// Before #0202 this read `parents.last`, correct only because
    /// `writeEntry` happened to append the worktree commit after every other
    /// keep-alive oid — an ordering nothing enforced and nothing tested.
    /// #0188 came one line from adding a further keep-alive append after it,
    /// which would have made `parents.last` something else entirely, and the
    /// wrong answer would not have thrown: `JournalRestore` would have
    /// applied the wrong commit as a stash, or found nothing, and reported
    /// the worktree restored regardless. Reading a named entry instead of a
    /// list position removes that coupling outright rather than documenting
    /// around it.
    static func worktreeCommit(
        of entry: JournalAnchor.Entry, at base: String, git: GitProcess
    ) throws -> String? {
        try anchoredSlots(of: entry, at: base, git: git)[JournalAnchor.worktreeCommitTreeEntryName]
    }

    /// What the caller did **not** get back, and why. A piece that was
    /// restored is absent from this list entirely — reporting it as an
    /// omission alongside its own restoration is how a report starts lying.
    static func omissions(
        of captured: JournalEntryMetadata.Captured,
        restored: [Piece] = []
    ) -> [Omission] {
        var result: [Omission] = []
        if !restored.contains(.index) {
            result.append(Omission(
                piece: .index,
                reason: captured.index == .notCaptured ? .notCaptured : .restoreUnavailable))
        }
        if !restored.contains(.worktree) {
            result.append(Omission(
                piece: .worktree,
                reason: captured.worktree == .notCaptured ? .notCaptured : .restoreUnavailable))
        }
        if !restored.contains(.untracked) {
            result.append(Omission(
                piece: .untracked,
                reason: captured.untracked ? .restoreUnavailable : .notCaptured))
        }
        if !restored.contains(.sequencer) {
            result.append(Omission(
                piece: .sequencer,
                reason: captured.sequencer == .notCaptured ? .notCaptured : .restoreUnavailable))
        }
        return result
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
