// RefManage.swift — tag and branch management: create, rename, delete, set
// upstream (#0363)

import Foundation

/// Which namespace a managed ref lives in. The kind decides the prefix every
/// existence check and every assertion uses, and the wording of the refusals
/// that name it.
public enum RefKind: Equatable, Sendable, CustomStringConvertible {
    /// `refs/heads/<name>`.
    case branch
    /// `refs/tags/<name>`.
    case tag

    public var description: String {
        switch self {
        case .branch: "branch"
        case .tag: "tag"
        }
    }

    /// The namespace the kind's refs live under.
    var refPrefix: String {
        switch self {
        case .branch: "refs/heads/"
        case .tag: "refs/tags/"
        }
    }
}

/// Why `Tag.create` or one of `Branch`'s operations refused, or could not
/// finish. Every case here is raised **before** the first mutation — before
/// the journal checkpoint is written, so a refusal touches nothing: no ref
/// moves, no object is written, and `undo` has nothing to reverse.
public enum RefManageError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A revision the caller named — a tag's target commit or a branch's
    /// start point — does not resolve. Raised before anything is touched.
    case unknownRevision(String)
    /// The branch this operation names does not exist. Raised before anything
    /// is touched.
    case unknownBranch(String)
    /// The upstream to track does not resolve to any local branch or
    /// remote-tracking ref. Raised before anything is touched.
    case unknownUpstream(String)
    /// A tag or branch with this exact name already exists. Raised before
    /// anything is touched.
    case alreadyExists(kind: RefKind, name: String)
    /// The requested name clashes with an existing ref across the `/`
    /// boundary — `feat` against `feat/x`, or the reverse. git refuses the
    /// write at the ref layer; this refusal is raised before anything is
    /// touched.
    case nameClash(requested: String, existing: String)
    /// The name is not a valid ref name (`git check-ref-format`). Raised
    /// before anything is touched.
    case invalidName(kind: RefKind, name: String)
    /// Deleting the branch the calling worktree has checked out — HEAD's own
    /// symref. Raised before anything is touched.
    case deletingCheckedOutBranch(name: String, worktree: String)
    /// A linked worktree has this branch checked out; deleting it would leave
    /// that worktree on a branch that no longer exists. Raised before
    /// anything is touched.
    case branchHeldByWorktree(name: String, worktree: String)
    /// The branch's tip is not reachable from HEAD, so deleting it would take
    /// its commits off every branch — the data loss `--force` exists to
    /// confirm. Raised before anything is touched.
    case unmergedBranch(name: String, tip: String)
    /// An annotated tag needs a message; none was given.
    case messageRequired
    /// Signing was requested (or explicitly suppressed) for a lightweight
    /// tag, which has no object to sign.
    case signingRequiresAnnotated
    /// A signature was attempted and could not be produced. Nothing was
    /// created — git refuses the tag object write itself.
    case signingFailed(reason: String)

    public var description: String {
        switch self {
        case let .unknownRevision(revision):
            "unknown commit '\(revision)' — it does not resolve in this repository; nothing was touched"
        case let .unknownBranch(name):
            "unknown branch '\(name)' — there is no refs/heads/\(name) in this repository; nothing was touched"
        case let .unknownUpstream(name):
            "unknown upstream '\(name)' — it does not resolve to a local branch or a "
                + "remote-tracking ref; nothing was touched"
        case let .alreadyExists(kind, name):
            "a \(kind) named '\(name)' already exists; nothing was touched"
        case let .nameClash(requested, existing):
            "cannot create '\(requested)': '\(existing)' exists — a ref cannot be "
                + "both a directory prefix and a name; nothing was touched"
        case let .invalidName(kind, name):
            "'\(name)' is not a valid \(kind) name (git check-ref-format refuses it); nothing was touched"
        case let .deletingCheckedOutBranch(name, worktree):
            "cannot delete branch '\(name)' checked out at \(worktree); nothing was touched"
        case let .branchHeldByWorktree(name, worktree):
            "cannot delete branch '\(name)' used by worktree at \(worktree); nothing was touched"
        case let .unmergedBranch(name, tip):
            "the branch '\(name)' is not fully merged — its tip \(tip) is not reachable from HEAD "
                + "and deleting it would take its commits off every branch; "
                + "pass --force to delete it anyway (the journal records the deletion)"
        case .messageRequired:
            "an annotated tag requires a message; pass --message <message> or create a lightweight tag"
        case .signingRequiresAnnotated:
            "signing applies to annotated tags only — a lightweight tag has no object to sign"
        case let .signingFailed(reason):
            "signing failed: \(reason)"
        }
    }
}

