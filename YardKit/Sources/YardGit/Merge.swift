// Merge.swift — merge a branch into the current branch (#0361)

import Foundation

/// Merges one branch into the current branch, non-interactively (#0361).
///
/// The first operation that creates merge commits. Two intents, and **git's
/// silent fast-forward guess is never available**: the caller states one —
/// `--ff-only` refuses anything a fast-forward cannot reach, `--no-ff`
/// always creates a merge commit — and the UI sheet (#0361's planning pass)
/// sends exactly one of the two flags for the same reason.
///
/// 1. **Refuse first** — every impossible merge is detected before the first
///    object is written: an unknown branch, an unmerged index, an
///    already-up-to-date target, and unrelated histories (refused unless the
///    caller states `allowUnrelated`) are all typed refusals raised before
///    anything is touched and before any journal entry is written.
/// 2. **One porcelain merge** — `git merge --ff-only` / `--no-ff` does the
///    merge-base computation, the index and worktree update, the ref move,
///    and the merge commit in one step. The commit's message rides `-m`
///    (git's own default wording under `--no-edit` when the caller passes
///    none); `GIT_EDITOR` is pinned `false` by `GitProcess` and is never
///    invoked.
/// 3. **Signing** — the #0060 rule: the explicit flag for the resolved
///    intent, never config reliance. The merge is porcelain and gets
///    `CommitCreate.arguments(for:)` exactly as Split forwards them. A
///    signature that cannot be produced is never resumable, so the merge is
///    aborted before the failure is typed `.signingFailed`.
/// 4. **Conflicts are the resumable state** — a conflicted merge is left
///    exactly as git left it (`MERGE_HEAD` present, unmerged index), which
///    is the state `WhereAmI.isMidMerge` reports and the resolve UI (#0057)
///    completes. Typed `.blockedOnConflicts`, exit class 8. Every other
///    failure is surfaced as git produced it.
///
/// The whole merge runs inside one `JournalCheckpoint.around`, so `yard
/// undo` reverses it as a single step — including dropping a merge commit.
public struct Merge: Equatable, Sendable {

    /// Which merge the caller wants. There is no default case on purpose:
    /// the intent is the caller's explicit statement, never git's guess.
    public enum Intent: Equatable, Sendable {
        /// `--ff-only` — refuse unless the target is a strict descendant of
        /// HEAD; never creates a merge commit.
        case fastForwardOnly
        /// `--no-ff` — always create a merge commit, even when a
        /// fast-forward is possible.
        case noFastForward
    }

    /// What a completed merge produced: the branch's new head oid, and
    /// whether the merge fast-forwarded — a fast-forward's head is exactly
    /// the target commit; a merge commit is a fresh object that is not.
    public struct Result: Sendable, Equatable, Encodable {

        /// The full oid the merged branch now names — the target commit
        /// after a fast-forward, the merge commit otherwise.
        public let head: String

        /// Whether the merge fast-forwarded: true when no merge commit was
        /// created (the branch simply moved to the target).
        public let fastForwarded: Bool

        public init(head: String, fastForwarded: Bool) {
            self.head = head
            self.fastForwarded = fastForwarded
        }

        /// The stable wire keys, identical to the stored-member names on
        /// purpose; no raw values — the member name IS the wire key.
        private enum CodingKeys: String, CodingKey {
            case head, fastForwarded
        }
    }

    /// Merges `branch` into the current branch, stating the intent
    /// explicitly.
    ///
    /// - Parameters:
    ///   - message: The merge commit's message, passed as `-m` —
    ///     `GIT_EDITOR` is never invoked. `nil` keeps git's own default
    ///     wording (`Merge branch 'feature'` and its remote-tracking and
    ///     bare-commit forms, measured, git 2.50.1), reached through
    ///     `--no-edit` rather than any editor. Ignored by a fast-forward,
    ///     which creates no commit.
    ///   - signing: The #0060 three-valued intent. `.config` lets
    ///     `commit.gpgsign` decide, exactly as every porcelain commit path
    ///     here does; `.sign`/`.noSign` spell the flag on the merge.
    ///   - allowUnrelated: Permits merging histories that share no common
    ///     ancestor (`--allow-unrelated-histories`). Refused unless stated —
    ///     an unrelated merge is almost always the wrong branch name.
    /// - Throws: `MergeError.unknownBranch` when `branch` does not resolve
    ///   to a commit; `.blockedOnConflicts` when the index already holds
    ///   unmerged entries (refused before anything is touched) or the merge
    ///   itself conflicted (left in progress, resumable, `MERGE_HEAD`
    ///   present); `.alreadyUpToDate` when the target is already reachable
    ///   from HEAD; `.unrelatedHistories` when the histories share no merge
    ///   base and `allowUnrelated` was not stated; `.signingFailed` when a
    ///   signature was attempted and could not be produced (the merge is
    ///   aborted first); `GitProcess.Failure` for every other non-zero exit.
    public static func run(
        branch: String,
        intent: Intent,
        message: String? = nil,
        signing: CommitCreate.Signing = .config,
        allowUnrelated: Bool = false,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Result {
        let plan = try walk(
            branch: branch, allowUnrelated: allowUnrelated,
            at: path, git: git, extraEnvironment: extraEnvironment)
        return try JournalCheckpoint.around(operation: "merge", at: path, git: git) { scoped in
            try perform(
                plan, intent: intent, message: message, signing: signing,
                at: path, git: scoped, extraEnvironment: extraEnvironment)
        }
    }
}

// MARK: - The walk

private extension Merge {

