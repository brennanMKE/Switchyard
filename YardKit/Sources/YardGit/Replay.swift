// Replay.swift — revert and cherry-pick one commit against the current
// branch (#0360)

import Foundation

/// The two single-commit replay operations (#0360): apply the inverse of one
/// commit onto the current branch as a new commit (`revert`), or replay one
/// commit from elsewhere onto it (`cherry-pick`). Both run the porcelain
/// path — `git revert --no-edit` / `git cherry-pick` — against a known
/// target, which is a different shape from Rewrite's detached
/// rebuild-and-replay and deliberately simpler:
///
/// 1. **Refuse first** — every impossible operation is detected before the
///    first object is written: an unknown revision, an unmerged index, a
///    merge commit for a revert (git needs `-m`'s parent selection, which
///    this surface does not offer), and a pick of a commit already reachable
///    from `HEAD` are all typed refusals raised before anything is touched
///    and before any journal entry is written.
/// 2. **Let git commit** — the porcelain invocation keeps `HEAD` on the
///    branch and moves the ref itself, once, only when the commit completes:
///    there is no detached scratch replay and no `update-ref` of our own to
///    pin. A conflicted run leaves git's own measured resumable state —
///    exit 1, `CHERRY_PICK_HEAD` (plus `REVERT_HEAD` for a revert), the
///    conflicted stage list — mapped to the typed `blockedOnConflicts`;
///    every other failure is aborted before being surfaced.
/// 3. **Signing** — the #0060 explicit flag for the resolved intent rides
///    the porcelain invocation. The porcelain path honors `commit.gpgsign`
///    (measured, git 2.50.1 — the ignore finding #0060 recorded is
///    `commit-tree`-specific), so `.config` really is config-decided here,
///    and `--gpg-sign`/`--no-gpg-sign` override the config either way.
///
/// The whole operation runs inside one `JournalCheckpoint.around`, so
/// `yard undo` reverses it as a single step. `GIT_EDITOR` is pinned `false`
/// by `GitProcess`, and `--no-edit` is pinned on `revert` besides: git's
/// default revert message lands without an editor ever being invoked, and a
/// cherry-pick commits with the picked commit's own message.
public struct Replay: Equatable, Sendable {

    /// What a completed replay produced: the branch's new head oid — the
    /// inverse commit a revert created, or the replayed commit a pick did.
    public struct Result: Sendable, Equatable, Encodable {

        /// The full oid the current branch's tip now names.
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

