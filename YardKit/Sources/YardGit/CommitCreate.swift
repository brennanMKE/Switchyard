// CommitCreate.swift — create a commit through `git commit`, signing per intent (#0036)

import Foundation

/// Creates one commit by shelling out to `git commit`, with signing decided by
/// a three-valued intent. Signing MUST shell out — libgit2 does not produce
/// signatures, and `git commit` is also the only path that runs the repository's
/// hooks (`pre-commit`, `commit-msg`), which #0038 requires. Git itself invokes
/// `ssh-keygen -Y sign` (or gpg) per its own config; nothing here reads a key,
/// and nothing here ever creates one.
///
/// The guarantee this type exists for (guide §9 M2): **a signature that cannot
/// be produced fails with `ExitClass.signingFailed` (9) rather than committing
/// unsigned.** Git already refuses to write the commit object when signing
/// fails (measured, Givens in #0036); this type's job is to preserve that
/// refusal as a typed, classified error instead of a generic exit-128.
public struct CommitCreate: Equatable, Sendable {

    /// What the caller wants about signing. Three-valued on purpose: "let the
    /// repository's `commit.gpgsign` decide" is different from either override.
    /// Measured precedence (#0036 Givens): `--gpg-sign` wins over
    /// `commit.gpgsign=false`, and `--no-gpg-sign` wins over
    /// `commit.gpgsign=true` — the flags always beat the config.
    public enum Signing: Equatable, Sendable {
        /// No flag: `commit.gpgsign` decides, git's default being "do not sign".
        case config
        /// `--gpg-sign`: sign even when `commit.gpgsign` is false or unset.
        case sign
        /// `--no-gpg-sign`: never sign, even when `commit.gpgsign` is true.
        case noSign
    }

    /// The one failure this type classifies. Everything else a failing
    /// `git commit` can produce — nothing staged, a hook declining, a bad
    /// revision — propagates as `GitProcess.Failure`, which already carries
    /// `ExitClass.repositoryError` (6).
    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        /// Git refused to write the commit because the signature could not be
        /// produced. `reason` is git's trimmed stderr, verbatim.
        case signingFailed(reason: String)

        public var description: String {
            switch self {
            case let .signingFailed(reason): "signing failed: \(reason)"
            }
        }
    }

    /// The oid of the commit that was created.
    public let oid: String

    public init(oid: String) {
        self.oid = oid
    }

    /// Commits the staged index with `message`, signing per `signing`.
    ///
    /// One `git commit` invocation through `GitProcess.capture` (so the exit
    /// code can be classified rather than thrown raw), then `git rev-parse
    /// HEAD` for the new oid on success. `GIT_EDITOR` is never invoked:
    /// `GitProcess` pins it to `false` and `-m` is always passed.
    ///
    /// - Parameter extraEnvironment: merged over the process environment for
    ///   every invocation. Tests use it to neutralize global and system config
    ///   scope; production callers leave it empty.
    /// - Throws: `Failure.signingFailed` when signing was in effect and git's
    ///   stderr matches a measured signing-failure shape; `GitProcess.Failure`
    ///   for every other non-zero exit. On either throw no commit was written —
    ///   git refuses the object write itself, measured in #0036's Givens.
    public static func run(
        message: String,
        signing: Signing = .config,
        in workingDirectory: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> CommitCreate {
        let args = ["commit", "-m", message] + arguments(for: signing)
        let output = try git.capture(
            args,
            workingDirectory: workingDirectory,
            extraEnvironment: extraEnvironment
        )
        guard output.exitCode == 0 else {
            let inEffect = try signingInEffect(
                signing,
                in: workingDirectory,
                git: git,
                extraEnvironment: extraEnvironment
            )
            if let failure = classify(stderr: output.standardError, signingInEffect: inEffect) {
                throw failure
            }
            throw GitProcess.Failure.exited(
                code: output.exitCode,
                stderr: output.standardError,
                arguments: args
            )
        }
        let head = try git.run(
            ["rev-parse", "HEAD"],
            workingDirectory: workingDirectory,
            extraEnvironment: extraEnvironment
        )
        return CommitCreate(oid: head.lines.first ?? "")
    }

    /// The flag each intent contributes to `git commit`'s argument vector.
    /// Long spellings so a log line reads without a lookup.
    static func arguments(for signing: Signing) -> [String] {
        switch signing {
        case .config: []
        case .sign: ["--gpg-sign"]
        case .noSign: ["--no-gpg-sign"]
        }
    }

    /// Whether git will attempt a signature for this invocation. `.sign` and
    /// `.noSign` are decided by the flag alone (measured: flags beat config);
    /// `.config` is decided by the effective `commit.gpgsign`, read through
    /// `SigningConfig` — consulted only on the failure path, so a successful
    /// commit costs no extra invocations.
    static func signingInEffect(
        _ signing: Signing,
        in workingDirectory: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Bool {
        switch signing {
        case .sign: true
        case .noSign: false
        case .config:
            try SigningConfig.read(
                in: workingDirectory,
                git: git,
                extraEnvironment: extraEnvironment
            ).willSign
        }
    }

    /// The measured stderr shapes of a signing failure (#0036 Givens, git
    /// 2.50.1, `LC_ALL=C` pinned by `GitProcess`):
    ///
    /// - `fatal: failed to write commit object` — the object-write refusal that
    ///   follows every failed signature (unloadable SSH key, gpg failure).
    /// - `either user.signingkey or gpg.ssh.defaultKeyCommand needs to be
    ///   configured` — git's early fatal when `gpg.format=ssh` has no key at
    ///   all; the write-refusal line never appears in that case.
    static let signingFailureMarkers = [
        "failed to write commit object",
        "either user.signingkey or gpg.ssh.defaultKeyCommand",
    ]

    /// Classifies a failing `git commit`. Returns `.signingFailed` only when a
    /// signature was actually being attempted AND stderr matches a measured
    /// signing-failure shape — an unsigned commit that fails to write its
    /// object is a repository error, not a signing one, however similar the
    /// message. Returns `nil` for every failure the caller should surface as
    /// `GitProcess.Failure`.
    static func classify(stderr: String, signingInEffect: Bool) -> Failure? {
        guard signingInEffect else { return nil }
        guard signingFailureMarkers.contains(where: { stderr.contains($0) }) else { return nil }
        return .signingFailed(reason: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - §6 exit class (#0141)

/// The M2 criterion, as engine contract: a signature that cannot be produced
/// is guide §6 code 9, envelope label `signing_failed` — never a silent
/// unsigned commit, and never a generic repository error.
extension CommitCreate.Failure: ExitClassCarrying {
    public var exitClass: ExitClass { .signingFailed }
}
