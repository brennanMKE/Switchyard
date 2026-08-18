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

public extension JournalCheckpoint {

    /// Runs `body` with a pre-operation journal entry written first, so
    /// `switchyard undo` works without the caller having asked (#0034
    /// decision 1's second entry kind).
    ///
    /// **One entry per user-level operation, not per primitive.** The
    /// primitives this wraps — `stageHunks`, `CommitCreate.run` — deliberately
    /// write no entries of their own, so a composed command like `commitHunks`
    /// produces exactly one. A checkpoint inside each primitive would litter
    /// the journal and make `undo` step through halves of a single action
    /// (guide §11 decision 15).
    ///
    /// The checkpoint is taken **before** `body` and is not rolled back if
    /// `body` throws: an entry describing the state before a failed attempt is
    /// correct and cheap, and removing it would need a second write on the
    /// error path for no gain.
    ///
    /// **`body` receives a `GitProcess` carrying the entry's id (#0221)**,
    /// scoped to exactly this call: every git subprocess `body` runs through
    /// the parameter it is handed exports `GitProcess.entryVariable`, so the
    /// `post-rewrite` hook can find its way back to the entry that was
    /// in-flight when the rewrite ran. `body` must use the parameter, not the
    /// outer `git` it may have captured — that captured value carries no id
    /// and a rewrite run through it attaches to nothing. Nothing is
    /// process-global: the id lives only on this one `GitProcess` value,
    /// which stops existing when `around` returns.
    ///
    /// **The entry id also goes on disk, inside the live sequencer
    /// directory itself — `RepositoryLayout.sequencerEntryIDFileName`
    /// joined onto the layout `SequencerSnapshot.capture` reports (guide
    /// §11 decision 24, #0273, superseding #0237/#0241/#0253/#0254/#0261's
    /// beside-the-sequencer file and every staleness rule those issues
    /// added for it).** The environment cannot survive a body that
    /// deliberately leaves an operation in progress — `Fixup.run` throwing
    /// `.blockedOnConflicts` leaves a rebase for the caller to resolve and
    /// continue, and whatever runs `git rebase --continue` is a new process
    /// with no scoped `GitProcess` to carry the id.
    ///
    /// **Writing inside the directory git owns means git's own lifecycle
    /// is the file's lifecycle.** Measured, git 2.50.1: both `git rebase
    /// --continue` and `git rebase --abort` remove the whole sequencer
    /// directory, our file included — so the file can never survive past
    /// the operation it names, and reading it back can never need to ask
    /// "is this still the same operation?" the way the old, longer-lived
    /// location did.
    ///
    /// **The file names an operation that is still in progress, not merely
    /// an entry that still exists.** It is written only once `body` has
    /// already thrown *and* a resumable git operation is still live —
    /// `SequencerSnapshot.capture` answering non-nil, the same
    /// `rebase-merge`/`rebase-apply` probe `Fixup`'s own conflict path
    /// answers "resumable" with. A `body` that cleans up before throwing —
    /// every `git rebase --abort` arm in `Fixup` — leaves no such state, so
    /// nothing is written for it. And nothing is ever written on a normal
    /// return: a call that never throws has nothing resumable to record, so
    /// it can never clobber a slot some other, still-in-progress call
    /// already occupies. `attachRewrite` is what reads the file back.
    ///
    /// **First-writer-wins.** A **second failing** call can still reach the
    /// write while a first operation's rebase is still live: its own body
    /// throws too (for `Fixup`, `git commit --fixup=` refuses the still-
    /// unmerged index the first conflict left behind, so no rebase of its
    /// own ever starts), and `SequencerSnapshot.capture` after the throw
    /// finds the *first* operation's rebase live — not one this body
    /// started. Writing here would overwrite the first call's entry id,
    /// orphaning its pre-operation `HEAD`. So the write is guarded by
    /// `sequencerWasLiveBefore`, bound once before `body` runs: a body can
    /// only have left a resumable operation of its **own** behind if no
    /// sequencer — this call's or a foreign one already live when it
    /// started — existed yet at that point. A second call reaching the
    /// catch with a sequencer already live before it started never writes,
    /// leaving the first call's slot (and a foreign rebase's absent one)
    /// untouched.
    static func around<T>(
        operation: String,
        at path: String,
        command: String? = nil,
        agent: JournalEntryMetadata.Agent? = nil,
        git: GitProcess = GitProcess(),
        fileManager: FileManager = .default,
        _ body: (GitProcess) throws -> T
    ) throws -> T {
        let context = try WorktreeContext.resolve(path: path, git: git)
        // The answer to "was a sequencer already live when THIS call
        // started" is bound once, before `body` runs, and required again in
        // the catch below: a body can only have left a resumable operation
        // of its own behind if none was live when it started. A foreign
        // rebase (or another switchyard operation's) already live at this
        // point belongs to nobody this call knows about and must never be
        // claimed -- or written into -- on its behalf.
        let sequencerWasLiveBefore = try SequencerSnapshot.capture(in: context, git: git) != nil
        let entry = try checkpoint(
            operation: operation, command: command, agent: agent,
            in: context, git: git)
        let scoped = GitProcess(executablePath: git.executablePath, journalEntryID: entry.id)

        do {
            return try body(scoped)
        } catch {
            // Only a body that leaves a resumable git operation behind gets
            // its id persisted -- validated against the live sequencer right
            // here, not inferred from the throw alone, since `Fixup`'s own
            // `git rebase --abort` arms throw too and must leave nothing.
            // `!sequencerWasLiveBefore` is what makes the write this call's
            // to make: a sequencer that was already live before this call
            // started cannot be the operation this call's own body left
            // behind, no matter what `SequencerSnapshot.capture` finds live
            // now.
            if !sequencerWasLiveBefore,
               let sequencerNow = try? SequencerSnapshot.capture(in: context, git: git),
               let entryIDPath = try? context.path(
                   for: sequencerNow.layout.rawValue + "/"
                       + RepositoryLayout.sequencerEntryIDFileName,
                   git: git) {
                try? entry.id.string.write(
                    toFile: entryIDPath, atomically: true, encoding: .utf8)
            }
            throw error
        }
    }