    /// Applies the inverse of `commit` onto the current branch as one new
    /// commit — `git revert --no-edit <commit>` with the signing intent
    /// spelled on it. Non-interactive: git's default `Revert "<subject>"`
    /// message, never an editor.
    ///
    /// - Throws: `ReplayError.unknownCommit` when `commit` does not resolve;
    ///   `.blockedOnConflicts` when the index already holds unmerged entries
    ///   (refused before anything is touched) or the inverse change could
    ///   not apply cleanly (the revert is left in progress, resumable);
    ///   `.mergeRevertRefused` when `commit` is a merge; `.signingFailed`
    ///   when a signature was attempted and could not be produced;
    ///   `GitProcess.Failure` for every other non-zero exit.
    public static func revert(
        commit: String,
        signing: CommitCreate.Signing = .config,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Result {
        try run(.revert(commit: commit), signing: signing,
                at: path, git: git, extraEnvironment: extraEnvironment)
    }

    /// Replays `commit` onto the current branch as one new commit —
    /// `git cherry-pick <commit>` with the signing intent spelled on it,
    /// the picked commit's own message.
    ///
    /// - Throws: `ReplayError.unknownCommit` when `commit` does not resolve;
    ///   `.blockedOnConflicts` as in `revert`; `.alreadyReachable` when
    ///   `commit` is already reachable from `HEAD` — its change is on the
    ///   branch, and replaying it would duplicate it; `.signingFailed` as in
    ///   `revert`; `GitProcess.Failure` for every other non-zero exit — a
    ///   merge commit among them, which git refuses without `-m`'s parent
    ///   selection and this surface does not offer.
    public static func cherryPick(
        commit: String,
        signing: CommitCreate.Signing = .config,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Result {
        try run(.cherryPick(commit: commit), signing: signing,
                at: path, git: git, extraEnvironment: extraEnvironment)
    }
}

// MARK: - The walk

private extension Replay {

    /// Which subcommand is being run — the one input `walk` needs.
    enum Request {
        case revert(commit: String)
        case cherryPick(commit: String)
    }

    /// Everything the porcelain invocation needs, resolved before the
    /// checkpoint so the body only mutates.
    struct Plan {
        /// The journal operation name — "revert" or "cherry-pick".
        let operation: String
        /// The git subcommand, spelled the same way as the operation.
        let subcommand: String
        /// The resolved commit the subcommand targets.
        let oid: String
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
        case let .revert(commit):
            let commitOid = try resolve(commit, at: path, git: git,
                                        extraEnvironment: extraEnvironment)
            try refuseUnmergedIndex(at: path, git: git, extraEnvironment: extraEnvironment)
            let parents = try parentOids(of: commitOid, at: path, git: git,
                                         extraEnvironment: extraEnvironment)
            if parents.count > 1 {
                throw ReplayError.mergeRevertRefused(commit: commitOid)
            }
            return Plan(operation: "revert", subcommand: "revert", oid: commitOid)

        case let .cherryPick(commit):
            let commitOid = try resolve(commit, at: path, git: git,
                                        extraEnvironment: extraEnvironment)
            try refuseUnmergedIndex(at: path, git: git, extraEnvironment: extraEnvironment)
            try refuseAlreadyReachable(commitOid, at: path, git: git,
                                       extraEnvironment: extraEnvironment)
            return Plan(operation: "cherry-pick", subcommand: "cherry-pick", oid: commitOid)
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
            throw ReplayError.unknownCommit(revision)
        }
        return oid
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

    /// A pick of a commit `HEAD` already reaches would duplicate its change
    /// on the branch — git would replay it as a (redundant) new commit.
    /// `merge-base --is-ancestor` is the reachability probe Rewrite's
    /// `refuseOffRef` runs in the opposite direction.
    static func refuseAlreadyReachable(
        _ commitOid: String,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws {
        let probe = try git.capture(
            ["merge-base", "--is-ancestor", commitOid, "HEAD"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        guard probe.exitCode != 0 else {
            throw ReplayError.alreadyReachable(commit: commitOid)
        }
    }

    /// Refuse an unmerged index before anything is touched — the same
    /// contract Rewrite refuses under, in the same place in the sequence.
    static func refuseUnmergedIndex(
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws {
        let conflicts = try conflictedFiles(at: path, git: git)
        guard conflicts.isEmpty else {
            throw ReplayError.blockedOnConflicts(files: conflicts)
        }
    }
}

// MARK: - Execution

private extension Replay {

    /// Runs the one porcelain invocation inside the checkpoint. Assumes
    /// every guard passed. The commit (and the ref move) is git's own: on
    /// success the current branch's tip is the new commit.
    static func perform(
        _ plan: Plan,
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Result {
        let inEffect = try CommitCreate.signingInEffect(
            signing, in: path, git: git, extraEnvironment: extraEnvironment)
        let arguments = [plan.subcommand]
            + (plan.subcommand == "revert" ? ["--no-edit"] : [])
            + CommitCreate.arguments(for: signing)
            + [plan.oid]
        let output: GitProcess.Output
        do {
            output = try git.capture(
                arguments,
                workingDirectory: path,
                extraEnvironment: extraEnvironment,
                timeout: inEffect ? GitProcess.signingTimeout : nil
            )
        } catch let failure as GitProcess.Failure {
            if case .timedOut = failure {
                throw try classifyTimeout(
                    failure, signingInEffect: inEffect, subcommand: plan.subcommand,
                    at: path, git: git, extraEnvironment: extraEnvironment)
            }
            throw failure
        }
        guard output.exitCode == 0 else {
            throw try classifiedFailure(
                output: output,
                arguments: arguments,
                subcommand: plan.subcommand,
                signingInEffect: inEffect,
                at: path, git: git, extraEnvironment: extraEnvironment
            )
        }
        let head = try git.run(
            ["rev-parse", "HEAD"], workingDirectory: path, extraEnvironment: extraEnvironment
        ).lines.first ?? ""
        return Result(head: head)
    }

    /// Classifies a failed porcelain invocation, by the index and not the
    /// message, the same shape Rewrite's classifier uses: non-empty
    /// conflicts stay resumable (`blockedOnConflicts`, git's own state left
    /// exactly as the run left it — `CHERRY_PICK_HEAD`/`REVERT_HEAD`, the
    /// conflicted stages, the sequencer); a signing failure aborts first (it
    /// can never sign, so it is not resumable); anything else aborts and
    /// surfaces git's own failure.
    static func classifiedFailure(
        output: GitProcess.Output,
        arguments: [String],
        subcommand: String,
        signingInEffect: Bool,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Error {
        let conflicts = try conflictedFiles(at: path, git: git)
        guard conflicts.isEmpty else {
            return ReplayError.blockedOnConflicts(files: conflicts)
        }

        if let failure = CommitCreate.classify(
            stderr: output.standardError, signingInEffect: signingInEffect) {
            _ = try? abort(subcommand, at: path, git: git,
                           extraEnvironment: extraEnvironment)
            switch failure {
            case let .signingFailed(reason):
                return ReplayError.signingFailed(reason: reason)
            }
        }

        _ = try? abort(subcommand, at: path, git: git,
                       extraEnvironment: extraEnvironment)
        return GitProcess.Failure.exited(
            code: output.exitCode, stderr: output.standardError, arguments: arguments)
    }

    /// Classifies a `GitProcess.Failure.timedOut` from the replay, the
    /// mirror of `Rewrite.classifyPickTimeout`: a timed-out replay can never
    /// be resumed from mid-hang, so it is aborted unconditionally, and a
    /// signing failure is typed; otherwise `failure` is rethrown unchanged.
    static func classifyTimeout(
        _ failure: GitProcess.Failure,
        signingInEffect: Bool,
        subcommand: String,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Error {
        _ = try? abort(subcommand, at: path, git: git,
                       extraEnvironment: extraEnvironment)
        guard case let .timedOut(after, _, _) = failure, signingInEffect else {
            return failure
        }
        return ReplayError.signingFailed(
            reason: "the replay did not finish within \(after) and was terminated -- "
                + "likely a signing prompt with no way to answer it")
    }

    /// Backs out of a failed replay. The subcommand that started the state
    /// is the one that aborts it: `git revert --abort` for a revert,
    /// `git cherry-pick --abort` for a pick. A failure that happened before
    /// any state existed makes this a harmless no-op.
    static func abort(
        _ subcommand: String,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> GitProcess.Output {
        try git.run(
            [subcommand, "--abort"], workingDirectory: path,
            extraEnvironment: extraEnvironment)
    }
}

// MARK: - Entry point

private extension Replay {

    /// Resolves the request, then runs the whole replay inside one
    /// checkpoint.
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

/// Why `Replay.revert`/`.cherryPick` refused, or could not finish.
public enum ReplayError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A named revision does not resolve to a commit. Raised before
    /// anything is touched.
    case unknownCommit(String)
    /// The commit to revert is a merge: reverting one needs git's `-m`
    /// parent selection, which this surface does not offer. Raised before
    /// anything is touched.
    case mergeRevertRefused(commit: String)
    /// The commit to pick is already reachable from `HEAD` — its change is
    /// on the branch, and replaying it would duplicate it. Raised before
    /// anything is touched.
    case alreadyReachable(commit: String)
    /// Either the index already held unmerged entries (refused before
    /// anything was touched), or the replay conflicted — in the replay case
    /// the operation is left in progress, resumable with git's own state,
    /// and `files` names the conflicted paths.
    case blockedOnConflicts(files: [ConflictedFile])
    /// A signature was attempted and could not be produced.
    case signingFailed(reason: String)

    public var description: String {
        switch self {
        case let .unknownCommit(revision):
            "unknown commit '\(revision)' — it does not resolve in this repository; nothing was touched"
        case let .mergeRevertRefused(commit):
            "reverting \(commit) is refused: it is a merge commit and reverting one needs "
                + "git's -m parent selection, which this surface does not offer"
        case let .alreadyReachable(commit):
            "cherry-picking \(commit) is refused: it is already reachable from HEAD — "
                + "its change is on the branch, and replaying it would duplicate it"
        case let .blockedOnConflicts(files):
            "replay blocked on conflicts in "
                + files.map(\.path).joined(separator: ", ")
        case let .signingFailed(reason):
            "signing failed: \(reason)"
        }
    }
}

// MARK: - §6 exit class

extension ReplayError: ExitClassCarrying {
    public var exitClass: ExitClass {
        switch self {
        case .unknownCommit, .mergeRevertRefused, .alreadyReachable:
            .repositoryError
        case .blockedOnConflicts: .blockedOnConflicts
        case .signingFailed: .signingFailed
        }
    }
}
