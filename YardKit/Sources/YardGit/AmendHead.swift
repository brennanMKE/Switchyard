// AmendHead.swift — amend the last commit with the index as it stands (#0463, #0464)

import Foundation

/// Amend: replace `HEAD`'s commit with one holding the index as it stands
/// and a new message, on the same parents (guide §11 decision 33). The
/// Changes view's Amend toggle is the caller.
///
/// Amend never rewrites a commit a remote-tracking ref already contains:
/// that rewrite only reaches the remote by force-pushing, and Switchyard
/// never force-pushes (decision 32). The engine refuses it for every
/// caller, not only the app's disabled toggle — the lesson #0461 learned
/// about a guard that lived only in a menu.
public enum AmendHead {

    /// Why the engine will not amend `HEAD`, decided before anything runs.
    public enum Refusal: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        /// `HEAD` names a branch with no commits yet.
        case noCommits
        /// `HEAD`'s commit is reachable from `remoteRef` (short name, e.g.
        /// `origin/main`), so it has been pushed.
        case pushed(remoteRef: String)

        public var description: String {
            switch self {
            case .noCommits:
                "There is no commit to amend yet."
            case let .pushed(remoteRef):
                "The last commit is already on \(remoteRef). Amending it would need a force-push, "
                    + "which Switchyard never does."
            }
        }
    }

    /// What Amend would rewrite, read fresh for the Changes view.
    public struct Target: Equatable, Sendable {
        /// `HEAD`'s full object id; `nil` on an unborn branch.
        public let oid: String?
        /// `HEAD`'s full message, trailing newlines removed — what the
        /// Amend toggle puts in the message editor. Empty when unborn.
        public let message: String
        /// Why `run` would refuse, or `nil` when it would go ahead.
        public let refusal: Refusal?

        public init(oid: String?, message: String, refusal: Refusal?) {
            self.oid = oid
            self.message = message
            self.refusal = refusal
        }
    }

    /// Reads `HEAD`'s commit, its message, and whether Amend is refused.
    ///
    /// Three `git` calls at most: `rev-parse --verify -q HEAD^{commit}`
    /// (exit 1, not an error, on an unborn branch), `log -1 --format=%B`
    /// with `--no-show-signature` so `log.showSignature` cannot put gpg
    /// output in the message, and `for-each-ref --contains` over
    /// `refs/remotes/` for the published check.
    public static func target(
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Target {
        let head = try git.capture(
            ["rev-parse", "--verify", "-q", "HEAD^{commit}"],
            workingDirectory: path, extraEnvironment: extraEnvironment)
        guard head.exitCode == 0, let oid = head.lines.first, !oid.isEmpty else {
            return Target(oid: nil, message: "", refusal: .noCommits)
        }
        let body = try git.run(
            ["log", "-1", "--no-show-signature", "--format=%B", oid, "--"],
            workingDirectory: path, extraEnvironment: extraEnvironment
        ).text
        var message = Substring(body)
        while message.hasSuffix("\n") { message = message.dropLast() }
        let refusal = try publishedRef(of: oid, at: path, git: git, extraEnvironment: extraEnvironment)
            .map { Refusal.pushed(remoteRef: $0) }
        return Target(oid: oid, message: String(message), refusal: refusal)
    }

    /// The remote-tracking ref that already contains `oid`, or `nil` when
    /// none does. Symbolic refs (`origin/HEAD`) are skipped, so the name is
    /// a real branch. The checked-out branch's upstream is named when it is
    /// one of them — the ref a user would push to — else the first in
    /// refname order.
    ///
    /// Any remote-tracking ref, not only `@{upstream}`: a branch just cut
    /// from `main`, with no upstream yet, has `HEAD` at `origin/main`'s
    /// commit, and amending that rewrites published history too.
    static func publishedRef(
        of oid: String, at path: String, git: GitProcess, extraEnvironment: [String: String]
    ) throws -> String? {
        let listed = try git.run(
            ["for-each-ref", "--contains", oid, "--format=%(symref)%09%(refname:short)", "refs/remotes/"],
            workingDirectory: path, extraEnvironment: extraEnvironment
        ).lines
        let names = listed.compactMap { line -> String? in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            return String(fields[1])
        }
        guard let first = names.first else { return nil }
        let upstream = try git.capture(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            workingDirectory: path, extraEnvironment: extraEnvironment)
        if upstream.exitCode == 0, let name = upstream.lines.first, names.contains(name) {
            return name
        }
        return first
    }
}

/// Every refusal is the repository's own state, decided before anything
/// runs: guide §6 code 6.
extension AmendHead.Refusal: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}

// MARK: - Amend (#0464)

extension AmendHead {

    /// Amends `HEAD`: `git commit --amend -m <message>`, journaled as one
    /// `amend` entry, so Edit ▸ Undo Amend puts back the old `HEAD` commit
    /// and the index as it was before (the staged changes staged again).
    ///
    /// Everything else is `CommitCreate.run`'s: `pre-commit` and
    /// `commit-msg` hooks run, signing follows `signing`, a signature that
    /// cannot be produced throws `CommitCreate.Failure.signingFailed`, and
    /// any other refusal throws `GitProcess.Failure.exited` with git's
    /// stderr. Nothing staged is allowed — that is a message-only amend. The
    /// author and author date stay `HEAD`'s (git's `--amend` rule); the
    /// committer is the current user. A merge commit keeps both parents.
    ///
    /// - Throws: `Refusal` from `target(at:)` **before** the checkpoint, so
    ///   a refused amend writes no entry. Git's own refusals come after the
    ///   checkpoint and keep it (`around`'s rule): measured, git 2.54.0,
    ///   `fatal: You are in the middle of a merge -- cannot amend.` (exit
    ///   128) while a merge is in progress, and `You asked to amend the most
    ///   recent commit, but doing so would make it empty.` (exit 1, on
    ///   stderr) when the result would be an empty non-root commit.
    @discardableResult
    public static func run(
        message: String,
        signing: CommitCreate.Signing = .config,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> CommitCreate {
        if let refusal = try target(at: path, git: git, extraEnvironment: extraEnvironment).refusal {
            throw refusal
        }
        return try JournalCheckpoint.around(operation: "amend", at: path, git: git) { git in
            try CommitCreate.run(
                message: message,
                signing: signing,
                amend: true,
                in: path,
                git: git,
                extraEnvironment: extraEnvironment
            )
        }
    }
}