    /// Attaches an own-invocation rewrite mapping to the journal entry that
    /// was in flight when the rewrite ran — the other half of #0220's
    /// foreign path, and #0221's job. `entryID` is whatever the caller read
    /// back out of `GitProcess.entryVariable` in the `post-rewrite` hook's
    /// environment; parsing that environment is the hook glue's job (#0217),
    /// not this function's.
    ///
    /// **Neither an environment id nor a file means nothing is attached
    /// (guide §11 decision 19, #0237, superseded for the file's location by
    /// decision 24, #0273).** Before decision 19, the environment was the
    /// only carrier and a `nil` here always meant "took no
    /// `JournalCheckpoint.around`". Now a second source exists — the file
    /// `around` leaves inside the live sequencer directory when its body
    /// throws mid-operation — so `nil` means both were checked and neither
    /// named a live entry: no `entryVariable` in the environment, and either
    /// no sequencer live, no file inside it, an unparseable one, or one
    /// naming an entry that no longer exists. Falling back to an observed
    /// entry would still misrepresent the mapping as foreign-sourced, which
    /// is exactly the distinction `JournalObserved.Metadata.kind` exists to
    /// preserve (#0220), and inventing a new entry with nothing else to
    /// anchor would fabricate state nothing captured. This is a documented,
    /// tested `nil`, not a swallowed failure — the same shape #0220's
    /// own-invocation guard on `JournalObserved.record` already uses for the
    /// opposite half of this boundary.
    ///
    /// **The environment wins when both are present.** A scoped `GitProcess`
    /// means the operation is running right now; the file is the fallback
    /// for when it is not, read only when `entryID` is `nil`.
    ///
    /// **Guide §11 decision 24 (#0273): the file's own lifetime is now the
    /// staleness check.** It lives at
    /// `<layout>/RepositoryLayout.sequencerEntryIDFileName`, inside whatever
    /// sequencer directory `SequencerSnapshot.capture` finds live *right
    /// now* — never a fixed, worktree-wide path. Measured, git 2.50.1: `git
    /// rebase --continue` and `git rebase --abort` both remove the whole
    /// sequencer directory, our file included, so a file this call can find
    /// can only belong to whatever operation is live at the moment of the
    /// read. There is no operation-identity question left to ask — no
    /// `stillInProgress` flag, no `orig-head` stamp to compare — because a
    /// file naming a finished or abandoned operation cannot exist: finishing
    /// or abandoning it is exactly what removed the directory that held it.
    /// The one check that remains is `JournalAnchor.list`: the id a live
    /// file names must still be a live journal entry, in case it was pruned
    /// out from under a still-open operation.
    ///
    /// **This is correct only because a real `post-rewrite` hook (#0217)
    /// calls `attachRewrite` synchronously, as a child of the git process
    /// that is still holding the sequencer directory open** — measured,
    /// git 2.50.1: the hook fires and only *after it returns* does git
    /// remove `rebase-merge`/`rebase-apply`. A caller that asks after that
    /// git process has already exited can never observe the file, no matter
    /// when it asks — the directory is provably gone by then. This is the
    /// same synchronous-capture requirement `writeEntry`'s own
    /// `sequencer: SequencerSnapshot? = nil` parameter exists for: let
    /// whoever is positioned to observe the truth supply it, rather than
    /// re-derive a value that may no longer be derivable.
    ///
    /// **Mid-rebase dedup (#0233).** `JournalObserved.isMidRebaseAmend` is
    /// checked first, before the own/foreign split, so a mid-rebase `amend`
    /// invocation attaches nothing here for the same reason it records
    /// nothing on the foreign path: the rebase's own final `rebase`-sourced
    /// invocation repeats the pair and is the authoritative one.
    ///
    /// Throws only on a genuine persistence failure once there is an id to
    /// attach to. The totality invariant (#0043, #0191) — a failed attach
    /// must never surface as a non-zero hook exit — is the caller's job,
    /// exactly as it already is for `JournalObserved.record`.
    @discardableResult
    static func attachRewrite(
        _ decision: PostRewrite.Decision,
        entryID: JournalEntryID?,
        in context: WorktreeContext,
        git: GitProcess = GitProcess(),
        fileManager: FileManager = .default
    ) throws -> JournalAnchor.Entry? {
        if try JournalObserved.isMidRebaseAmend(
            decision, in: context, git: git, fileManager: fileManager) {
            return nil
        }

        guard decision.isOwnInvocation else { return nil }

        // The file is read only when the environment carried no id -- `??`
        // never even resolves the live sequencer otherwise. `fromFile` also
        // carries the path the id came from, so it can be cleared below
        // without touching a sequencer this call resolved nothing from.
        let fromFile = entryID == nil
            ? try inFlightEntryID(in: context, git: git, fileManager: fileManager)
            : nil
        guard let resolvedID = entryID ?? fromFile?.id else { return nil }

        let existing = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: resolvedID, in: context, git: git))
        let mapping = JournalEntryMetadata.RewriteMapping(
            source: decision.source.gitArgument, rewrites: decision.rewrites)
        let updated = existing.attachingRewrite(mapping)
        let attached = try JournalAnchor.updateMetadata(
            try updated.serialized(), for: resolvedID, in: context, git: git)
        // The operation is over at this point: remove the file the id was
        // resolved from, if it was the file -- a no-op when the id came
        // from the environment instead, since a different, still-open
        // operation's own file (guide §11 decision 24) is never this call's
        // to clear.
        if let path = fromFile?.path {
            try? fileManager.removeItem(atPath: path)
        }
        return attached
    }

    /// Reads the entry id `around` left inside the *currently live*
    /// sequencer directory, if any — `RepositoryLayout
    /// .sequencerEntryIDFileName` joined onto the layout
    /// `SequencerSnapshot.capture` reports right now, resolved through
    /// `WorktreeContext.path(for:)`, never by concatenating onto `.git/`.
    /// Returns both the id and the path it came from, so `attachRewrite` can
    /// clear exactly that file once the attach it enabled has succeeded.
    ///
    /// **No staleness branch beyond "does a live sequencer have this file,
    /// and does it name a live entry" (guide §11 decision 24, #0273).** The
    /// file cannot outlive the operation it was written for — git removes
    /// the whole directory on both `--continue` and `--abort` — so nothing
    /// here needs to ask whether the operation is *still* the one that wrote
    /// it: no sequencer live, or no file inside the one that is, both
    /// degrade the same way as an unparseable one or an id that no longer
    /// names a live journal entry (a crash between `around` writing the file
    /// and the operation finishing, or a prune that ran while the operation
    /// was still open) — no-attach, never an unrelated entry.
    private static func inFlightEntryID(
        in context: WorktreeContext,
        git: GitProcess,
        fileManager: FileManager
    ) throws -> (id: JournalEntryID, path: String)? {
        guard let sequencer = try SequencerSnapshot.capture(in: context, git: git) else {
            return nil
        }
        let path = try context.path(
            for: sequencer.layout.rawValue + "/" + RepositoryLayout.sequencerEntryIDFileName,
            git: git)
        guard fileManager.fileExists(atPath: path),
              let contents = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }

        // An unparseable file cannot name anything, so this degrades to
        // no-attach without cleaning it up (#0292). Cleanup is unreachable
        // in practice: the file's only writer is `around`'s catch, which
        // always writes a `JournalEntryID.string` -- valid by construction,
        // since `generate`/`incremented` only ever draw from the id
        // alphabet -- and decision 24 already bounds the file's lifetime to
        // the sequencer directory that holds it, so a stale file written by
        // anything else cannot survive to be read here.
        guard let id = JournalEntryID(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        // The file's own lifetime already rules out "names an operation
        // that has finished or been abandoned" (guide §11 decision 24). The
        // one case left is a prune that ran while the operation was still
        // open: the id no longer names a live journal entry, so clean the
        // file up the same way and degrade to no-attach.
        let stillLive = try JournalAnchor.list(in: context, git: git).contains { $0.id == id }
        guard stillLive else {
            try? fileManager.removeItem(atPath: path)
            return nil
        }
        return (id, path)
    }
}
