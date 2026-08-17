// JournalCheckpoint.swift — capture current state and write one journal entry (#0167)

import Foundation

/// The checkpoint flow: capture the repository's current state and write it
/// as one anchored journal entry (#0028) — the engine behind
/// `checkpoint [label]`, and the primitive every restore-class flow (#0168,
/// #0169) calls to write its own pre-mutation entry.
///
/// **What a checkpoint captures today: refs and `HEAD`, nothing else.** The
/// index and worktree snapshot primitives (#0151, #0152) do not exist yet, so
/// the entry's `captured` map is `JournalEntryMetadata.Captured.refsOnly` —
/// honest by construction until #0171 wires the other pieces in and flips the
/// flags (#0034 decision 3).
///
/// **The whole flow runs inside `JournalLock.withLock` (#0032)** — capture,
/// blob write, id generation, anchor write — so the newest-id read that
/// `JournalEntryID.generate(after:)` depends on cannot race another
/// switchyard process's write. `withLock` is synchronous and polls with
/// `usleep`, so `checkpoint` blocks its calling thread for up to
/// `lockTimeout`; nothing here may run on the main actor.
///
/// **A crash cannot leave a half-entry.** The anchor ref create is the single
/// commit point: every object written before it — refs blob, metadata blob,
/// tree, snapshot commit — is unreferenced until the ref exists, so a failure
/// at any earlier step leaves only unreachable objects that ordinary
/// maintenance reclaims (`switchyard` itself never runs `git gc`), and an
/// anchor can never exist without its metadata because the metadata rides in
/// the tree the anchor's commit points at.
///
/// **No `journal.json` cache row is written here.** The metadata cache
/// (#0156) does not exist yet; when it does, its row rides in this same lock
/// as composition work, not here. A checkpoint the cache misses is the safe
/// direction — the cache may under-report the journal, never over-report it
/// (#0033's invariant) — and #0030 rebuilds it from refs alone.
public enum JournalCheckpoint {

