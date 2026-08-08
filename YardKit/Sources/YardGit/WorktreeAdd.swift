// WorktreeAdd.swift — engine behind `switchyard wt new` (#0021)

import Foundation

/// What the new worktree checks out.
public enum WorktreeAddTarget: Sendable, Equatable {
    /// Create a branch (`-b <name>`), optionally at a named start point.
    /// A nil `from` starts at the current `HEAD`, exactly as git does.
    case newBranch(name: String, from: String? = nil)
    /// Check out an existing branch. Git refuses when a sibling worktree
    /// already has it checked out — that refusal is surfaced as
    /// `WorktreeAddError.branchInUse`, naming the holder.
    case branch(String)
    /// Detached `HEAD` at a committish (`--detach <committish>`).
    case detached(at: String)
}

/// Result of a worktree creation attempt. Failures the engine understands are
/// carried in `error` rather than thrown, so a caller can render a structured
/// refusal; only transport-level problems (git unlaunchable) throw.
public struct WorktreeAddResult: Sendable {

    /// Canonicalized absolute path of the new worktree. On failure, the
    /// canonicalized form of the path that was requested.
    public let worktreePath: String

    /// Short branch name checked out in the new worktree. Nil when detached
    /// or on failure.
    public let branch: String?

    /// `HEAD` oid of the new worktree after creation. Nil on failure.
    public let head: String?

    /// The lock reason written when an agent id was given —
    /// `switchyard-agent:session=<id>` — nil otherwise.
    public let lockReason: String?

    /// The structured reason the creation was refused, nil on success.
    public let error: WorktreeAddError?

    /// True when the worktree was created.
    public var success: Bool { error == nil }

    public init(worktreePath: String,
                branch: String? = nil,
                head: String? = nil,
                lockReason: String? = nil,
                error: WorktreeAddError? = nil) {
        self.worktreePath = worktreePath
        self.branch = branch
        self.head = head
        self.lockReason = lockReason
        self.error = error
    }
}

/// Structured refusals from `git worktree add`, classified from measured
/// stderr shapes (git 2.50.1). Anything unrecognized lands in
/// `unknownFailure` with git's stderr intact.
public enum WorktreeAddError: Error, Equatable, CustomStringConvertible, Sendable {

    /// The branch is checked out in another worktree. `holderPath` is the
    /// canonicalized path of the worktree that has it (from `worktreeList`),
    /// nil only when the holder could not be identified.
    case branchInUse(branch: String, holderPath: String?, holderIsMainWorktree: Bool)

    /// `-b <name>` named a branch that already exists.
    case branchExists(String)

    /// `-b <name>` named something that is not a valid ref name.
    case invalidBranchName(String)

    /// The target directory already exists and is not empty.
    case pathExists(String)

    /// The start point or committish did not resolve.
    case invalidReference(String)

    /// `git worktree add` failed in a way the engine does not classify.
    case unknownFailure(code: Int32, stderr: String)

    /// Stable machine-readable code for JSON output.
    public var code: String {
        switch self {
        case .branchInUse: "branchInUse"
        case .branchExists: "branchExists"
        case .invalidBranchName: "invalidBranchName"
        case .pathExists: "pathExists"
        case .invalidReference: "invalidReference"
        case .unknownFailure: "failure"
        }
    }

