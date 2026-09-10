// Split.swift — split one commit into two along a hunk boundary (#0062)

import Foundation

/// Splits one commit into two, non-interactively, along a hunk boundary named
/// by #0016's stable hunk id — the operation `git rebase -i`'s `edit` makes
/// agents fail at, because it wants an editor and a shell.
///
/// The mechanism is #0060's decision — a `commit-tree` walk, no rebase engine
/// — applied to one commit `C`:
///
/// 1. **Locate** — `commitDiff(C)` (the `diff-tree --root -p --cc` path that
///    handles root and merge shapes) is parsed into hunks, and the caller
///    names one by its stable content-derived id. An unknown id is a typed
///    refusal raised before anything is touched, as is a commit that
///    introduces fewer than two hunks (there is no boundary to split at).
/// 2. **First half** — the index is reset to `C^`'s tree (`read-tree --empty`
///    for a root commit: the index must simply be empty, and `write-tree`
///    materializes the first half's tree from there, so `commit-tree` is
///    never handed a tree object that does not exist), only the chosen
///    hunk's patch is applied to the index through the one `git apply
///    --cached` path everything shares, and `git write-tree` +
///    `git commit-tree` create commit `A` with parent `C^`. Message
///    `first` (default: `C`'s original), passed on stdin — no editor is ever
///    involved.
/// 3. **Second half** — the remaining hunks are applied on top, `write-tree`
///    + `commit-tree` create `B` with parent `A`, message `second` (default:
///    `C`'s original). **`B`'s tree must equal `C`'s tree** — the issue's
///    criterion, checked before any ref moves; a mismatch is a typed error
///    and leaves every ref untouched.
/// 4. **Move the ref once** — descendants of `C` on the caller's branch (the
///    ref `HEAD` names, or `HEAD` itself when detached) are replayed with
///    `git cherry-pick` onto `B`, then the ref moves once via
///    `update-ref --stdin` with the old value pinned — until it moves, any
///    failure leaves history untouched. A conflicted pick is left in
///    progress, resumable (`blockedOnConflicts`); every other replay failure
///    is aborted before being surfaced.
/// 5. **Signing** — the #0060 rule: the explicit flag for the resolved
///    intent, never config reliance. `commit-tree` is plumbing and ignores
///    `commit.gpgsign` (measured, git 2.50.1: a repository with
///    `commit.gpgsign=true` commits unsigned through `commit-tree` with no
///    flag), so the intent is spelled out on every half; the replay is
///    porcelain and gets `CommitCreate.arguments(for:)` exactly as absorb
///    forwards them.
///
/// The whole rewrite runs inside one `JournalCheckpoint.around(operation:
/// "split")`, so `yard undo` reverses it as a single step. The guards and
/// all reads run before the checkpoint: a refusal — unknown id, nothing to
/// do, an unmerged index, a commit off the caller's branch — touches
/// nothing and writes no journal entry.
///
/// The index is the scratch space for building the halves and is restored
/// to the caller's exact bytes before any replay and on every pre-replay
/// failure. The worktree is never written by the split itself; only the
/// replay's `checkout --detach` moves it, and a conflicted pick leaves it
/// in the resumable mid-pick state.
public struct Split: Equatable, Sendable {

    /// What a completed split produced: the two new commits, parented
    /// `C^ → first → second`, where `second`'s tree equals `C`'s tree.
    public struct Result: Sendable, Equatable, Encodable {

        /// The first half's full oid — parent `C^` (none for a root commit),
        /// carrying only the chosen hunk's change over the split base.
        public let first: String

        /// The second half's full oid — parent `first`, tree equal to `C`'s.
        public let second: String

        public init(first: String, second: String) {
            self.first = first
            self.second = second
        }

        /// The stable wire keys, identical to the stored-member names on
        /// purpose; no raw values — the case name IS the wire key.
        private enum CodingKeys: String, CodingKey {
            case first, second
        }
    }

