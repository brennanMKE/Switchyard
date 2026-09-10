// Rewrite.swift — reorder, drop, and reword one commit on the branch (#0063)

import Foundation

/// The remaining non-interactive history rewrites (#0063): move a commit
/// within the branch (`--before|--after <ref>`), remove one, or rewrite its
/// message. All three are one shape — #0060's decision, the walk/replay
/// Split and Absorb already use — differing only in how the branch's
/// first-parent list is modified:
///
/// 1. **Refuse first** — every impossible operation is detected before the
///    first object is written: an unknown revision, an unmerged index, a
///    commit off the caller's ref, a dropped merge, a reorder whose target
///    position is off the first-parent chain, a rewrite that would have to
///    create a new root commit, and a message that already matches are all
///    typed refusals raised before anything is touched and before any
///    journal entry is written.
/// 2. **Modify the first-parent list** — the walk reads the ref `HEAD`
///    names as a first-parent chain, oldest first, and applies the one edit:
///    `reword` replaces that commit's message (the commit is rebuilt with
///    `commit-tree`, tree and parents byte-preserved — the message arrives
///    as a flag, so `GIT_EDITOR` is never invoked); `drop` removes it
///    (refused for a merge, whose second parent would be silently lost);
///    `reorder` moves it to the named position on the same chain.
/// 3. **Rebuild and replay** — the unchanged prefix of the chain keeps its
///    original oids. A reword's replacement commit is built with
///    `commit-tree`; everything after the first changed position is replayed
///    with `git cherry-pick`, oldest first, which re-derives each
///    descendant's tree against its new parent. A conflicted pick is left in
///    progress, resumable (`blockedOnConflicts`); every other replay failure
///    is aborted before being surfaced.
/// 4. **Move the ref once** — `update-ref --stdin` with the old value
///    pinned, the single commit point of the whole rewrite. Until it moves,
///    any failure leaves history untouched.
/// 5. **Signing** — the #0060 rule: the explicit flag for the resolved
///    intent, never config reliance. `commit-tree` is plumbing and ignores
///    `commit.gpgsign` (measured, git 2.50.1), so the intent is spelled on
///    it explicitly; the replay is porcelain and gets
///    `CommitCreate.arguments(for:)` exactly as Split forwards them.
///
/// The whole rewrite runs inside one `JournalCheckpoint.around`, so
/// `yard undo` reverses it as a single step. `GIT_EDITOR` is pinned `false`
/// by `GitProcess` and is never invoked: every message rides stdin or a
/// flag.
public struct Rewrite: Equatable, Sendable {

    /// Where a reordered commit lands relative to the reference commit.
    public enum Position: Equatable, Sendable {
        /// Immediately before the reference commit.
        case before
        /// Immediately after the reference commit.
        case after
    }

    /// What a completed rewrite produced: the branch's new head oid.
    public struct Result: Sendable, Equatable, Encodable {

        /// The full oid the moved ref now names — the replayed tip, the
        /// rebuilt commit itself, or the kept parent (a dropped tip).
        public let head: String

        public init(head: String) {
            self.head = head
        }

        /// The stable wire key, identical to the stored-member name on
        /// purpose; no raw values — the case name IS the wire key.
        private enum CodingKeys: String, CodingKey {
            case head
        }
    }

