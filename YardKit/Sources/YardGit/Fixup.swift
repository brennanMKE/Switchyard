// Fixup.swift — squash the staged index into a target commit and autosquash (#0039)

import Foundation

/// Squashes the **staged index** into `target` and autosquashes in one step —
/// the engine behind `yard fixup`, and GitUp's flagship operation.
///
/// Scope is deliberately the staged-index case only. Squashing an *existing*
/// commit into an older one is a different mechanism (rewriting that commit's
/// own message to `fixup!` first) and is #0214.
///
/// The sequence: `git commit --fixup=<target>`, then `git rebase --autosquash`
/// from just below `target`, all inside one `JournalCheckpoint.around` so
/// `yard undo` reverses the whole pair as a single step (#0212's trap).
public struct Fixup: Equatable, Sendable {

    /// Oid of `HEAD` after the autosquash rebase.
    public let head: String

    public init(head: String) {
        self.head = head
    }

    /// Runs the fixup, returning the new `HEAD` on success.
    ///
    /// - Parameter target: the commit the staged index is squashed into. Must
    ///   be an ancestor of `HEAD`.
    /// - Parameter signing: forwarded to both the fixup commit and the
    ///   rebase, so a caller who asks for `.sign` or `.noSign` gets it on
    ///   every rewritten commit; `.config` (the default) lets
    ///   `commit.gpgsign` decide and passes no flag either place — measured
    ///   to keep existing signatures when the repository signs by config,
    ///   and to drop them when it does not (a repo that signs only via a
    ///   hand-passed `-S` is not "configured to sign").
    /// - Throws: `FixupError.targetNotAncestor` when `target` is not an
    ///   ancestor of `HEAD`; `.nothingStaged` when the index has nothing to
    ///   fix up; `.blockedOnConflicts` when the rebase cannot apply cleanly,
    ///   leaving the rebase in progress for the caller to resolve and
    ///   continue; `.signingFailed` when a signature was attempted and could
    ///   not be produced, leaving no rebase in progress.
    public static func run(
        target: String,
        signing: CommitCreate.Signing = .config,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Fixup {
        // 1. Refuse a non-ancestor target. Measured: `merge-base
        //    --is-ancestor` exits 0 for an ancestor, non-zero otherwise —
        //    read with `capture`, never `run`, since a non-zero exit here is
        //    information, not a launch failure.
        let ancestorCheck = try git.capture(
            ["merge-base", "--is-ancestor", target, "HEAD"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        guard ancestorCheck.exitCode == 0 else {
            throw FixupError.targetNotAncestor(target: target)
        }

        // 2. Refuse an empty index. `git commit --fixup=<target>` with
        //    nothing staged prints "nothing to commit" and creates no
        //    commit — without this guard the call would silently no-op.
        let staged = try git.run(
            ["diff", "--cached", "--name-only"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        ).lines
        guard !staged.isEmpty else {
            throw FixupError.nothingStaged
        }

        // 3. Everything past this point is one checkpoint for the pair.
        return try JournalCheckpoint.around(operation: "fixup", at: path, git: git) { git in
            try performFixup(
                target: target,
                signing: signing,
                at: path,
                git: git,
                extraEnvironment: extraEnvironment
            )
        }
    }

    /// Runs the git invocation that creates the `fixup!` commit for the
    /// staged-index mode, then hands off to the shared rebase step. Assumes
    /// the ancestor and staged-index guards already passed and the
    /// checkpoint is already written.
    private static func performFixup(
        target: String,
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Fixup {
        // 4. `git commit --fixup=<target>`. Git derives the message
        //    ("fixup! <target's subject>") and lands the commit on top of
        //    `HEAD`, not next to `target` — nothing here needs to read
        //    target's own message.
        let commitArguments = ["commit", "--fixup=\(target)"] + CommitCreate.arguments(for: signing)
        let commitOutput = try git.capture(
            commitArguments,
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        guard commitOutput.exitCode == 0 else {
            throw try classifiedCommitFailure(
                output: commitOutput,
                arguments: commitArguments,
                signing: signing,
                at: path,
                git: git,
                extraEnvironment: extraEnvironment
            )
        }

        return try autosquashRebase(
            target: target, signing: signing, at: path, git: git, extraEnvironment: extraEnvironment)
    }

    /// The rebase step shared by both fixup modes (#0039's staged-index mode
    /// and #0214's existing-commit mode): both have, by this point, already
    /// landed a `fixup!`-labelled commit at `HEAD` by one mechanism or
    /// another, and this runs the same `git rebase --autosquash` and the
    /// same conflict-versus-signing classification of a non-zero exit for
    /// either.
    private static func autosquashRebase(
        target: String,
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Fixup {
        // 5. `git rebase --autosquash <base>`, non-interactively (measured:
        //    no `-i`, no sequence editor needed on git 2.50.1). `<base>` is
        //    `target^`, except when `target` is the root commit, where that
        //    revision does not resolve and `--root` is used instead —
        //    detected with a quiet `rev-parse --verify` probe.
        let parentProbe = try git.capture(
            ["rev-parse", "--verify", "--quiet", "\(target)^"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        let rebaseArguments: [String]
        if parentProbe.exitCode == 0 {
            rebaseArguments = ["rebase", "--autosquash", "\(target)^"]
                + CommitCreate.arguments(for: signing)
        } else {
            rebaseArguments = ["rebase", "--autosquash", "--root"]
                + CommitCreate.arguments(for: signing)
        }
        // Bounded only when a signature will actually be attempted (#0163),
        // computed once up front rather than gated on the `signing`
        // parameter alone -- `.config` is the default here too, and most
        // `Fixup` callers never override it, so gating on the raw parameter
        // (as an earlier revision did) applies the bounded wait to nearly
        // every rebase in the package, not just the rare signing-active
        // ones. `.noSign` decides `false` and `.sign` decides `true`
        // without a git call; `.config` costs one cheap, synchronous,
        // un-timed `git config` read. A rebase also replays every commit
        // between `target` and `HEAD`, so it can legitimately run far
        // longer than a single `git commit` for reasons that have nothing
        // to do with signing -- `signingTimeout` is a guess about human
        // patience, not a rebase-size budget, and a caller signing many
        // commits in one rebase accepts that tradeoff.
        let inEffect = try CommitCreate.signingInEffect(
            signing, in: path, git: git, extraEnvironment: extraEnvironment)
        let rebaseOutput: GitProcess.Output
        do {
            rebaseOutput = try git.capture(
                rebaseArguments,
                workingDirectory: path,
                extraEnvironment: extraEnvironment,
                timeout: inEffect ? GitProcess.signingTimeout : nil
            )
        } catch let failure as GitProcess.Failure {
            if case .timedOut = failure {
                // The rebase can never be resumed from mid-hang, so it is
                // aborted unconditionally, exactly as `classifiedRebaseFailure`'s
                // non-conflict paths do -- there is no index state here that a
                // caller could usefully continue. Nothing to clean up on the
                // in-flight file (#0253): `around`'s catch, which is the only
                // writer, has not run yet at this point -- it only writes
                // after `body` throws, and only when the sequencer is still
                // live then. The abort just above already ends this rebase,
                // so `around` finds no live sequencer and writes nothing for
                // this operation to begin with.
                _ = try? git.run(
                    ["rebase", "--abort"], workingDirectory: path, extraEnvironment: extraEnvironment)
                throw classifyTimeout(failure, signingInEffect: inEffect)
            }
            throw failure
        }
        guard rebaseOutput.exitCode == 0 else {
            throw try classifiedRebaseFailure(
                output: rebaseOutput,
                arguments: rebaseArguments,
                signing: signing,
                at: path,
                git: git,
                extraEnvironment: extraEnvironment
            )
        }

        // 6. Success — the rewritten HEAD.
        let head = try git.run(
            ["rev-parse", "HEAD"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        return Fixup(head: head.lines.first ?? "")
    }

    /// Classifies a failed `git commit --fixup=…`. No rebase has started at
    /// this point, so there is nothing to abort — only a signing failure or
    /// a plain repository error to distinguish.
    private static func classifiedCommitFailure(
        output: GitProcess.Output,
        arguments: [String],
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Error {
        let inEffect = try CommitCreate.signingInEffect(
            signing, in: path, git: git, extraEnvironment: extraEnvironment)
        if let failure = CommitCreate.classify(
            stderr: output.standardError, signingInEffect: inEffect) {
            switch failure {
            case let .signingFailed(reason):
                return FixupError.signingFailed(reason: reason)
            }
        }
        return GitProcess.Failure.exited(
            code: output.exitCode, stderr: output.standardError, arguments: arguments)
    }

    /// Classifies a failed `git rebase --autosquash …`.
    ///
    /// 7. Classify by the index, not the message:
    ///    - non-empty conflicts → `.blockedOnConflicts`, and the rebase is
    ///      left in progress (resumable) — do not abort.
    ///    - empty conflicts, stderr matches a signing failure → abort the
    ///      rebase first (it can never sign, so it is not resumable), then
    ///      `.signingFailed`.
    ///    - neither → abort the rebase, then a plain `GitProcess.Failure`.
    ///
    /// Neither abort arm below cleans up the in-flight entry-id file
    /// (#0253, removed here as dead code): `JournalCheckpoint.around`'s
    /// catch clause is the file's only writer, and it runs *after* this
    /// function returns its `Error` up through `body`'s throw -- at which
    /// point it checks the sequencer itself before deciding to write
    /// anything. Since the `git rebase --abort` just below already ends
    /// this rebase, `around` finds no live sequencer and writes nothing for
    /// this operation, so there was never a file here to clear. A
    /// A file left behind by an *earlier*, different interrupted operation
    /// cannot be reached at all since **guide §11 decision 24** (#0273): the
    /// entry id lives inside `rebase-merge/` / `rebase-apply/`, which git
    /// deletes on both finish and abort, so it has the operation's own
    /// lifetime and there is nothing stale to clear or to detect. This
    /// comment previously pointed at `attachRewrite`'s `stillInProgress`
    /// requirement, which #0273 deleted along with the file it guarded. Measured: deleting both call sites this
    /// function used to have leaves the full suite green.
    private static func classifiedRebaseFailure(
        output: GitProcess.Output,
        arguments: [String],
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Error {
        let conflicts = try conflictedFiles(at: path, git: git)
        guard conflicts.isEmpty else {
            return FixupError.blockedOnConflicts(files: conflicts)
        }

        let inEffect = try CommitCreate.signingInEffect(
            signing, in: path, git: git, extraEnvironment: extraEnvironment)
        if let failure = CommitCreate.classify(
            stderr: output.standardError, signingInEffect: inEffect) {
            _ = try? git.run(
                ["rebase", "--abort"], workingDirectory: path, extraEnvironment: extraEnvironment)
            switch failure {
            case let .signingFailed(reason):
                return FixupError.signingFailed(reason: reason)
            }
        }

        _ = try? git.run(
            ["rebase", "--abort"], workingDirectory: path, extraEnvironment: extraEnvironment)
        return GitProcess.Failure.exited(
            code: output.exitCode, stderr: output.standardError, arguments: arguments)
    }

    /// Classifies a `GitProcess.Failure.timedOut` from the `git rebase
    /// --autosquash` invocation (#0163), the mirror of `CommitCreate.
    /// classifyTimeout`. Signing in effect -> `.signingFailed`; otherwise
    /// `failure` is rethrown unchanged, keeping `ExitClass.repositoryError`
    /// via `GitProcess.Failure`'s own conformance. Pure and subprocess-free
    /// -- the caller aborts the rebase itself before calling this, since
    /// that is a side effect, not a classification.
    static func classifyTimeout(_ failure: GitProcess.Failure, signingInEffect: Bool) -> Error {
        guard case let .timedOut(after, _, _) = failure, signingInEffect else { return failure }
        return FixupError.signingFailed(
            reason: "git rebase --autosquash did not finish within \(after) and was terminated -- "
                + "likely a signing prompt with no way to answer it")
    }
}

// MARK: - Existing-commit mode (#0214)

extension Fixup {
    /// Squashes an existing commit into an older ancestor — the other half
    /// of guide §6's `fixup` from #0039, which fixes up the **staged
    /// index** instead of an already-made commit.
    ///
    /// The mechanism differs from #0039's: there is no index to build a
    /// `fixup!` commit from, because the commit already exists. Instead
    /// `source`'s own message is rewritten in place to `fixup! <target's
    /// subject>` with `git commit --amend --fixup=<target> --no-edit`
    /// (measured: this keeps `source`'s content, changes only its message),
    /// and then the same autosquash rebase #0039 runs folds it in.
    /// `--no-edit` is required — without it git opens an editor, and while
    /// `GitProcess` pins `GIT_EDITOR=false` so that would fail rather than
    /// hang, passing `--no-edit` avoids relying on that.
    ///
    /// - Parameter source: the commit to fold in. Defaults to `HEAD`; only
    ///   `HEAD` is supported by this issue — folding a commit that is not
    ///   the tip needs an interactive todo list built by hand, which is
    ///   #0062/#0063's territory. Anything else throws
    ///   `.unsupportedSource(source:)` rather than doing something
    ///   approximate.
    /// - Parameter target: the ancestor commit `source` is squashed into.
    /// - Parameter signing: forwarded exactly as #0039's `run(target:…)`
    ///   forwards it — see that overload's doc comment.
    /// - Throws: `.unsupportedSource` when `source` is not `HEAD`;
    ///   `.targetNotAncestor` when `target` is not an ancestor of `source`;
    ///   `.sourceEqualsTarget` when `source` and `target` resolve to the
    ///   same commit; `.indexNotClean` when the index has staged changes —
    ///   measured: `git commit --amend --fixup=` silently sweeps a dirty
    ///   index into the amended commit, so this guard exists to refuse
    ///   rather than lose staged work silently. This is the mirror image of
    ///   `.nothingStaged` above: `Fixup.run(target:…)` fixes up the index
    ///   and requires it non-empty; this mode fixes up a commit and
    ///   requires the index empty. `.blockedOnConflicts` and
    ///   `.signingFailed` are exactly as #0039's `run(target:…)` documents
    ///   them — the rebase step is shared, not duplicated.
    public static func run(
        source: String = "HEAD",
        target: String,
        signing: CommitCreate.Signing = .config,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Fixup {
        // Only HEAD is supported in this issue. Checked first, and without
        // a git call, since it needs none.
        guard source == "HEAD" else {
            throw FixupError.unsupportedSource(source: source)
        }

        // Guards, in order: source resolves; target is an ancestor of
        // source; source != target; the index is clean.

        // 1. `source` resolves. `.run` throws on a non-zero exit, which is
        //    exactly "does not resolve" here.
        let sourceOid = try git.run(
            ["rev-parse", source], workingDirectory: path, extraEnvironment: extraEnvironment
        ).lines.first ?? ""

        // 2. `target` is an ancestor of `source` — same probe #0039 uses,
        //    read with `capture` since a non-zero exit here is information,
        //    not a launch failure.
        let ancestorCheck = try git.capture(
            ["merge-base", "--is-ancestor", target, source],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        guard ancestorCheck.exitCode == 0 else {
            throw FixupError.targetNotAncestor(target: target)
        }

        // 3. `source != target`, compared by oid so an equivalent ref name
        //    (e.g. `target: "HEAD"`) is still caught.
        let targetOid = try git.run(
            ["rev-parse", target], workingDirectory: path, extraEnvironment: extraEnvironment
        ).lines.first ?? ""
        guard sourceOid != targetOid else {
            throw FixupError.sourceEqualsTarget
        }

        // 4. The index must be clean — the opposite sense of #0039's
        //    `.nothingStaged` guard; see this method's doc comment.
        let staged = try git.run(
            ["diff", "--cached", "--name-only"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        ).lines
        guard staged.isEmpty else {
            throw FixupError.indexNotClean(paths: staged)
        }

        // 5. Everything past this point is one checkpoint for the pair,
        //    exactly as #0039's `run(target:…)`.
        return try JournalCheckpoint.around(operation: "fixup", at: path, git: git) { git in
            try performFixupExisting(
                target: target,
                signing: signing,
                at: path,
                git: git,
                extraEnvironment: extraEnvironment
            )
        }
    }

    /// Rewrites `HEAD`'s own message to `fixup! <target's subject>` in
    /// place, then hands off to the same `autosquashRebase` #0039's
    /// staged-index mode uses — the one piece of the mechanism that is
    /// actually shared between the two modes.
    private static func performFixupExisting(
        target: String,
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Fixup {
        let commitArguments = ["commit", "--amend", "--fixup=\(target)", "--no-edit"]
            + CommitCreate.arguments(for: signing)
        let commitOutput = try git.capture(
            commitArguments,
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        guard commitOutput.exitCode == 0 else {
            throw try classifiedCommitFailure(
                output: commitOutput,
                arguments: commitArguments,
                signing: signing,
                at: path,
                git: git,
                extraEnvironment: extraEnvironment
            )
        }

        return try autosquashRebase(
            target: target, signing: signing, at: path, git: git, extraEnvironment: extraEnvironment)
    }
}

/// Why `Fixup.run` refused, or could not finish.
public enum FixupError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `target` is not an ancestor of `source` (`HEAD` in the staged-index
    /// mode; whatever `source` resolved to in the existing-commit mode).
    case targetNotAncestor(target: String)
    /// The index has nothing staged to fix up. Only thrown by the
    /// staged-index mode (`Fixup.run(target:…)`), which fixes up **the
    /// index** and so requires it non-empty.
    case nothingStaged
    /// The index holds staged changes. Only thrown by the existing-commit
    /// mode (`Fixup.run(source:target:…)`), which fixes up **a commit** and
    /// so requires the index empty — otherwise `git commit --amend
    /// --fixup=` silently sweeps the staged work into the amended commit.
    /// This is `.nothingStaged`'s mirror image: same check, opposite sense,
    /// because the two modes fix up different things.
    case indexNotClean(paths: [String])
    /// `source` and `target` resolved to the same commit.
    case sourceEqualsTarget
    /// `source` was not `HEAD`. Folding a commit that is not the tip needs
    /// an interactive todo list built by hand (#0062/#0063's territory),
    /// which this issue does not implement.
    case unsupportedSource(source: String)
    /// The autosquash rebase could not apply cleanly. The rebase is left in
    /// progress, resumable.
    case blockedOnConflicts(files: [ConflictedFile])
    /// A signature was attempted and could not be produced. No rebase is
    /// left in progress.
    case signingFailed(reason: String)

    public var description: String {
        switch self {
        case let .targetNotAncestor(target):
            "\(target) is not an ancestor of HEAD"
        case .nothingStaged:
            "nothing staged to fix up"
        case let .indexNotClean(paths):
            "refusing to fix up an existing commit: the index already holds staged changes in "
                + paths.joined(separator: ", ")
                + " — commit or unstage that work first, then retry"
        case .sourceEqualsTarget:
            "source and target are the same commit"
        case let .unsupportedSource(source):
            "\(source) is not HEAD — folding a non-tip commit needs a hand-built todo list, not yet supported"
        case let .blockedOnConflicts(files):
            "fixup blocked on conflicts in "
                + files.map(\.path).joined(separator: ", ")
        case let .signingFailed(reason):
            "signing failed: \(reason)"
        }
    }
}

// MARK: - §6 exit class (#0141)

extension FixupError: ExitClassCarrying {
    public var exitClass: ExitClass {
        switch self {
        case .targetNotAncestor, .nothingStaged, .indexNotClean, .sourceEqualsTarget, .unsupportedSource:
            .repositoryError
        case .blockedOnConflicts: .blockedOnConflicts
        case .signingFailed: .signingFailed
        }
    }
}