    /// Executes the split.
    ///
    /// - Parameters:
    ///   - commit: the commit to split, any revision syntax `rev-parse`
    ///     accepts (typically an oid or `HEAD`).
    ///   - hunkID: the stable id (#0016) of the hunk that becomes the first
    ///     half. Resolved against a fresh `commitDiff` of `commit`.
    ///   - firstMessage: the first half's message; `nil` keeps `C`'s original.
    ///   - secondMessage: the second half's message; `nil` keeps `C`'s
    ///     original.
    ///   - signing: forwarded to both halves and the replay — see the type
    ///     doc comment for the explicit-flag rule.
    ///   - extraEnvironment: merged over the process environment for every
    ///     invocation. Tests use it to neutralize global and system config
    ///     scope; production callers leave it empty.
    /// - Throws: `SplitError.unknownHunkID` when `hunkID` matches nothing in
    ///   the fresh listing; `.nothingToDo` when the commit introduces fewer
    ///   than two hunks; `.commitNotOnRef` when `commit` is not on the ref
    ///   `HEAD` names; `.blockedOnConflicts` when the index already holds
    ///   unmerged entries (refused before anything is touched) or the
    ///   descendant replay conflicted (the pick is left in progress,
    ///   resumable); `.signingFailed` when a signature was attempted and
    ///   could not be produced; `.treeMismatch` if the rebuilt second half's
    ///   tree somehow differed from `C`'s (the criterion — the ref is never
    ///   moved in that case); `GitProcess.Failure` for every other non-zero
    ///   exit.
    public static func run(
        commit: String,
        hunkID: String,
        first firstMessage: String? = nil,
        second secondMessage: String? = nil,
        signing: CommitCreate.Signing = .config,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Result {
        // 1. Resolve the commit to an oid once, so every later spelling of
        //    it (`C^`, `C^{tree}`, the ref-move bounds) is the same object.
        let commitOid = try git.run(
            ["rev-parse", "--verify", "\(commit)^{commit}"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        ).lines.first ?? ""

        // 2. Refuse an unmerged index before anything is touched — a staged
        //    conflict resolution is work the index scratch below would
        //    reset away, the same contract absorb refuses under, and the
        //    same place in the sequence absorb checks it (before any diff
        //    is classified).
        let conflicts = try conflictedFiles(at: path, git: git)
        guard conflicts.isEmpty else {
            throw SplitError.blockedOnConflicts(files: conflicts)
        }

        // 3. The ref that moves once: the branch `HEAD` names, or `HEAD`
        //    itself when detached. `C` must sit on its history — the
        //    descendants are read as `C..<ref>`, and moving a ref `C` is
        //    not on would orphan the caller's line. Checked before the
        //    hunk lookup, so a commit from another line of history is
        //    refused for the reason that actually applies.
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
        let ancestorProbe = try git.capture(
            ["merge-base", "--is-ancestor", commitOid, tip],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        guard ancestorProbe.exitCode == 0 else {
            throw SplitError.commitNotOnRef(commit: commitOid, ref: refName)
        }

        // 4. The diff the commit introduced, parsed into hunks with their
        //    stable ids (#0016). A clean merge or an `--allow-empty` commit
        //    diffs empty — there is nothing to split.
        let files = try commitDiff(at: path, revision: commitOid, git: git)
        let hunks = files.flatMap(\.hunks)
        if hunks.isEmpty {
            throw SplitError.nothingToDo
        }
        guard let chosen = hunks.first(where: { $0.id == hunkID }) else {
            throw SplitError.unknownHunkID(id: hunkID)
        }
        guard hunks.count >= 2 else {
            throw SplitError.nothingToDo
        }

        // 5. The split base: `C^`, or nothing for a root commit (the empty
        //    tree). The quiet probe is the same shape absorb's rebase base
        //    uses; a merge commit never reaches it, because its `--cc` diff
        //    either is empty (`.nothingToDo`) or refuses in `selectPatch`.
        let parentProbe = try git.capture(
            ["rev-parse", "--verify", "--quiet", "\(commitOid)^"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        let isRoot = parentProbe.exitCode != 0
        let parentOid = isRoot ? "" : (parentProbe.lines.first ?? "")

        // 6. Descendants to replay, oldest first, resolved before the
        //    checkpoint so the body only mutates. Measured: `rev-list
        //    --reverse` always lists a linear chain parents-first; siblings
        //    (a side branch merged in) ride a date tie-break, and either
        //    order replays correctly or conflicts, both handled below.
        let descendants = try git.run(
            ["rev-list", "--reverse", "\(commitOid)..\(tip)"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        ).lines

        // 7. `C`'s original message — the default for both halves, read raw
        //    (`%B`) so a multi-paragraph message round-trips through stdin.
        let originalMessage = try git.run(
            ["log", "-n", "1", "--format=%B", commitOid],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        ).text

        // 8. The expected final tree — the issue's criterion, resolved
        //    before the checkpoint so the body compares against a value
        //    nothing in the body could have influenced.
        let expectedTree = try git.run(
            ["rev-parse", "\(commitOid)^{tree}"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        ).lines.first ?? ""

        // 9. Everything past this point is one checkpoint for the whole
        //    rewrite — both halves, the replay, and the ref move.
        return try JournalCheckpoint.around(operation: "split", at: path, git: git) { scoped in
            try perform(
                commitOid: commitOid,
                chosen: chosen,
                files: files,
                hunks: hunks,
                isRoot: isRoot,
                parentOid: parentOid,
                refName: refName,
                attached: attached,
                tip: tip,
                descendants: descendants,
                originalMessage: originalMessage,
                expectedTree: expectedTree,
                firstMessage: firstMessage,
                secondMessage: secondMessage,
                signing: signing,
                at: path,
                git: scoped,
                extraEnvironment: extraEnvironment
            )
        }
    }
}

// MARK: - Execution

extension Split {

    /// Builds the two halves, replays any descendants, and moves the ref
    /// once. Assumes every guard passed and the checkpoint is already
    /// written.
    private static func perform(
        commitOid: String,
        chosen: Hunk,
        files: [FileDiff],
        hunks: [Hunk],
        isRoot: Bool,
        parentOid: String,
        refName: String,
        attached: Bool,
        tip: String,
        descendants: [String],
        originalMessage: String,
        expectedTree: String,
        firstMessage: String?,
        secondMessage: String?,
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

        // --- Phase 1: build both halves on the index as scratch. ---
        let firstOid: String
        let secondOid: String
        do {
            // The split base: `C^`'s tree, or an empty index for a root
            // commit. `read-tree --empty` needs no tree object at all, and
            // `write-tree` below materializes whatever the chosen hunk
            // produces — so `commit-tree` is never handed a tree that does
            // not exist (the empty-tree question the planning pass asked
            // about never arises).
            if isRoot {
                try git.run(
                    ["read-tree", "--empty"],
                    workingDirectory: path, extraEnvironment: extraEnvironment)
            } else {
                let baseTree = try git.run(
                    ["rev-parse", "\(parentOid)^{tree}"],
                    workingDirectory: path, extraEnvironment: extraEnvironment
                ).lines.first ?? ""
                try git.run(
                    ["read-tree", baseTree],
                    workingDirectory: path, extraEnvironment: extraEnvironment)
            }

            // First half: only the chosen hunk, through the one apply path
            // everything shares. The index equals the split base, so the
            // hunk's patch (built with `commitDiff`'s pinned flags) applies
            // byte-for-byte.
            let firstPatch = try selectPatch(ids: [chosen.id], from: files, area: .staged)
            try applyPatchToIndex(firstPatch, at: path, git: git)
            let firstTree = try git.run(
                ["write-tree"], workingDirectory: path, extraEnvironment: extraEnvironment
            ).lines.first ?? ""

            // Second half: the remaining hunks, in file order, applied on
            // top. They came from one diff of the split base, so applying
            // them over the first half reconstructs `C`'s tree exactly —
            // asserted next, before any commit object exists.
            let remainingIDs = hunks.filter { $0.id != chosen.id }.map(\.id)
            let secondPatch = try selectPatch(ids: remainingIDs, from: files, area: .staged)
            try applyPatchToIndex(secondPatch, at: path, git: git)
            let secondTree = try git.run(
                ["write-tree"], workingDirectory: path, extraEnvironment: extraEnvironment
            ).lines.first ?? ""

            // The criterion: the pair must rebuild the original tree. A
            // mismatch means the hunk decomposition did not reconstruct the
            // commit — nothing has been created or moved yet, and the typed
            // error says so.
            guard secondTree == expectedTree else {
                throw SplitError.treeMismatch(expected: expectedTree, actual: secondTree)
            }

            // Create the halves. Plumbing: no hooks, no editor — the message
            // rides stdin, and signing is the explicit flag for the resolved
            // intent (#0060), since `commit-tree` ignores `commit.gpgsign`.
            let inEffect = try CommitCreate.signingInEffect(
                signing, in: path, git: git, extraEnvironment: extraEnvironment)
            var firstArguments = ["commit-tree", firstTree]
            if !isRoot { firstArguments += ["-p", parentOid] }
            firstArguments += commitTreeArguments(signingInEffect: inEffect)
            firstOid = try commitTree(
                firstArguments,
                message: firstMessage ?? originalMessage,
                at: path, git: git, extraEnvironment: extraEnvironment)

            let secondArguments = ["commit-tree", secondTree, "-p", firstOid]
                + commitTreeArguments(signingInEffect: inEffect)
            secondOid = try commitTree(
                secondArguments,
                message: secondMessage ?? originalMessage,
                at: path, git: git, extraEnvironment: extraEnvironment)
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

        // --- Phase 2: replay descendants, then move the ref once.
        if descendants.isEmpty {
            // `C` was the tip: the ref moves straight to the second half,
            // and an attached `HEAD` follows it symbolically.
            try moveRef(refName: refName, from: tip, to: secondOid,
                        at: path, git: git, extraEnvironment: extraEnvironment)
            return Result(first: firstOid, second: secondOid)
        }

        try git.run(
            ["checkout", "-q", "--detach", secondOid],
            workingDirectory: path, extraEnvironment: extraEnvironment)
        do {
            let pickArguments = ["cherry-pick"]
                + CommitCreate.arguments(for: signing)
                + descendants
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
            try moveRef(refName: refName, from: tip, to: replayedTip,
                        at: path, git: git, extraEnvironment: extraEnvironment)
            if attached {
                try git.run(
                    ["symbolic-ref", "HEAD", refName],
                    workingDirectory: path, extraEnvironment: extraEnvironment)
            }
            return Result(first: firstOid, second: secondOid)
        } catch {
            // A conflicted pick stays exactly as the pick left it — HEAD
            // detached on the second half, the pick in progress, the branch
            // unmoved — that is the resumable state the contract promises.
            // Every other failure is cleaned up first: a signing failure can
            // never be resumed, and git's own refusal leaves no pick worth
            // resuming.
            if case SplitError.blockedOnConflicts = error { throw error }
            _ = try? git.run(
                ["cherry-pick", "--abort"], workingDirectory: path,
                extraEnvironment: extraEnvironment)
            try? indexSnapshot.restore(in: context, git: git)
            if attached {
                _ = try? git.run(
                    ["symbolic-ref", "HEAD", refName], workingDirectory: path,
                    extraEnvironment: extraEnvironment)
            }
            throw error
        }
    }

    /// The flag the #0060 rule contributes to a `git commit-tree` invocation:
    /// the explicit flag for the resolved intent, never config. Measured,
    /// git 2.50.1: `commit-tree` is plumbing and ignores `commit.gpgsign`
    /// (a repository with it set to `true` commits unsigned through
    /// `commit-tree` with no flag), so an intent that is in effect must be
    /// spelled out, and an intent that is not must be pinned off — both
    /// halves of the pair then always agree.
    static func commitTreeArguments(signingInEffect: Bool) -> [String] {
        signingInEffect ? ["--gpg-sign"] : ["--no-gpg-sign"]
    }

    /// Moves `refName` once, old value pinned, via `update-ref --stdin` —
    /// the single commit point of the whole rewrite. If the ref moved
    /// underneath the run, the old value no longer matches and git rejects
    /// the whole transaction, leaving the ref (and history) untouched.
    private static func moveRef(
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
    private static func commitTree(
        _ arguments: [String],
        message: String,
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
            if let failure = CommitCreate.classify(stderr: output.standardError, signingInEffect: true) {
                switch failure {
                case let .signingFailed(reason):
                    throw SplitError.signingFailed(reason: reason)
                }
            }
            throw GitProcess.Failure.exited(
                code: output.exitCode,
                stderr: output.standardError,
                arguments: arguments
            )
        }
        return oid
    }

    /// Classifies a failed `git cherry-pick` replay, by the index and not
    /// the message, the same shape absorb's rebase classifier uses:
    /// non-empty conflicts stay resumable (`.blockedOnConflicts`, nothing
    /// aborted); a signing failure aborts the pick first (it can never
    /// sign, so it is not resumable); anything else aborts and surfaces
    /// git's own failure.
    private static func classifiedPickFailure(
        output: GitProcess.Output,
        arguments: [String],
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Error {
        let conflicts = try conflictedFiles(at: path, git: git)
        guard conflicts.isEmpty else {
            return SplitError.blockedOnConflicts(files: conflicts)
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
                return SplitError.signingFailed(reason: reason)
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
    private static func classifyPickTimeout(
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
        return SplitError.signingFailed(
            reason: "the descendant replay did not finish within \(after) and was terminated -- "
                + "likely a signing prompt with no way to answer it")
    }
}

// MARK: - Errors

/// Why `Split.run` refused, or could not finish.
public enum SplitError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The named hunk id appears in no fresh listing of the commit's diff —
    /// stale (the hunk changed since it was listed) or never valid. Raised
    /// before anything is touched.
    case unknownHunkID(id: String)
    /// The commit introduces fewer than two hunks (or none — an
    /// `--allow-empty` commit or a clean merge), so there is no hunk
    /// boundary to split at.
    case nothingToDo
    /// The commit to split is not on the ref `HEAD` names, so there are no
    /// well-defined descendants and no ref this operation could move.
    case commitNotOnRef(commit: String, ref: String)
    /// Either the index already held unmerged entries (refused before
    /// anything was touched), or the descendant replay conflicted — in the
    /// replay case the pick is left in progress, resumable, and `files`
    /// names the conflicted paths.
    case blockedOnConflicts(files: [ConflictedFile])
    /// A signature was attempted and could not be produced.
    case signingFailed(reason: String)
    /// The criterion failed: the rebuilt second half's tree does not equal
    /// the original commit's tree. The ref was not moved; this is a defect
    /// in the hunk decomposition, never a state to push through.
    case treeMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case let .unknownHunkID(id):
            "unknown hunk id '\(id)' — stale (the hunk changed since it was listed) "
                + "or never valid; nothing was touched"
        case .nothingToDo:
            "nothing to split — the commit introduces fewer than two hunks, "
                + "so there is no hunk boundary to split at"
        case let .commitNotOnRef(commit, ref):
            "the commit to split (\(commit)) is not on \(ref) — "
                + "check out the branch that contains it first"
        case let .blockedOnConflicts(files):
            "split blocked on conflicts in "
                + files.map(\.path).joined(separator: ", ")
        case let .signingFailed(reason):
            "signing failed: \(reason)"
        case let .treeMismatch(expected, actual):
            "the rebuilt second half's tree (\(actual)) does not match the original "
                + "commit's tree (\(expected)) — the ref was not moved"
        }
    }
}

// MARK: - §6 exit class

extension SplitError: ExitClassCarrying {
    public var exitClass: ExitClass {
        switch self {
        case .unknownHunkID, .nothingToDo, .commitNotOnRef, .treeMismatch: .repositoryError
        case .blockedOnConflicts: .blockedOnConflicts
        case .signingFailed: .signingFailed
        }
    }
}