    public var description: String {
        switch self {
        case let .branchInUse(branch, holderPath, isMain):
            let holder = holderPath.map { " at \($0)" } ?? ""
            let kind = isMain ? "the main worktree" : "another worktree"
            return "branch '\(branch)' is already checked out in \(kind)\(holder)"
        case let .branchExists(name):
            return "a branch named '\(name)' already exists"
        case let .invalidBranchName(name):
            return "'\(name)' is not a valid branch name"
        case let .pathExists(path):
            return "'\(path)' already exists"
        case let .invalidReference(ref):
            return "invalid reference: \(ref)"
        case let .unknownFailure(code, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "git worktree add exited \(code)" + (detail.isEmpty ? "" : ": \(detail)")
        }
    }
}

/// Creates a linked worktree for the repository at `repositoryPath`.
///
/// The agent id, when given, locks the worktree **atomically at creation**
/// via `git worktree add --lock --reason` — there is no window in which the
/// worktree exists unlocked — with the reason
/// `switchyard-agent:session=<id>`, the prefix guide §11 decision 9 fixes
/// and `WorktreePrune` already recognizes. `--force` is never passed, under
/// any input: the refusals git makes are the product, not an obstacle.
///
/// `populate: false` maps to `--no-checkout` and leaves the working tree
/// empty except for `.git`; the sparse-checkout path (#0128) builds on it.
public func worktreeAdd(
    at repositoryPath: String,
    path: String,
    target: WorktreeAddTarget,
    agentID: String? = nil,
    populate: Bool = true,
    git: GitProcess = GitProcess()
) throws -> WorktreeAddResult {
    let requested = WorktreeContext.canonicalize(path)
    let arguments = worktreeAddArguments(
        path: path, target: target, agentID: agentID, populate: populate)

    let outcome = try git.capture(arguments, workingDirectory: repositoryPath)
    guard outcome.exitCode == 0 else {
        var error = classifyWorktreeAddFailure(
            exitCode: outcome.exitCode, stderr: outcome.standardError)
        // Enrich the in-use refusal with the holder, structurally, from
        // porcelain rather than by parsing a path out of prose.
        if case let .branchInUse(branch, _, _) = error {
            let holder = try? siblingWorktree(holding: branch, at: repositoryPath, git: git)
            error = .branchInUse(
                branch: branch,
                holderPath: holder?.path,
                holderIsMainWorktree: holder?.isMainWorktree ?? false)
        }
        return WorktreeAddResult(worktreePath: requested, error: error)
    }

    let branchName: String?
    switch target {
    case let .newBranch(name, _): branchName = name
    case let .branch(name):
        branchName = name.hasPrefix("refs/heads/")
            ? String(name.dropFirst("refs/heads/".count)) : name
    case .detached: branchName = nil
    }

    // HEAD is set even for --no-checkout; ask the new worktree itself.
    let head = try? git.run(["rev-parse", "HEAD"], workingDirectory: requested)
        .lines.first

    return WorktreeAddResult(
        worktreePath: requested,
        branch: branchName,
        head: head,
        lockReason: agentID.map(agentLockReason))
}

/// The lock reason written for an agent session: the settled
/// `switchyard-agent:` prefix (guide §11 decision 9, the constant
/// `WorktreePrune` filters on) plus `session=<id>`.
func agentLockReason(_ agentID: String) -> String {
    WorktreePrune.agentLockReasonPrefix + "session=\(agentID)"
}

/// Builds the `git worktree add` argument vector. Pure, so tests can pin the
/// two contracts that matter: `--force` is never present, and an agent id
/// always arrives as `--lock --reason switchyard-agent:session=<id>`.
func worktreeAddArguments(
    path: String,
    target: WorktreeAddTarget,
    agentID: String?,
    populate: Bool
) -> [String] {
    var arguments = ["worktree", "add"]
    if !populate { arguments.append("--no-checkout") }
    if let agentID {
        arguments += ["--lock", "--reason", agentLockReason(agentID)]
    }
    switch target {
    case let .newBranch(name, from):
        arguments += ["-b", name, path]
        if let from { arguments.append(from) }
    case let .branch(name):
        arguments += [path, name]
    case let .detached(committish):
        arguments += ["--detach", path, committish]
    }
    return arguments
}

/// Classifies a failed `git worktree add` from its stderr. Every recognized
/// shape below was measured on git 2.50.1. Matching is on the first `fatal:`
/// line: git's progress line (`Preparing worktree (…)`) also arrives on
/// stderr ahead of it, and `hint:` lines can follow it.
func classifyWorktreeAddFailure(exitCode: Int32, stderr: String) -> WorktreeAddError {
    let first = stderr
        .split(separator: "\n", omittingEmptySubsequences: true)
        .first(where: { $0.hasPrefix("fatal: ") })
        .map(String.init) ?? ""

    func quoted(after prefix: String, before suffix: String) -> String? {
        guard first.hasPrefix(prefix), first.hasSuffix(suffix) else { return nil }
        return String(first.dropFirst(prefix.count).dropLast(suffix.count))
    }

    // fatal: 'feature' is already used by worktree at '/path/to/holder'
    if first.hasPrefix("fatal: '"), first.contains("' is already used by worktree at '") {
        let tail = first.dropFirst("fatal: '".count)
        if let end = tail.range(of: "' is already used by worktree at '") {
            return .branchInUse(
                branch: String(tail[..<end.lowerBound]),
                holderPath: nil,
                holderIsMainWorktree: false)
        }
    }
    // fatal: a branch named 'feature' already exists
    if let name = quoted(after: "fatal: a branch named '", before: "' already exists") {
        return .branchExists(name)
    }
    // fatal: 'bad..name' is not a valid branch name
    if let name = quoted(after: "fatal: '", before: "' is not a valid branch name") {
        return .invalidBranchName(name)
    }
    // fatal: '../somewhere' already exists
    if let path = quoted(after: "fatal: '", before: "' already exists") {
        return .pathExists(path)
    }
    // fatal: invalid reference: deadbeef
    if first.hasPrefix("fatal: invalid reference: ") {
        return .invalidReference(String(first.dropFirst("fatal: invalid reference: ".count)))
    }
    return .unknownFailure(code: exitCode, stderr: stderr)
}