    /// Rewrites one commit's message, non-interactively.
    ///
    /// The commit is rebuilt with `git commit-tree` — same tree, same
    /// parents, caller's message — and its descendants are replayed with
    /// `git cherry-pick`, then the ref moves once. Works for a merge commit
    /// too: `commit-tree` carries every original parent, so nothing is lost.
    ///
    /// - Throws: `RewriteError.unknownCommit` when `commit` does not
    ///   resolve; `.blockedOnConflicts` when the index already holds
    ///   unmerged entries (refused before anything is touched) or the
    ///   descendant replay conflicted (the pick is left in progress,
    ///   resumable); `.commitNotOnRef` when `commit` is not on the ref
    ///   `HEAD` names; `.nothingToDo` when the message already matches;
    ///   `.signingFailed` when a signature was attempted and could not be
    ///   produced; `GitProcess.Failure` for every other non-zero exit.
    public static func reword(
        commit: String,
        message: String,
        signing: CommitCreate.Signing = .config,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Result {
        try run(.reword(commit: commit, message: message), signing: signing,
                at: path, git: git, extraEnvironment: extraEnvironment)
    }

    /// Removes one commit from the branch, its changes and all.
    ///
    /// The descendants are replayed onto the dropped commit's parent — the
    /// `git rebase --onto` shape — so each later commit's tree is re-derived
    /// without the dropped commit's change.
    ///
    /// - Throws: `RewriteError.unknownCommit` when `commit` does not
    ///   resolve; `.commitNotOnRef` when `commit` is not on the ref `HEAD`
    ///   names; `.dropMergeRefused` when `commit` is a merge (a dropped
    ///   merge's second parent would be silently lost); `.rootRewriteRefused`
    ///   when `commit` is a root commit (the replay would have to create a
    ///   new root); `.blockedOnConflicts` as in `reword`;
    ///   `.signingFailed` as in `reword`; `GitProcess.Failure` for every
    ///   other non-zero exit.
    public static func drop(
        commit: String,
        signing: CommitCreate.Signing = .config,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Result {
        try run(.drop(commit: commit), signing: signing,
                at: path, git: git, extraEnvironment: extraEnvironment)
    }

    /// Moves one commit to immediately before or after another commit on
    /// the same first-parent chain.
    ///
    /// Both the moved commit and the reference must sit on the branch's
    /// first-parent chain — a cross-branch move is a rebase, not a reorder.
    /// The commits between the old and new positions are replayed in the
    /// new order; the branch's final tree is unchanged (a pure reorder
    /// re-applies the same set of changes in a different order).
    ///
    /// - Throws: `RewriteError.unknownCommit` when either revision does not
    ///   resolve; `.reorderTargetNotOnBranch` when either the moved commit
    ///   or the reference is not on the first-parent chain of the ref `HEAD`
    ///   names; `.nothingToDo` when the commit already sits at the requested
    ///   position; `.blockedOnConflicts` and `.signingFailed` as in
    ///   `reword`; `GitProcess.Failure` for every other non-zero exit.
    public static func reorder(
        commit: String,
        position: Position,
        reference: String,
        signing: CommitCreate.Signing = .config,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Result {
        try run(.reorder(commit: commit, position: position, reference: reference),
                signing: signing, at: path, git: git, extraEnvironment: extraEnvironment)
    }
}

// MARK: - The walk

private extension Rewrite {

    /// Which subcommand is being run — the one input `walk` needs.
    enum Request {
        case reword(commit: String, message: String)
        case drop(commit: String)
        case reorder(commit: String, position: Position, reference: String)
    }

    /// A replacement commit built with `git commit-tree`: tree and parents
    /// byte-preserved from the original, message from the caller.
    struct Rebuild {
        let tree: String
        let parents: [String]
        let message: String
    }

    /// Everything the rebuild and replay need, resolved before the
    /// checkpoint so the body only mutates.
    struct Plan {
        let operation: String
        let rebuild: Rebuild?
        /// Where HEAD detaches before the replay: a reword detaches on its
        /// rebuilt commit; a drop or reorder on the unchanged commit that
        /// precedes the first pick. `nil` only alongside a non-nil rebuild.
        let detachAt: String?
        /// The commits to pick, oldest first. Empty means the ref moves
        /// straight to the rebuilt (or kept) commit.
        let picks: [String]
        let refName: String
        let oldTip: String
        let attached: Bool
    }

    /// Resolves the request into a `Plan`, raising every typed refusal
    /// before anything is touched. Reads only — no object is written here.
    static func walk(
        _ request: Request,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Plan {
        switch request {
        case let .reword(commit, message):
            let commitOid = try resolve(commit, at: path, git: git,
                                        extraEnvironment: extraEnvironment)
            try refuseUnmergedIndex(at: path, git: git, extraEnvironment: extraEnvironment)
            let head = try resolveHead(at: path, git: git, extraEnvironment: extraEnvironment)
            try refuseOffRef(commitOid, head, at: path, git: git,
                             extraEnvironment: extraEnvironment)
            let tree = try git.run(
                ["rev-parse", "\(commitOid)^{tree}"],
                workingDirectory: path, extraEnvironment: extraEnvironment
            ).lines.first ?? ""
            let parents = try parentOids(of: commitOid, at: path, git: git,
                                         extraEnvironment: extraEnvironment)
            let original = try git.run(
                ["log", "-n", "1", "--format=%B", commitOid],
                workingDirectory: path, extraEnvironment: extraEnvironment
            ).text
            if original == message {
                throw RewriteError.nothingToDo
            }
            let descendants = try git.run(
                ["rev-list", "--reverse", "\(commitOid)..\(head.tip)"],
                workingDirectory: path, extraEnvironment: extraEnvironment
            ).lines
            return Plan(
                operation: "reword",
                rebuild: Rebuild(tree: tree, parents: parents, message: message),
                detachAt: nil, picks: descendants,
                refName: head.refName, oldTip: head.tip, attached: head.attached)

        case let .drop(commit):
            let commitOid = try resolve(commit, at: path, git: git,
                                        extraEnvironment: extraEnvironment)
            try refuseUnmergedIndex(at: path, git: git, extraEnvironment: extraEnvironment)
            let head = try resolveHead(at: path, git: git, extraEnvironment: extraEnvironment)
            try refuseOffRef(commitOid, head, at: path, git: git,
                             extraEnvironment: extraEnvironment)
            let parents = try parentOids(of: commitOid, at: path, git: git,
                                         extraEnvironment: extraEnvironment)
            if parents.count > 1 {
                throw RewriteError.dropMergeRefused(commit: commitOid)
            }
            guard let base = parents.first else {
                throw RewriteError.rootRewriteRefused(operation: "drop", commit: commitOid)
            }
            let descendants = try git.run(
                ["rev-list", "--reverse", "\(commitOid)..\(head.tip)"],
                workingDirectory: path, extraEnvironment: extraEnvironment
            ).lines
            return Plan(
                operation: "drop", rebuild: nil, detachAt: base, picks: descendants,
                refName: head.refName, oldTip: head.tip, attached: head.attached)

        case let .reorder(commit, position, reference):
            let commitOid = try resolve(commit, at: path, git: git,
                                        extraEnvironment: extraEnvironment)
            try refuseUnmergedIndex(at: path, git: git, extraEnvironment: extraEnvironment)
            let head = try resolveHead(at: path, git: git, extraEnvironment: extraEnvironment)
            let referenceOid = try resolve(reference, at: path, git: git,
                                           extraEnvironment: extraEnvironment)
            // The first-parent chain of the ref that moves, oldest first.
            // Both the moved commit and the reference must sit on it — a
            // cross-branch reorder is a rebase, not a reorder.
            let chain = try git.run(
                ["rev-list", "--first-parent", "--reverse", head.tip],
                workingDirectory: path, extraEnvironment: extraEnvironment
            ).lines
            guard let from = chain.firstIndex(of: commitOid) else {
                throw RewriteError.reorderTargetNotOnBranch(
                    revision: commitOid, ref: head.refName)
            }
            guard let to = chain.firstIndex(of: referenceOid) else {
                throw RewriteError.reorderTargetNotOnBranch(
                    revision: referenceOid, ref: head.refName)
            }
            if commitOid == referenceOid {
                throw RewriteError.nothingToDo
            }
            var moved = chain
            moved.remove(at: from)
            let shifted = to > from ? to - 1 : to
            moved.insert(commitOid, at: position == .before ? shifted : shifted + 1)
            guard moved != chain else {
                throw RewriteError.nothingToDo
            }
            var first = 0
            while first < chain.count, chain[first] == moved[first] { first += 1 }
            guard first > 0 else {
                throw RewriteError.rootRewriteRefused(operation: "reorder", commit: commitOid)
            }
            return Plan(
                operation: "reorder", rebuild: nil, detachAt: chain[first - 1],
                picks: Array(moved[first...]),
                refName: head.refName, oldTip: head.tip, attached: head.attached)
        }
    }

    /// Resolves one revision, typing a failure to refuse before anything is
    /// touched.
    static func resolve(
        _ revision: String,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> String {
        let output = try git.capture(
            ["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        guard output.exitCode == 0, let oid = output.lines.first, !oid.isEmpty else {
            throw RewriteError.unknownCommit(revision)
        }
        return oid
    }

    struct Head {
        let refName: String
        let tip: String
        let attached: Bool
    }

    /// The ref that moves once: the branch `HEAD` names, or `HEAD` itself
    /// when detached — the same resolution Split performs.
    static func resolveHead(
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Head {
        let symref = try git.capture(
            ["symbolic-ref", "-q", "HEAD"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        let attached = symref.exitCode == 0
        let refName = attached ? (symref.lines.first ?? "HEAD") : "HEAD"
        let tip = try git.run(
            ["rev-parse", "--verify", "\(refName)^{commit}"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        ).lines.first ?? ""
        return Head(refName: refName, tip: tip, attached: attached)
    }

    /// The commit's parents, first-parent first — `rev-list --parents -n 1`
    /// prints the commit followed by every parent on one line.
    static func parentOids(
        of commitOid: String,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> [String] {
        let output = try git.run(
            ["rev-list", "--parents", "-n", "1", commitOid],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        guard let line = output.lines.first else { return [] }
        return line.split(separator: " ").dropFirst().map(String.init)
    }

    /// `commit` must sit on the history of the ref that moves — the
    /// descendants are read as `commit..<ref>`, and moving a ref the commit
    /// is not on would orphan the caller's line.
    static func refuseOffRef(
        _ commitOid: String,
        _ head: Head,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws {
        let probe = try git.capture(
            ["merge-base", "--is-ancestor", commitOid, head.tip],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        guard probe.exitCode == 0 else {
            throw RewriteError.commitNotOnRef(commit: commitOid, ref: head.refName)
        }
    }

    /// Refuse an unmerged index before anything is touched — a staged
    /// conflict resolution is work the replay would refuse and the index
    /// scratch would reset away, the same contract Split refuses under, in
    /// the same place in the sequence.
    static func refuseUnmergedIndex(
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws {
        let conflicts = try conflictedFiles(at: path, git: git)
        guard conflicts.isEmpty else {
            throw RewriteError.blockedOnConflicts(files: conflicts)
        }
    }
}

// MARK: - Execution

private extension Rewrite {

    /// Builds the replacement commit (a reword), replays the picks, and
    /// moves the ref once. Assumes every guard passed and the checkpoint is
    /// already written.
    static func perform(
        _ plan: Plan,
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Result {
        let context = try WorktreeContext.resolve(path: path, git: git)
        // The caller's index bytes, restored after the scratch work and
        // before the replay (the replay's checkout refuses a dirty index),
        // and on any pre-replay failure. The checkpoint's own capture is
        // what `undo` uses; this one is the successful path's restore.
        let indexSnapshot = try IndexSnapshot.capture(in: context, git: git)

        // --- Phase 1: build the replacement commit, if this is a reword. ---
        var rebuiltOid: String?
        do {
            if let rebuild = plan.rebuild {
                // Plumbing: no hooks, no editor — the message rides stdin,
                // and signing is the explicit flag for the resolved intent
                // (#0060), since `commit-tree` ignores `commit.gpgsign`.
                let inEffect = try CommitCreate.signingInEffect(
                    signing, in: path, git: git, extraEnvironment: extraEnvironment)
                var arguments = ["commit-tree", rebuild.tree]
                for parent in rebuild.parents { arguments += ["-p", parent] }
                arguments += commitTreeArguments(signingInEffect: inEffect)
                rebuiltOid = try commitTree(
                    arguments,
                    message: rebuild.message,
                    signingInEffect: inEffect,
                    at: path, git: git, extraEnvironment: extraEnvironment)
            }
        } catch {
            // Pre-replay failure: put the caller's index back before
            // surfacing anything. No ref has moved; `undo` also reverses
            // the whole attempt.
            try? indexSnapshot.restore(in: context, git: git)
            throw error
        }

        // The scratch work is done — the caller's staged bytes come back
        // before any replay checkout, which refuses a dirty index.
        try indexSnapshot.restore(in: context, git: git)

        // The commit the ref lands on when nothing needs picking: the
        // rebuilt commit (a reworded tip), or the kept parent (a dropped
        // tip). A reorder always has picks.
        let newHead = rebuiltOid ?? plan.detachAt ?? plan.oldTip
        if plan.picks.isEmpty {
            try moveRef(refName: plan.refName, from: plan.oldTip, to: newHead,
                        at: path, git: git, extraEnvironment: extraEnvironment)
            return Result(head: newHead)
        }

        // --- Phase 2: replay the picks in order, then move the ref once.
        try git.run(
            ["checkout", "-q", "--detach", newHead],
            workingDirectory: path, extraEnvironment: extraEnvironment)
        do {
            let pickArguments = ["cherry-pick"]
                + CommitCreate.arguments(for: signing)
                + plan.picks
            let inEffect = try CommitCreate.signingInEffect(
                signing, in: path, git: git, extraEnvironment: extraEnvironment)
            let pickOutput: GitProcess.Output
            do {
                pickOutput = try git.capture(
                    pickArguments,
                    workingDirectory: path,
                    extraEnvironment: extraEnvironment,
                    timeout: inEffect ? GitProcess.signingTimeout : nil
                )
            } catch let failure as GitProcess.Failure {
                if case .timedOut = failure {
                    throw try classifyPickTimeout(
                        failure, signingInEffect: inEffect,
                        at: path, git: git, extraEnvironment: extraEnvironment)
                }
                throw failure
            }
            guard pickOutput.exitCode == 0 else {
                throw try classifiedPickFailure(
                    output: pickOutput,
                    arguments: pickArguments,
                    signing: signing,
                    at: path, git: git, extraEnvironment: extraEnvironment
                )
            }
            let replayedTip = try git.run(
                ["rev-parse", "HEAD"], workingDirectory: path, extraEnvironment: extraEnvironment
            ).lines.first ?? ""
            try moveRef(refName: plan.refName, from: plan.oldTip, to: replayedTip,
                        at: path, git: git, extraEnvironment: extraEnvironment)
            if plan.attached {
                try git.run(
                    ["symbolic-ref", "HEAD", plan.refName],
                    workingDirectory: path, extraEnvironment: extraEnvironment)
            }
            return Result(head: replayedTip)
        } catch {
            // A conflicted pick stays exactly as the pick left it — HEAD
            // detached on the new base, the pick in progress, the branch
            // unmoved — that is the resumable state the contract promises.
            // Every other failure is cleaned up first: a signing failure can
            // never be resumed, and git's own refusal leaves no pick worth
            // resuming.
            if case RewriteError.blockedOnConflicts = error { throw error }
            _ = try? git.run(
                ["cherry-pick", "--abort"], workingDirectory: path,
                extraEnvironment: extraEnvironment)
            try? indexSnapshot.restore(in: context, git: git)
            if plan.attached {
                _ = try? git.run(
                    ["symbolic-ref", "HEAD", plan.refName], workingDirectory: path,
                    extraEnvironment: extraEnvironment)
            }
            throw error
        }
    }

    /// The flag the #0060 rule contributes to a `git commit-tree` invocation:
    /// the explicit flag for the resolved intent, never config — the same
    /// rule Split's halves follow.
    static func commitTreeArguments(signingInEffect: Bool) -> [String] {
        signingInEffect ? ["--gpg-sign"] : ["--no-gpg-sign"]
    }

    /// Moves `refName` once, old value pinned, via `update-ref --stdin` —
    /// the single commit point of the whole rewrite. If the ref moved
    /// underneath the run, the old value no longer matches and git rejects
    /// the whole transaction, leaving the ref (and history) untouched.
    static func moveRef(
        refName: String,
        from oldOid: String,
        to newOid: String,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws {
        let input = "update \(refName) \(newOid) \(oldOid)\n"
        try git.run(
            ["update-ref", "--stdin"],
            workingDirectory: path,
            standardInput: Data(input.utf8),
            extraEnvironment: extraEnvironment
        )
    }

    /// One `git commit-tree`, message on stdin, classified exactly as
    /// `CommitCreate.run` classifies `git commit`: a signing failure is the
    /// typed `.signingFailed`, everything else is `GitProcess.Failure`.
    /// Measured: `commit-tree` accepts `--gpg-sign`/`--no-gpg-sign` and
    /// reads the message from stdin when no `-m` is passed (multi-paragraph
    /// messages round-trip byte-for-byte).
    static func commitTree(
        _ arguments: [String],
        message: String,
        signingInEffect: Bool,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> String {
        let output = try git.capture(
            arguments,
            workingDirectory: path,
            standardInput: Data(message.utf8),
            extraEnvironment: extraEnvironment
        )
        guard output.exitCode == 0, let oid = output.lines.first, !oid.isEmpty else {
            if signingInEffect, isSigningFailure(output.standardError) {
                throw RewriteError.signingFailed(
                    reason: output.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw GitProcess.Failure.exited(
                code: output.exitCode,
                stderr: output.standardError,
                arguments: arguments
            )
        }
        return oid
    }

    /// The measured stderr shapes of a failed `git commit-tree` signature.
    /// `commit-tree` is plumbing and refuses before any object write, so it
    /// never prints `git commit`'s `fatal: failed to write commit object`
    /// refusal — measured, git 2.50.1, a failing `gpg.program` under
    /// `--gpg-sign` exits 1 with `error: gpg failed to sign the data:` plus
    /// the helper's own output. `git commit`'s measured markers (#0036) are
    /// kept too, so a shape shared between the two still classifies.
    static let commitTreeSigningFailureMarkers = [
        "failed to write commit object",
        "either user.signingkey or gpg.ssh.defaultKeyCommand",
        "gpg failed to sign the data",
    ]

    static func isSigningFailure(_ stderr: String) -> Bool {
        commitTreeSigningFailureMarkers.contains { stderr.contains($0) }
    }

    /// Classifies a failed `git cherry-pick` replay, by the index and not
    /// the message, the same shape Split's classifier uses: non-empty
    /// conflicts stay resumable (`.blockedOnConflicts`, nothing aborted); a
    /// signing failure aborts the pick first (it can never sign, so it is
    /// not resumable); anything else aborts and surfaces git's own failure.
    static func classifiedPickFailure(
        output: GitProcess.Output,
        arguments: [String],
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Error {
        let conflicts = try conflictedFiles(at: path, git: git)
        guard conflicts.isEmpty else {
            return RewriteError.blockedOnConflicts(files: conflicts)
        }

        let inEffect = try CommitCreate.signingInEffect(
            signing, in: path, git: git, extraEnvironment: extraEnvironment)
        if let failure = CommitCreate.classify(
            stderr: output.standardError, signingInEffect: inEffect) {
            _ = try? git.run(
                ["cherry-pick", "--abort"], workingDirectory: path,
                extraEnvironment: extraEnvironment)
            switch failure {
            case let .signingFailed(reason):
                return RewriteError.signingFailed(reason: reason)
            }
        }

        _ = try? git.run(
            ["cherry-pick", "--abort"], workingDirectory: path,
            extraEnvironment: extraEnvironment)
        return GitProcess.Failure.exited(
            code: output.exitCode, stderr: output.standardError, arguments: arguments)
    }

    /// Classifies a `GitProcess.Failure.timedOut` from the replay, the
    /// mirror of `Absorb.classifyTimeout`: a timed-out pick can never be
    /// resumed from mid-hang, so it is aborted unconditionally, and a
    /// signing failure is typed; otherwise `failure` is rethrown unchanged.
    static func classifyPickTimeout(
        _ failure: GitProcess.Failure,
        signingInEffect: Bool,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Error {
        _ = try? git.run(
            ["cherry-pick", "--abort"], workingDirectory: path,
            extraEnvironment: extraEnvironment)
        guard case let .timedOut(after, _, _) = failure, signingInEffect else {
            return failure
        }
        return RewriteError.signingFailed(
            reason: "the descendant replay did not finish within \(after) and was terminated -- "
                + "likely a signing prompt with no way to answer it")
    }
}

// MARK: - Entry point

private extension Rewrite {

    /// Resolves the request, then runs the whole rewrite inside one
    /// checkpoint — both the rebuild and the replay, and the ref move.
    static func run(
        _ request: Request,
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Result {
        let plan = try walk(request, at: path, git: git, extraEnvironment: extraEnvironment)
        return try JournalCheckpoint.around(operation: plan.operation, at: path, git: git) { scoped in
            try perform(
                plan,
                signing: signing,
                at: path,
                git: scoped,
                extraEnvironment: extraEnvironment
            )
        }
    }
}

// MARK: - Errors

/// Why `Rewrite.reword`/`.drop`/`.reorder` refused, or could not finish.
public enum RewriteError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A named revision — the commit, or a reorder's reference — does not
    /// resolve to a commit. Raised before anything is touched.
    case unknownCommit(String)
    /// The commit to reword or drop is not on the ref `HEAD` names, so
    /// there are no well-defined descendants and no ref this operation
    /// could move.
    case commitNotOnRef(commit: String, ref: String)
    /// The commit to drop is a merge: dropping it would silently lose its
    /// second parent's line of history. Raised before anything is touched.
    case dropMergeRefused(commit: String)
    /// A reorder's moved commit or reference is not on the first-parent
    /// chain of the ref `HEAD` names — a cross-branch reorder is a rebase,
    /// not a reorder. Raised before anything is touched.
    case reorderTargetNotOnBranch(revision: String, ref: String)
    /// The rewrite would have to create a new root commit — dropping the
    /// chain's root, or moving any commit to or before it — which the
    /// cherry-pick replay cannot express. Raised before anything is touched.
    /// (Rewording the root works and is not refused.)
    case rootRewriteRefused(operation: String, commit: String)
    /// The reword's message already matches, or the reordered commit
    /// already sits at the requested position.
    case nothingToDo
    /// Either the index already held unmerged entries (refused before
    /// anything was touched), or the replay conflicted — in the replay case
    /// the pick is left in progress, resumable, and `files` names the
    /// conflicted paths.
    case blockedOnConflicts(files: [ConflictedFile])
    /// A signature was attempted and could not be produced.
    case signingFailed(reason: String)

    public var description: String {
        switch self {
        case let .unknownCommit(revision):
            "unknown commit '\(revision)' — it does not resolve in this repository; nothing was touched"
        case let .commitNotOnRef(commit, ref):
            "the commit (\(commit)) is not on \(ref) — check out the branch that contains it first"
        case let .dropMergeRefused(commit):
            "dropping \(commit) is refused: it is a merge commit and dropping it would "
                + "silently lose its second parent's line of history"
        case let .reorderTargetNotOnBranch(revision, ref):
            "the reorder target (\(revision)) is not on \(ref)'s first-parent chain — "
                + "a cross-branch reorder is a rebase, not a reorder"
        case let .rootRewriteRefused(operation, commit):
            "\(operation) cannot rewrite the first-parent chain's root (\(commit)) — "
                + "the replay would have to create a new root commit, which cherry-pick cannot do"
        case .nothingToDo:
            "nothing to do — the message already matches, or the commit already sits at "
                + "the requested position"
        case let .blockedOnConflicts(files):
            "rewrite blocked on conflicts in "
                + files.map(\.path).joined(separator: ", ")
        case let .signingFailed(reason):
            "signing failed: \(reason)"
        }
    }
}

// MARK: - §6 exit class

extension RewriteError: ExitClassCarrying {
    public var exitClass: ExitClass {
        switch self {
        case .unknownCommit, .commitNotOnRef, .dropMergeRefused, .reorderTargetNotOnBranch,
             .rootRewriteRefused, .nothingToDo:
            .repositoryError
        case .blockedOnConflicts: .blockedOnConflicts
        case .signingFailed: .signingFailed
        }
    }
}