    /// Captures current state and writes one journal entry, returning it.
    ///
    /// `traversal` is non-nil exactly when undo/redo is writing the entry —
    /// entry kind is decided by that field's presence, never by matching
    /// `operation`, which is display-only free text (#0034 decision 7).
    /// `command` and `agent` are pass-throughs for M3's CLI; engine callers
    /// leave them nil.
    @discardableResult
    public static func checkpoint(
        operation: String,
        label: String? = nil,
        command: String? = nil,
        agent: JournalEntryMetadata.Agent? = nil,
        traversal: JournalChain.Traversal? = nil,
        lockTimeout: Duration = .seconds(10),
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> JournalAnchor.Entry {
        try JournalLock(context: context).withLock(timeout: lockTimeout) {
            let sequencer = try SequencerSnapshot.capture(in: context, git: git)
            return try writeEntry(
                capturing: RefSnapshot.capture(in: context, git: git),
                index: try IndexSnapshot.capture(in: context, git: git),
                worktree: try WorktreeSnapshot.capture(in: context, git: git),
                sequencer: sequencer,
                operation: operation,
                label: label,
                command: command,
                agent: agent,
                traversal: traversal,
                in: context,
                git: git)
        }
    }

    /// Writes one entry recording `snapshot` as the captured state, assuming
    /// the caller already holds the journal lock (#0032).
    ///
    /// The seam exists for the restore flow (#0168), which must write its
    /// pre-restore entry inside its own lock and from the same capture its
    /// guard ran against. It cannot call `checkpoint` for either half of
    /// that: a nested `withLock` on the journal's lock file self-deadlocks
    /// until its timeout — `flock(2)` denies a second exclusive lock taken
    /// through a second descriptor even in the same process (measured on
    /// macOS: `EWOULDBLOCK`) — and a second `RefSnapshot.capture` taken after
    /// the guard's would let the entry describe a state the guard never
    /// checked.
    static func writeEntry(
        capturing snapshot: RefSnapshot,
        index: IndexSnapshot? = nil,
        worktree: WorktreeSnapshot? = nil,
        sequencer: SequencerSnapshot? = nil,
        operation: String,
        label: String? = nil,
        command: String? = nil,
        agent: JournalEntryMetadata.Agent? = nil,
        traversal: JournalChain.Traversal? = nil,
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> JournalAnchor.Entry {
        let base = context.topLevel ?? context.gitDir

        let hashed = try git.run(
            ["hash-object", "-w", "--stdin"],
            workingDirectory: base,
            standardInput: snapshot.serialized())
        guard let refsBlob = hashed.lines.first, !refsBlob.isEmpty else {
            throw JournalAnchor.Error.malformedPlumbingOutput(
                command: "hash-object", line: "")
        }

        // The newest existing id makes same-millisecond writes — and a
        // clock stepping backwards — still produce ascending ids.
        let id = JournalEntryID.generate(
            after: try JournalAnchor.list(in: context, git: git).last?.id)

        let metadata = JournalEntryMetadata(
            id: id,
            operation: operation,
            command: command,
            label: label,
            timestamp: Date(),
            worktree: .init(name: context.worktreeName, path: base),
            captured: JournalEntryMetadata.Captured(
                refs: true, head: true,
                index: index?.captured ?? .notCaptured,
                worktree: worktree == nil ? .notCaptured : .stash,
                untracked: worktree != nil,
                sequencer: sequencer.map { .init($0.layout) } ?? .notCaptured),
            agent: agent,
            traversal: traversal)

        var keepAlive = try keepAliveParents(of: snapshot, at: base, git: git)
        // The worktree snapshot's commit is reachable from no ref, so it must
        // be a parent or ordinary maintenance may reclaim it — the same reason
        // captured ref tips are parents. Its *position* in this list carries
        // no meaning: `worktreeCommit` above is the identification path
        // (#0202), read from its own tree entry, not from where it lands
        // here relative to whatever else this list grows to hold.
        if let worktree { keepAlive.append(worktree.commit) }
        // NOT `keepAlive.append(contentsOf: sequencer.keepAlive)`, as this
        // issue's own literal text specified: `SequencerSnapshot.keepAlive`
        // returns TREE oids (the sequencer tree, and AUTO_MERGE's tree when
        // present) — commit-tree's `-p` requires an actual commit, and a tree
        // there is a hard `fatal: <oid> is not a valid 'commit' object`, exit
        // 128, on every mid-rebase checkpoint (measured: this crashed the
        // round-trip test the issue calls "the point", and reproduced with a
        // two-line scratch repo independent of any fixture). The sequencer's
        // own tree needs no parent slot regardless: `JournalAnchor.write`
        // already embeds `contents.sequencerTree` as a subtree of the anchor
        // commit's own tree, so it is reachable from the anchor with no
        // parent needed. AUTO_MERGE's tree (only present under
        // merge.conflictStyle=diff3/zdiff3) has no reachability path in this
        // design — it is not embedded in the anchor tree and cannot be a
        // commit parent — which is a real gap left for review rather than
        // silently dropped; see the round's report.

        var indexTree: String?
        var indexBlob: String?
        switch index {
        case let .tree(oid): indexTree = oid
        case let .raw(blob): indexBlob = blob
        case nil: break
        }

        let contents = JournalAnchor.Contents(
            metadataJSON: try metadata.serialized(),
            refsBlob: refsBlob,
            indexTree: indexTree,
            indexBlob: indexBlob,
            untrackedTree: worktree?.untrackedTree,
            sequencerTree: sequencer?.tree,
            worktreeCommit: worktree?.commit,
            keepAlive: keepAlive)
        return try JournalAnchor.write(contents, id: id, in: context, git: git)
    }

    /// The commit OIDs the snapshot commit must carry as parents so captured
    /// history stays reachable after the refs pointing at it are deleted:
    /// a detached `HEAD`'s commit, plus every captured ref's oid **peeled to
    /// a commit** — an annotated tag's `for-each-ref` oid is the tag object,
    /// which cannot be a commit parent (`commit-tree` rejects it, exit 128).
    ///
    /// One `cat-file --batch-check` pass peels everything: each oid goes in
    /// as `<oid>^{commit}`, a commit comes back as itself, an annotated tag
    /// as its peeled commit, and anything unpeelable — a tag pointing at a
    /// blob or tree — as `<input> missing`, which is skipped: there is no
    /// commit to keep alive behind it. Deduplicated here so a hundred refs
    /// on one tip contribute one parent and one argv slot; git would also
    /// dedupe (warning, exit 0), but argv is finite and warnings are noise.
    ///
    /// The tag *object* itself is not kept: a commit parent confers
    /// reachability on commits, and no snapshot-commit structure can hold a
    /// tag. If an annotated tag is deleted after capture and its tag object
    /// reclaimed, restoring that ref fails atomically — the whole
    /// `update-ref --stdin` transaction is rejected (`fatal: … nonexistent
    /// object`, exit 128) and no ref moves. Measured; accepted and
    /// documented rather than papered over.
    static func keepAliveParents(
        of snapshot: RefSnapshot,
        at base: String,
        git: GitProcess
    ) throws -> [String] {
        var oids: [String] = []
        if case let .detached(oid) = snapshot.head { oids.append(oid) }
        oids += snapshot.refs.map(\.oid)
        var seen: Set<String> = []
        let unique = oids.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return [] }

        let input = unique.map { "\($0)^{commit}\n" }.joined()
        let output = try git.run(
            ["cat-file", "--batch-check=%(objectname) %(objecttype)"],
            workingDirectory: base,
            standardInput: Data(input.utf8))

        var parents: [String] = []
        var parentSeen: Set<String> = []
        for line in output.lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count >= 2 else {
                throw JournalAnchor.Error.malformedPlumbingOutput(
                    command: "cat-file", line: line)
            }
            guard fields[1] == "commit" else { continue }
            let oid = String(fields[0])
            if parentSeen.insert(oid).inserted { parents.append(oid) }
        }
        return parents
    }
}
