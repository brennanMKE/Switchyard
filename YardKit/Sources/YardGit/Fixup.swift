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

    /// Runs the two git invocations that do the actual work, assuming the
    /// ancestor and staged-index guards already passed and the checkpoint is
    /// already written.
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
        let rebaseOutput = try git.capture(
            rebaseArguments,
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
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
}

/// Why `Fixup.run` refused, or could not finish.
public enum FixupError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `target` is not an ancestor of `HEAD`.
    case targetNotAncestor(target: String)
    /// The index has nothing staged to fix up.
    case nothingStaged
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
        case .targetNotAncestor, .nothingStaged: .repositoryError
        case .blockedOnConflicts: .blockedOnConflicts
        case .signingFailed: .signingFailed
        }
    }
}