    /// Everything the merge needs, resolved before the checkpoint so the
    /// body only mutates.
    struct Plan {
        let branch: String
        let target: String
        /// Whether `MERGE_HEAD` already existed when the walk ran — a merge
        /// git refuses to start. Only a merge this run started may ever be
        /// aborted; a foreign one belongs to the resolve UI (#0057).
        let mergeWasAlreadyInProgress: Bool
        let allowUnrelated: Bool
    }

    /// Resolves the request into a `Plan`, raising every typed refusal
    /// before anything is touched. Reads only — no object is written here.
    static func walk(
        branch: String,
        allowUnrelated: Bool,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Plan {
        let target = try resolveBranch(branch, at: path, git: git,
                                       extraEnvironment: extraEnvironment)
        try refuseUnmergedIndex(at: path, git: git, extraEnvironment: extraEnvironment)
        let headTip = try git.run(
            ["rev-parse", "--verify", "HEAD"],
            workingDirectory: path, extraEnvironment: extraEnvironment
        ).lines.first ?? ""
        // Already up to date: the target is reachable from HEAD, itself
        // included — `--is-ancestor` answers for both, and no merge of any
        // intent would create anything.
        let ancestor = try git.capture(
            ["merge-base", "--is-ancestor", target, headTip],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        guard ancestor.exitCode != 0 else {
            throw MergeError.alreadyUpToDate(branch: branch)
        }
        // Unrelated histories: no merge base at all. Refused unless stated,
        // before anything is written — git's own refusal for this arrives
        // only mid-merge, far too late to be a typed pre-mutation answer.
        let base = try git.capture(
            ["merge-base", headTip, target],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        guard base.exitCode == 0 || allowUnrelated else {
            throw MergeError.unrelatedHistories(branch: branch)
        }
        return Plan(
            branch: branch, target: target,
            mergeWasAlreadyInProgress: try mergeHeadPresent(
                at: path, git: git, extraEnvironment: extraEnvironment),
            allowUnrelated: allowUnrelated)
    }

    /// Resolves the branch to a commit, typing a failure to refuse before
    /// anything is touched.
    static func resolveBranch(
        _ branch: String,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> String {
        let output = try git.capture(
            ["rev-parse", "--verify", "--quiet", "\(branch)^{commit}"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        guard output.exitCode == 0, let oid = output.lines.first, !oid.isEmpty else {
            throw MergeError.unknownBranch(branch)
        }
        return oid
    }

    /// Refuse an unmerged index before anything is touched — the resolve UI
    /// (#0057) owns a live conflict; a merge would refuse on its own halfway
    /// through, after writing objects. The same guard Rewrite refuses under,
    /// in the same place in the sequence.
    static func refuseUnmergedIndex(
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws {
        let conflicts = try conflictedFiles(at: path, git: git)
        guard conflicts.isEmpty else {
            throw MergeError.blockedOnConflicts(files: conflicts)
        }
    }

    /// Whether `MERGE_HEAD` exists — asked through git rather than assuming
    /// `.git/`, the same rule every other in-progress probe here follows.
    static func mergeHeadPresent(
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Bool {
        let output = try git.run(
            ["rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD"],
            workingDirectory: path, extraEnvironment: extraEnvironment
        )
        guard let mergeHead = output.lines.first, !mergeHead.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: mergeHead)
    }
}

// MARK: - Execution

private extension Merge {

    /// Runs the one porcelain merge. Assumes every guard passed and the
    /// checkpoint is already written.
    static func perform(
        _ plan: Plan,
        intent: Intent,
        message: String?,
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Result {
        var arguments = ["merge"]
        switch intent {
        case .fastForwardOnly: arguments += ["--ff-only"]
        case .noFastForward: arguments += ["--no-ff"]
        }
        // The explicit-flag rule (#0060): the resolved intent spelled on the
        // porcelain command, never a config reliance this call cannot see.
        // `.config` passes nothing, so `commit.gpgsign` decides — the same
        // forward shape Split gives its cherry-pick replay.
        arguments += CommitCreate.arguments(for: signing)
        // `--no-edit` is what keeps the default message non-interactive when
        // no `-m` rides along; with `-m` it is redundant but harmless. Either
        // way `GIT_EDITOR` is pinned `false` by `GitProcess` and would fail
        // the merge rather than open an editor.
        arguments += ["--no-edit"]
        if let message { arguments += ["-m", message] }
        if plan.allowUnrelated { arguments += ["--allow-unrelated-histories"] }
        arguments += [plan.branch]

        // Bounded only when a signature will actually be attempted (#0163) —
        // a merge commit's signing helper can hang exactly like `git commit`'s.
        let inEffect = try CommitCreate.signingInEffect(
            signing, in: path, git: git, extraEnvironment: extraEnvironment)
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
                // A timed-out merge can never be resumed from mid-hang: the
                // signing helper's UI is ungovernable, so abort and type.
                abortIfWeStarted(plan, at: path, git: git, extraEnvironment: extraEnvironment)
                if case let CommitCreate.Failure.signingFailed(reason) =
                    CommitCreate.classifyTimeout(failure, signingInEffect: inEffect) {
                    throw MergeError.signingFailed(reason: reason)
                }
                throw failure
            }
            throw failure
        }
        guard output.exitCode == 0 else {
            // Classified by the index, not the message — the same rule
            // Rewrite's replay classifier uses: non-empty conflicts stay
            // exactly as git left them (MERGE_HEAD present, unmerged index,
            // the resumable state the resolve UI completes); a signing
            // failure is never resumable, so it is aborted first; anything
            // else (git's own refusals — not a fast-forward, a hook
            // declining the merge commit) surfaces as git produced it.
            let conflicts = try conflictedFiles(at: path, git: git)
            guard conflicts.isEmpty else {
                throw MergeError.blockedOnConflicts(files: conflicts)
            }
            if let failure = CommitCreate.classify(
                stderr: output.standardError, signingInEffect: inEffect) {
                abortIfWeStarted(plan, at: path, git: git, extraEnvironment: extraEnvironment)
                if case let .signingFailed(reason) = failure {
                    throw MergeError.signingFailed(reason: reason)
                }
                throw failure
            }
            throw GitProcess.Failure.exited(
                code: output.exitCode,
                stderr: output.standardError,
                arguments: arguments
            )
        }
        let head = try git.run(
            ["rev-parse", "HEAD"], workingDirectory: path, extraEnvironment: extraEnvironment
        ).lines.first ?? ""
        // A fast-forward's head is exactly the target commit; a merge commit
        // is a fresh object. Parent-counting would misread a fast-forward to
        // a target that is itself a merge.
        return Result(head: head, fastForwarded: head == plan.target)
    }

    /// Aborts the merge — but only one this run started. A `MERGE_HEAD` that
    /// predated the call is the resolve UI's live operation (#0057); git
    /// refuses to start a second merge over it, so a failure here cannot be
    /// ours to clean up, and `--abort` would destroy someone else's state.
    static func abortIfWeStarted(
        _ plan: Plan,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) {
        guard !plan.mergeWasAlreadyInProgress else { return }
        _ = try? git.run(
            ["merge", "--abort"], workingDirectory: path,
            extraEnvironment: extraEnvironment)
    }
}

// MARK: - Errors

/// Why `Merge.run` refused, or could not finish.
public enum MergeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The named branch does not resolve to a commit. Raised before anything
    /// is touched.
    case unknownBranch(String)
    /// The target is already reachable from HEAD — itself included — so no
    /// merge of any intent would create anything. Raised before anything is
    /// touched.
    case alreadyUpToDate(branch: String)
    /// The two histories share no common ancestor and `allowUnrelated` was
    /// not stated. Raised before anything is touched.
    case unrelatedHistories(branch: String)
    /// Either the index already held unmerged entries (refused before
    /// anything was touched), or the merge itself conflicted — in the merge
    /// case `MERGE_HEAD` is present and the state is resumable, and `files`
    /// names the conflicted paths.
    case blockedOnConflicts(files: [ConflictedFile])
    /// A signature was attempted and could not be produced. The merge is
    /// aborted before this is raised — a signing failure is never resumable.
    case signingFailed(reason: String)

    public var description: String {
        switch self {
        case let .unknownBranch(branch):
            "unknown branch '\(branch)' — it does not resolve in this repository; nothing was touched"
        case let .alreadyUpToDate(branch):
            "nothing to merge — '\(branch)' is already reachable from HEAD; nothing was touched"
        case let .unrelatedHistories(branch):
            "refusing to merge unrelated histories: '\(branch)' and HEAD share no common "
                + "ancestor — pass --allow-unrelated to state the intent; nothing was touched"
        case let .blockedOnConflicts(files):
            "merge blocked on conflicts in "
                + files.map(\.path).joined(separator: ", ")
        case let .signingFailed(reason):
            "signing failed: \(reason)"
        }
    }
}

// MARK: - §6 exit class

extension MergeError: ExitClassCarrying {
    public var exitClass: ExitClass {
        switch self {
        case .unknownBranch, .alreadyUpToDate, .unrelatedHistories:
            .repositoryError
        case .blockedOnConflicts: .blockedOnConflicts
        case .signingFailed: .signingFailed
        }
    }
}
