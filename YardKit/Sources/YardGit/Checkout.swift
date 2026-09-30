// Checkout.swift — switch to a local branch, check out a remote branch as a
// new tracking branch, or detach at a commit; each one journal entry
// (guide §11 decision 38)

import Foundation

/// Moving `HEAD` — the three ways the app changes what is checked out. Each
/// is `git switch`, run inside one `JournalCheckpoint.around`, so Edit ▸ Undo
/// puts `HEAD`, the index and the working tree back as they were (the
/// checkpoint captures all three).
///
/// **Local changes follow `git switch`'s own rule** (decision 38): a change
/// to a file that is the same in both commits is carried across; a change
/// the switch would overwrite refuses the whole switch, and nothing is
/// touched. The refusal is decided **before** the checkpoint by the same
/// two-way merge `git switch` runs — `git read-tree -m -u -n HEAD <target>`,
/// a dry run that writes nothing (measured, git 2.54.0: it refuses exactly
/// the cases `git switch` refuses — a modified file, a staged file, an
/// untracked file in the way — and passes a change `git switch` carries).
/// `git update-index -q --refresh` runs first, because the dry run reads a
/// file whose stat data changed as modified even when its content did not
/// (measured: `touch a.txt` alone made it refuse).
public enum Checkout {

    /// The journal operation strings (display-only, #0034 decision 7).
    public static let switchOperation = "switch"
    public static let trackOperation = "switch-track"
    public static let detachOperation = "switch-detach"

    /// Why a checkout refused. Every case is raised before the journal
    /// checkpoint, so a refusal writes nothing — not even an undo entry.
    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        /// There is no `refs/heads/<name>`.
        case unknownBranch(String)
        /// There is no `refs/remotes/<name>`.
        case unknownRemoteBranch(String)
        /// The commit does not resolve.
        case unknownCommit(String)
        /// `HEAD` is already on this branch.
        case alreadyOnBranch(String)
        /// `HEAD` is already detached at this commit.
        case alreadyDetachedAt(String)
        /// A local branch with this name already exists (check out as local
        /// branch only).
        case branchExists(String)
        /// Another worktree has the branch checked out; git refuses to check
        /// one branch out twice.
        case heldByWorktree(branch: String, worktree: String)
        /// A rebase, merge, cherry-pick or revert is in progress, or the
        /// index has unresolved conflicts.
        case operationInProgress(String)
        /// Local changes to these files would be overwritten. `paths` may be
        /// empty when git named none the engine could read back.
        case localChangesWouldBeOverwritten(target: String, paths: [String])