// MARK: - §6 exit class

extension RefManageError: ExitClassCarrying {
    public var exitClass: ExitClass {
        switch self {
        case .signingFailed: .signingFailed
        default: .repositoryError
        }
    }
}

// MARK: - Tag

/// Tag creation — lightweight or annotated, signing per explicit intent
/// (#0363). Everything else about tags (rename, delete) is not in this
/// issue's surface.
///
/// The measured shape of the operation (git 2.50.1): `git tag <name> <commit>`
/// is a lightweight ref pointing at the commit; `-a -F -` builds an annotated
/// tag object with the message read from stdin, so no editor and no argv
/// quoting is ever involved; `-s` signs the annotated tag and shells out
/// through `gpg.program` exactly as `git commit` does. `--no-sign` is
/// accepted alongside `-a` and beats `tag.gpgsign`, the same precedence
/// `git commit`'s flags have (#0036). Names ride after `--` so a name
/// beginning with `-` reaches git's own name validation instead of its option
/// parser; the invalid-name refusal below happens before that call anyway.
public struct Tag: Equatable, Sendable {

    /// What a completed creation produced: the ref, the object it names
    /// (the tag object when annotated, the commit when lightweight), and
    /// which of the two it is.
    public struct Result: Sendable, Equatable, Encodable {

        /// The full ref name, `refs/tags/<name>`.
        public let ref: String

        /// The object the ref points at: the tag object for an annotated
        /// tag, the commit itself for a lightweight one.
        public let oid: String

        /// Whether this is an annotated tag.
        public let annotated: Bool

        public init(ref: String, oid: String, annotated: Bool) {
            self.ref = ref
            self.oid = oid
            self.annotated = annotated
        }

        /// The stable wire key, identical to the stored-member name on
        /// purpose; no raw values — the case name IS the wire key.
        private enum CodingKeys: String, CodingKey {
            case ref, oid, annotated
        }
    }

    /// Creates a tag at `commit`.
    ///
    /// A lightweight tag (`annotated: false`) points straight at the commit.
    /// An annotated tag requires a message; it is written to the tag object
    /// through stdin, so multi-paragraph messages round-trip byte-for-byte
    /// and `GIT_EDITOR` is never invoked (`GitProcess` pins it `false`, and
    /// the message always rides `-F -`). Signing follows the #0060 rule: the
    /// explicit flag for the resolved intent, never config reliance —
    /// `.config` consults `tag.gpgsign`, `.sign` and `.noSign` override it.
    ///
    /// - Throws: `RefManageError.invalidName` when the name is not a valid
    ///   tag name; `.messageRequired` when an annotated tag has no message;
    ///   `.signingRequiresAnnotated` when signing intent meets a lightweight
    ///   creation; `.unknownRevision` when `commit` does not resolve;
    ///   `.alreadyExists` when the tag exists; `.signingFailed` when a
    ///   signature was attempted and could not be produced;
    ///   `GitProcess.Failure` for every other non-zero exit.
    public static func create(
        name: String,
        commit: String,
        annotated: Bool = false,
        message: String? = nil,
        signing: CommitCreate.Signing = .config,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Result {
        try refuseInvalidName(.tag, name, at: path, git: git, extraEnvironment: extraEnvironment)
        if annotated {
            guard let message, !message.isEmpty else { throw RefManageError.messageRequired }
        } else if signing != .config {
            throw RefManageError.signingRequiresAnnotated
        }
        let commitOid = try resolve(commit, at: path, git: git, extraEnvironment: extraEnvironment)
        try refuseIfRefExists(.tag, name, at: path, git: git, extraEnvironment: extraEnvironment)
        try refuseRefClash(.tag, name, at: path, git: git, extraEnvironment: extraEnvironment)
        return try JournalCheckpoint.around(operation: "tag-create", at: path, git: git) { scoped in
            try perform(
                name: name, commitOid: commitOid, annotated: annotated, message: message,
                signing: signing, at: path, git: scoped, extraEnvironment: extraEnvironment)
        }
    }

    /// Runs `git tag` inside the checkpoint. Assumes every guard passed.
    static func perform(
        name: String,
        commitOid: String,
        annotated: Bool,
        message: String?,
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Result {
        let inEffect = try signingInEffect(
            signing, at: path, git: git, extraEnvironment: extraEnvironment)
        var arguments = ["tag"]
        if annotated { arguments += ["-a", "-F", "-"] }
        if inEffect {
            arguments += ["-s"]
        } else if annotated {
            arguments += ["--no-sign"]
        }
        arguments += ["--", name, commitOid]

        let output: GitProcess.Output
        do {
            output = try git.capture(
                arguments,
                workingDirectory: path,
                standardInput: annotated ? Data((message ?? "").utf8) : nil,
                extraEnvironment: extraEnvironment,
                timeout: inEffect ? GitProcess.signingTimeout : nil
            )
        } catch let failure as GitProcess.Failure {
            if case .timedOut = failure {
                throw classifyTimeout(failure, signingInEffect: inEffect)
            }
            throw failure
        }
        guard output.exitCode == 0 else {
            if inEffect, isSigningFailure(output.standardError) {
                throw RefManageError.signingFailed(
                    reason: output.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw GitProcess.Failure.exited(
                code: output.exitCode,
                stderr: output.standardError,
                arguments: arguments
            )
        }
        let oid = try git.run(
            ["rev-parse", "refs/tags/\(name)"],
            workingDirectory: path, extraEnvironment: extraEnvironment
        ).lines.first ?? ""
        return Result(ref: "refs/tags/\(name)", oid: oid, annotated: annotated)
    }

    /// Whether git will attempt a signature, per the #0060 rule: `.sign` and
    /// `.noSign` are decided by the flag alone; `.config` consults
    /// `tag.gpgsign` — the tag's own key, not `commit.gpgsign` — whose git
    /// default is "do not sign". One cheap config read, the same cost
    /// `CommitCreate.signingInEffect` pays.
    static func signingInEffect(
        _ signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Bool {
        switch signing {
        case .sign: return true
        case .noSign: return false
        case .config:
            let output = try git.capture(
                ["config", "--type=bool", "--default=false", "tag.gpgsign"],
                workingDirectory: path, extraEnvironment: extraEnvironment)
            return output.lines.first == "true"
        }
    }

    /// The measured stderr shapes of a failed `git tag -s` signature
    /// (git 2.50.1, a failing `gpg.program`): `error: gpg failed to sign the
    /// data:` plus the helper's output, then `error: unable to sign the tag`,
    /// exit 128.
    static let signingFailureMarkers = [
        "gpg failed to sign the data",
        "unable to sign the tag",
    ]

    static func isSigningFailure(_ stderr: String) -> Bool {
        signingFailureMarkers.contains { stderr.contains($0) }
    }

    /// The mirror of `CommitCreate.classifyTimeout` (#0163): a timed-out
    /// `git tag -s` can only be a signing prompt with no way to answer it.
    static func classifyTimeout(
        _ failure: GitProcess.Failure,
        signingInEffect: Bool
    ) -> Error {
        guard case let .timedOut(after, _, _) = failure, signingInEffect else {
            return failure
        }
        return RefManageError.signingFailed(
            reason: "git tag did not finish within \(after) and was terminated -- "
                + "likely a signing prompt with no way to answer it")
    }
}

// MARK: - Branch

/// Branch management: create, rename, delete, set upstream (#0363). The
/// rename is `git branch -m`, which moves HEAD's symref when the
/// checked-out branch is the one being renamed (measured) — the caller's
/// checkout follows the new name without a second write. Every operation is
/// one mutation inside one `JournalCheckpoint.around`, so `yard undo`
/// reverses it as a single step — including a forced delete, whose ref
/// snapshot is what restores the branch.
public struct Branch: Equatable, Sendable {

    /// What a completed operation produced. `upstream` is set only by
    /// `setUpstream` and `headFollowed` only by `rename`; both are absent
    /// from the wire for the operations that do not produce them.
    public struct Result: Sendable, Equatable, Encodable {

        /// The full ref name the operation is about: the created, renamed
        /// (new), deleted, or upstreamed branch.
        public let ref: String

        /// The branch's tip after the operation — for `delete`, the tip the
        /// deleted ref held.
        public let oid: String

        /// The full ref name of the upstream just set, e.g.
        /// `refs/remotes/origin/main`.
        public let upstream: String?

        /// Whether HEAD's symref followed a rename (the branch was the
        /// calling worktree's checkout). `nil` — and absent on the wire —
        /// for every operation but `rename`.
        public let headFollowed: Bool?

        public init(ref: String, oid: String, upstream: String? = nil,
                    headFollowed: Bool? = nil) {
            self.ref = ref
            self.oid = oid
            self.upstream = upstream
            self.headFollowed = headFollowed
        }

        /// The stable wire key, identical to the stored-member name on
        /// purpose; no raw values — the case name IS the wire key.
        private enum CodingKeys: String, CodingKey {
            case ref, oid, upstream, headFollowed
        }
    }

    /// Creates a branch at `start` (default HEAD) without checking it out —
    /// the engine verb is create, never switch.
    ///
    /// - Throws: `RefManageError.invalidName` when the name is not a valid
    ///   branch name; `.alreadyExists` when the branch exists;
    ///   `.nameClash` when the name collides with an existing ref across the
    ///   `/` boundary in either direction; `.unknownRevision` when `start`
    ///   does not resolve; `GitProcess.Failure` for every other non-zero
    ///   exit.
    public static func create(
        name: String,
        start: String? = nil,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Result {
        try refuseInvalidName(.branch, name, at: path, git: git, extraEnvironment: extraEnvironment)
        try refuseIfRefExists(.branch, name, at: path, git: git, extraEnvironment: extraEnvironment)
        try refuseRefClash(.branch, name, at: path, git: git, extraEnvironment: extraEnvironment)
        let startOid = try resolve(start ?? "HEAD", at: path, git: git, extraEnvironment: extraEnvironment)
        return try JournalCheckpoint.around(operation: "branch-create", at: path, git: git) { scoped in
            try scoped.run(
                ["branch", "--", name, startOid],
                workingDirectory: path, extraEnvironment: extraEnvironment)
            return Result(ref: "refs/heads/\(name)", oid: startOid)
        }
    }

    /// Renames a branch — `git branch -m` — which moves HEAD's symref when
    /// the renamed branch is the one this worktree has checked out, so the
    /// caller's checkout follows the new name. A branch held by a linked
    /// worktree renames cleanly too: git updates that worktree's HEAD.
    ///
    /// - Throws: `RefManageError.unknownBranch` when `old` does not exist;
    ///   `.invalidName` when the new name is not a valid branch name;
    ///   `.alreadyExists` when the new name exists;
    ///   `.nameClash` on a `/`-boundary collision; `GitProcess.Failure` for
    ///   every other non-zero exit.
    public static func rename(
        old: String,
        new: String,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Result {
        try refuseIfBranchExists(old, at: path, git: git, extraEnvironment: extraEnvironment)
        try refuseInvalidName(.branch, new, at: path, git: git, extraEnvironment: extraEnvironment)
        try refuseIfRefExists(.branch, new, at: path, git: git, extraEnvironment: extraEnvironment)
        try refuseRefClash(.branch, new, at: path, git: git, extraEnvironment: extraEnvironment)
        let headFollowed = try headSymref(at: path, git: git, extraEnvironment: extraEnvironment)
            == "refs/heads/\(old)"
        return try JournalCheckpoint.around(operation: "branch-rename", at: path, git: git) { scoped in
            try scoped.run(
                ["branch", "-m", "--", old, new],
                workingDirectory: path, extraEnvironment: extraEnvironment)
            let oid = try scoped.run(
                ["rev-parse", "refs/heads/\(new)"],
                workingDirectory: path, extraEnvironment: extraEnvironment
            ).lines.first ?? ""
            return Result(ref: "refs/heads/\(new)", oid: oid, upstream: nil,
                          headFollowed: headFollowed)
        }
    }

    /// Deletes a branch. Without `force`, the deletion is refused unless the
    /// branch's tip is reachable from HEAD — the data-loss guard git's own
    /// `-d` enforces. With `force` (`git branch -D`) the deletion proceeds
    /// and the journal's ref snapshot is what makes `yard undo` bring the
    /// branch back.
    ///
    /// - Throws: `RefManageError.unknownBranch`; `.deletingCheckedOutBranch`
    ///   when this worktree has it checked out; `.branchHeldByWorktree` when
    ///   a linked worktree does; `.unmergedBranch` when the tip is not
    ///   reachable from HEAD and no `force` was given; `GitProcess.Failure`
    ///   for every other non-zero exit.
    public static func delete(
        name: String,
        force: Bool = false,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Result {
        let tip = try refuseIfBranchExists(name, at: path, git: git,
                                           extraEnvironment: extraEnvironment)
        let context = try WorktreeContext.resolve(path: path, git: git)
        try refuseCheckedOut(name, context: context, at: path, git: git,
                             extraEnvironment: extraEnvironment)
        try refuseHeldByLinkedWorktree(name, context: context, at: path, git: git,
                                       extraEnvironment: extraEnvironment)
        if !force {
            try refuseUnmerged(name, tip: tip, at: path, git: git,
                               extraEnvironment: extraEnvironment)
        }
        return try JournalCheckpoint.around(operation: "branch-delete", at: path, git: git) { scoped in
            try scoped.run(
                ["branch", "-D", "--", name],
                workingDirectory: path, extraEnvironment: extraEnvironment)
            return Result(ref: "refs/heads/\(name)", oid: tip)
        }
    }

    /// Points a branch's upstream at a local branch or a remote-tracking ref.
    /// The upstream is resolved to its full ref name before the mutation so
    /// the payload names exactly what was set, and `git branch
    /// --set-upstream-to` is handed the same unambiguous name.
    ///
    /// - Throws: `RefManageError.unknownBranch` when the branch does not
    ///   exist; `.unknownUpstream` when the upstream resolves to neither a
    ///   local branch, a remote-tracking ref, nor an existing full ref name;
    ///   `GitProcess.Failure` for every other non-zero exit.
    public static func setUpstream(
        name: String,
        upstream: String,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Result {
        let tip = try refuseIfBranchExists(name, at: path, git: git,
                                           extraEnvironment: extraEnvironment)
        let upstreamRef = try resolveUpstream(upstream, at: path, git: git,
                                              extraEnvironment: extraEnvironment)
        return try JournalCheckpoint.around(operation: "branch-upstream", at: path, git: git) { scoped in
            try scoped.run(
                ["branch", "--set-upstream-to=\(upstreamRef)", "--", name],
                workingDirectory: path, extraEnvironment: extraEnvironment)
            return Result(ref: "refs/heads/\(name)", oid: tip, upstream: upstreamRef)
        }
    }
}

// MARK: - Shared guards

/// Every refusal below is raised before the first mutation and before the
/// journal checkpoint, so a refused operation writes nothing at all — not
/// even an undo entry.
private func refuseInvalidName(
    _ kind: RefKind,
    _ name: String,
    at path: String,
    git: GitProcess,
    extraEnvironment: [String: String]
) throws {
    // `--branch` applies the branch-specific rules (`git branch`'s own
    // grammar, measured against `feature/x`, `@`, `naïve`, spaces, `..`,
    // `~`, a leading dash, `.lock`, bare `HEAD`, a trailing slash, a leading
    // dot, `:`, and `?`); `--allow-onelevel` is the tag grammar, which lets
    // one-level names like `v1` through but keeps every other rule. No `--`
    // here: check-ref-format takes no separator (measured, exit 129), and a
    // dash-leading name is refused by parse-options at exit 129 — refused
    // either way.
    var arguments = ["check-ref-format"]
    if kind == .tag { arguments += ["--allow-onelevel"] } else { arguments += ["--branch"] }
    arguments += [name]
    let output = try git.capture(
        arguments, workingDirectory: path, extraEnvironment: extraEnvironment)
    guard output.exitCode == 0 else {
        throw RefManageError.invalidName(kind: kind, name: name)
    }
}

/// Refuses a name that already exists exactly in the kind's namespace.
private func refuseIfRefExists(
    _ kind: RefKind,
    _ name: String,
    at path: String,
    git: GitProcess,
    extraEnvironment: [String: String]
) throws {
    let output = try git.capture(
        ["rev-parse", "--verify", "--quiet", kind.refPrefix + name],
        workingDirectory: path, extraEnvironment: extraEnvironment)
    guard output.exitCode != 0 else {
        throw RefManageError.alreadyExists(kind: kind, name: name)
    }
}

/// `git branch`'s existence refusal, returning the branch's tip — the oid a
/// delete reports and an undo restores.
@discardableResult
private func refuseIfBranchExists(
    _ name: String,
    at path: String,
    git: GitProcess,
    extraEnvironment: [String: String]
) throws -> String {
    let output = try git.capture(
        ["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"],
        workingDirectory: path, extraEnvironment: extraEnvironment)
    guard output.exitCode == 0, let tip = output.lines.first, !tip.isEmpty else {
        throw RefManageError.unknownBranch(name)
    }
    return tip
}

/// Refuses the `/`-boundary collision git's ref locking enforces at write
/// time (measured: with `feat/x` present, `git branch feat` exits 128 with
/// `cannot lock ref`): `feat` may not be created while `feat/x` exists, nor
/// `feat/x` while `feat` does.
private func refuseRefClash(
    _ kind: RefKind,
    _ name: String,
    at path: String,
    git: GitProcess,
    extraEnvironment: [String: String]
) throws {
    let requested = kind.refPrefix + name
    // A bare prefix pattern — measured: for-each-ref's `*` glob does not
    // match `/`, so `refs/heads/*` would miss `refs/heads/feat/x`, while the
    // bare `refs/heads/` prefix lists every ref under the namespace.
    let listing = try git.run(
        ["for-each-ref", "--format=%(refname)", kind.refPrefix],
        workingDirectory: path, extraEnvironment: extraEnvironment)
    for existing in listing.lines {
        if requested.hasPrefix(existing + "/") || existing.hasPrefix(requested + "/") {
            throw RefManageError.nameClash(requested: requested, existing: existing)
        }
    }
}

/// HEAD's symbolic target — `refs/heads/main` when attached, `nil` when
/// detached.
private func headSymref(
    at path: String,
    git: GitProcess,
    extraEnvironment: [String: String]
) throws -> String? {
    let output = try git.capture(
        ["symbolic-ref", "-q", "HEAD"],
        workingDirectory: path, extraEnvironment: extraEnvironment)
    guard output.exitCode == 0, let target = output.lines.first else { return nil }
    return target
}

/// Refuses deleting the branch this worktree has checked out — HEAD's own
/// symref, which git refuses for the calling worktree with the same
/// `cannot delete branch ... used by worktree` shape it uses for linked
/// worktrees (measured).
private func refuseCheckedOut(
    _ name: String,
    context: WorktreeContext,
    at path: String,
    git: GitProcess,
    extraEnvironment: [String: String]
) throws {
    guard try headSymref(at: path, git: git, extraEnvironment: extraEnvironment)
        != "refs/heads/\(name)" else {
        throw RefManageError.deletingCheckedOutBranch(
            name: name, worktree: context.topLevel ?? path)
    }
}

/// Refuses deleting a branch a linked worktree holds — git refuses the write
/// itself (measured, exit 1); typing it here keeps the refusal before the
/// checkpoint and names the holding worktree's path.
private func refuseHeldByLinkedWorktree(
    _ name: String,
    context: WorktreeContext,
    at path: String,
    git: GitProcess,
    extraEnvironment: [String: String]
) throws {
    let worktrees = try worktreeList(path: path, git: git)
    for entry in worktrees where entry.branch == name {
        // `WorktreeEntry.branch` is the short name (refs/heads/ stripped).
        // The caller's own worktree was refused above; any *other* holding
        // worktree is this refusal. A prunable holder's directory is gone —
        // git still honors the claim, so the refusal stands either way.
        if entry.path != context.topLevel {
            throw RefManageError.branchHeldByWorktree(
                name: name, worktree: entry.path ?? "(unknown worktree)")
        }
    }
}

/// Refuses the deletion when the branch's tip is not reachable from HEAD —
/// the data-loss case `--force` exists to confirm. `merge-base --is-ancestor`
/// exits 0 when the tip is reachable, 1 when it is not; every other exit is
/// git's own failure.
private func refuseUnmerged(
    _ name: String,
    tip: String,
    at path: String,
    git: GitProcess,
    extraEnvironment: [String: String]
) throws {
    let probe = try git.capture(
        ["merge-base", "--is-ancestor", tip, "HEAD"],
        workingDirectory: path, extraEnvironment: extraEnvironment)
    guard probe.exitCode == 0 else {
        if probe.exitCode == 1 {
            throw RefManageError.unmergedBranch(name: name, tip: tip)
        }
        throw GitProcess.Failure.exited(
            code: probe.exitCode, stderr: probe.standardError,
            arguments: ["merge-base", "--is-ancestor", tip, "HEAD"])
    }
}

/// Resolves the upstream to the full ref name git will track: the name as
/// given when it already names a ref, else the same name under `refs/heads/`,
/// then `refs/remotes/` — the two namespaces an upstream can live in (a
/// local branch or a remote-tracking ref). `--symbolic-full-name` is what
/// returns the full ref rather than the object it points at, so the payload
/// names the ref itself (`refs/remotes/origin/main`), never a dwim'd
/// shorthand and never an oid.
private func resolveUpstream(
    _ upstream: String,
    at path: String,
    git: GitProcess,
    extraEnvironment: [String: String]
) throws -> String {
    let candidates = [upstream, "refs/heads/\(upstream)", "refs/remotes/\(upstream)"]
    for candidate in candidates {
        let output = try git.capture(
            ["rev-parse", "--verify", "--quiet", "--symbolic-full-name", candidate],
            workingDirectory: path, extraEnvironment: extraEnvironment)
        if output.exitCode == 0, let full = output.lines.first, !full.isEmpty {
            return full
        }
    }
    throw RefManageError.unknownUpstream(upstream)
}

/// Resolves one revision to a commit, typing the failure to refuse before
/// anything is touched — the same shape `Rewrite.resolve` uses.
private func resolve(
    _ revision: String,
    at path: String,
    git: GitProcess,
    extraEnvironment: [String: String]
) throws -> String {
    let output = try git.capture(
        ["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"],
        workingDirectory: path, extraEnvironment: extraEnvironment)
    guard output.exitCode == 0, let oid = output.lines.first, !oid.isEmpty else {
        throw RefManageError.unknownRevision(revision)
    }
    return oid
}