        public var description: String {
            switch self {
            case let .unknownBranch(name):
                "unknown branch '\(name)' — there is no refs/heads/\(name); nothing was touched"
            case let .unknownRemoteBranch(name):
                "unknown remote branch '\(name)' — there is no refs/remotes/\(name); nothing was touched"
            case let .unknownCommit(revision):
                "unknown commit '\(revision)'; nothing was touched"
            case let .alreadyOnBranch(name):
                "already on '\(name)'; nothing was touched"
            case let .alreadyDetachedAt(oid):
                "HEAD is already detached at \(oid.prefix(7)); nothing was touched"
            case let .branchExists(name):
                "a branch named '\(name)' already exists; nothing was touched"
            case let .heldByWorktree(branch, worktree):
                "'\(branch)' is checked out in the worktree at \(worktree); nothing was touched"
            case let .operationInProgress(what):
                "\(what) — finish or abort it first; nothing was touched"
            case let .localChangesWouldBeOverwritten(target, paths):
                "your local changes would be overwritten by checking out '\(target)'"
                    + (paths.isEmpty ? "" : ": " + paths.joined(separator: ", "))
                    + " — commit or stash them first; nothing was touched"
            }
        }
    }

    /// Where `HEAD` ended up: its commit, and its branch (`nil` when
    /// detached).
    public struct Result: Sendable, Equatable {
        public let head: String
        public let branch: String?

        public init(head: String, branch: String?) {
            self.head = head
            self.branch = branch
        }
    }

    /// Switch: `git switch <name>`. One journal entry, operation `switch`.
    ///
    /// - Throws: `Refusal` before anything is touched; `GitProcess.Failure`
    ///   for any other git failure.
    @discardableResult
    public static func switchBranch(
        name: String, at path: String, git: GitProcess = GitProcess()
    ) throws -> Result {
        let context = try WorktreeContext.resolve(path: path, git: git)
        let top = context.topLevel ?? path
        guard let tip = try resolveRef("refs/heads/\(name)", at: top, git: git) else {
            throw Refusal.unknownBranch(name)
        }
        if try headSymref(at: top, git: git) == "refs/heads/\(name)" {
            throw Refusal.alreadyOnBranch(name)
        }
        try refuseHeld(name, context: context, at: top, git: git)
        try refuseUnsafe(target: tip, naming: name, at: top, git: git)
        return try JournalCheckpoint.around(operation: switchOperation, at: path, git: git) { git in
            try git.run(["switch", "-q", "--no-guess", name], workingDirectory: top)
            return Result(head: tip, branch: name)
        }
    }

    /// Check Out as Local Branch: `git switch --create <name> --track
    /// refs/remotes/<remoteBranch>`. `name` defaults to `remoteBranch`
    /// without its remote (`origin/feature` → `feature`). One journal entry,
    /// operation `switch-track`. Undo puts `HEAD`, the index and the working
    /// tree back and **leaves the new branch** (with its upstream config):
    /// guide §11 decision 20 — a restore deletes only refs its snapshot
    /// recorded — the same way Undo New Branch leaves the branch it made
    /// (measured).
    @discardableResult
    public static func trackRemote(
        remoteBranch: String, name: String? = nil, at path: String,
        git: GitProcess = GitProcess()
    ) throws -> Result {
        let context = try WorktreeContext.resolve(path: path, git: git)
        let top = context.topLevel ?? path
        guard let tip = try resolveRef("refs/remotes/\(remoteBranch)", at: top, git: git) else {
            throw Refusal.unknownRemoteBranch(remoteBranch)
        }
        let local = name ?? Self.localName(forRemoteBranch: remoteBranch)
        if try resolveRef("refs/heads/\(local)", at: top, git: git) != nil {
            throw Refusal.branchExists(local)
        }
        try refuseUnsafe(target: tip, naming: remoteBranch, at: top, git: git)
        return try JournalCheckpoint.around(operation: trackOperation, at: path, git: git) { git in
            try git.run(
                ["switch", "-q", "--create", local, "--track", "refs/remotes/\(remoteBranch)"],
                workingDirectory: top)
            return Result(head: tip, branch: local)
        }
    }

    /// Check Out (Detached): `git switch --detach <commit>`. One journal
    /// entry, operation `switch-detach`.
    @discardableResult
    public static func detach(
        commit: String, at path: String, git: GitProcess = GitProcess()
    ) throws -> Result {
        let context = try WorktreeContext.resolve(path: path, git: git)
        let top = context.topLevel ?? path
        guard let oid = try resolveRef("\(commit)^{commit}", at: top, git: git) else {
            throw Refusal.unknownCommit(commit)
        }
        if try headSymref(at: top, git: git) == nil,
           try resolveRef("HEAD", at: top, git: git) == oid {
            throw Refusal.alreadyDetachedAt(oid)
        }
        try refuseUnsafe(target: oid, naming: String(oid.prefix(7)), at: top, git: git)
        return try JournalCheckpoint.around(operation: detachOperation, at: path, git: git) { git in
            try git.run(["switch", "-q", "--detach", oid], workingDirectory: top)
            return Result(head: oid, branch: nil)
        }
    }

    /// `origin/feature` → `feature`; `origin/team/x` → `team/x`. A name with
    /// no `/` is returned unchanged.
    public static func localName(forRemoteBranch remoteBranch: String) -> String {
        guard let slash = remoteBranch.firstIndex(of: "/") else { return remoteBranch }
        return String(remoteBranch[remoteBranch.index(after: slash)...])
    }

    // MARK: - Guards

    private static func resolveRef(_ name: String, at top: String, git: GitProcess) throws -> String? {
        let output = try git.capture(["rev-parse", "--verify", "--quiet", name], workingDirectory: top)
        guard output.exitCode == 0, let oid = output.lines.first, !oid.isEmpty else { return nil }
        return oid
    }

    private static func headSymref(at top: String, git: GitProcess) throws -> String? {
        let output = try git.capture(["symbolic-ref", "-q", "HEAD"], workingDirectory: top)
        return output.exitCode == 0 ? output.lines.first : nil
    }

    private static func refuseHeld(
        _ name: String, context: WorktreeContext, at top: String, git: GitProcess
    ) throws {
        for entry in try worktreeList(path: top, git: git)
        where entry.branch == name && entry.path != context.topLevel {
            throw Refusal.heldByWorktree(branch: name, worktree: entry.path ?? "(unknown worktree)")
        }
    }

    /// The in-progress guard, then the dry run. `naming` is what the refusal
    /// calls the target.
    private static func refuseUnsafe(
        target: String, naming: String, at top: String, git: GitProcess
    ) throws {
        let state = try whereAmI(path: top, git: git)
        if state.isMidRebase { throw Refusal.operationInProgress("a rebase is in progress") }
        if state.isMidMerge { throw Refusal.operationInProgress("a merge is in progress") }
        if state.isMidCherryPick { throw Refusal.operationInProgress("a cherry-pick is in progress") }
        if state.isMidRevert { throw Refusal.operationInProgress("a revert is in progress") }
        if state.hasConflicts { throw Refusal.operationInProgress("there are unresolved conflicts") }
        // An unborn HEAD has nothing to merge against; git switch itself
        // decides that case.
        guard !state.headOID.isEmpty else { return }
        _ = try git.capture(["update-index", "-q", "--refresh"], workingDirectory: top)
        let dryRun = try git.capture(
            ["read-tree", "-m", "-u", "-n", "HEAD", target], workingDirectory: top)
        guard dryRun.exitCode != 0 else { return }
        throw Refusal.localChangesWouldBeOverwritten(
            target: naming, paths: try blockingPaths(target: target, at: top, git: git))
    }

    /// The files the refusal names: every path that differs between `HEAD`
    /// and the target and has a local change (staged, unstaged or
    /// untracked). The dry run above is the gate; this list is only what
    /// the message shows.
    private static func blockingPaths(target: String, at top: String, git: GitProcess) throws -> [String] {
        let differing = Set(try git.run(
            ["diff", "--name-only", "--no-renames", "-z", "HEAD", target], workingDirectory: top
        ).text.split(separator: "\0").map(String.init))
        return try gitStatus(at: top, git: git).entries
            .map(\.path)
            .filter { differing.contains($0) }
            .sorted()
    }
}

extension Checkout.Refusal: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
