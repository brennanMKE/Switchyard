// RemoteSync.swift — the app's Fetch, Pull and Push (#0452, #0453, #0454)

import Foundation

/// The app toolbar's three network operations (guide §11 decision 32).
///
/// Every one shells out to `git`. libgit2 runs no hooks and has no
/// credential helpers, and network operations are on the `git` side of the
/// hybrid boundary (`GitProcess`'s own doc). `GitProcess`'s environment
/// already forbids every prompt (`GIT_TERMINAL_PROMPT=0`, empty `GIT_ASKPASS`
/// and `SSH_ASKPASS`), so a missing credential fails with git's stderr
/// instead of waiting for input nobody can give. An app launched from
/// Finder has no controlling terminal either (measured, decision 32), so
/// `ssh` cannot fall back to `/dev/tty`.
///
/// All three are `async` and run their network step through `GitProcess`'s
/// async `run`, so cancelling the calling task terminates that child
/// (SIGTERM, then SIGKILL). Nothing else here is cancellable on purpose:
/// see `pull`.
public enum RemoteSync {

    /// A refusal decided before anything runs. No journal entry is written
    /// and no `git` network command starts.
    public enum Refusal: Error, Equatable, CustomStringConvertible, Sendable {
        /// `HEAD` is detached, so there is no current branch to pull or push.
        case detachedHead
        /// The current branch has no upstream (`branch.<name>.remote` and
        /// `branch.<name>.merge` are not both set). Pull needs one.
        case noUpstream(branch: String)
        /// The repository has no remotes at all.
        case noRemote
        /// No upstream, no remote named `origin`, and more than one remote:
        /// the first push cannot pick one without guessing.
        case ambiguousRemote([String])
        /// The upstream is a local branch (`branch.<name>.remote` is `.`),
        /// so a push would move a local branch, not publish anything.
        case localUpstream(branch: String)

        public var description: String {
            switch self {
            case .detachedHead:
                "HEAD is detached. Check out a branch first."
            case let .noUpstream(branch):
                "The branch “\(branch)” has no upstream branch to pull from."
            case .noRemote:
                "This repository has no remotes."
            case let .ambiguousRemote(names):
                "The branch has no upstream and there is no remote named “origin” "
                    + "(remotes: \(names.joined(separator: ", "))). Set an upstream with git first."
            case let .localUpstream(branch):
                "The branch “\(branch)” tracks a local branch, so there is nothing to push to."
            }
        }
    }

    // MARK: - Fetch (#0452)

    /// Fetches every remote: `git fetch --all`, journaled as one `fetch`
    /// entry written before the fetch runs.
    ///
    /// Only remote-tracking refs (and new tags) move, so Edit ▸ Undo Fetch
    /// restores the remote-tracking refs to what they were. The fetched
    /// objects stay, and the next Fetch brings the refs forward again.
    /// Refs the fetch *created* are left alone by the undo (guide §11
    /// decision 20).
    ///
    /// No `--prune`: the user's `fetch.prune` / `remote.<name>.prune`
    /// config decides, the same as `git fetch` in a terminal.
    public static func fetch(at path: String, git: GitProcess = GitProcess()) async throws {
        let context = try await WorktreeContext.resolve(path: path, git: git)
        try JournalCheckpoint.checkpoint(operation: "fetch", in: context, git: git)
        try await git.run(["fetch", "--all"], workingDirectory: path)
    }

    /// The configured remote names, as `git remote` lists them (sorted).
    /// Empty for a repository with no remotes. The toolbar reads it to
    /// decide whether Fetch, Pull and Push are available at all.
    public static func remoteNames(at path: String, git: GitProcess = GitProcess()) async throws -> [String] {
        try await git.run(["remote"], workingDirectory: path).lines.filter { !$0.isEmpty }
    }
}

// MARK: - One remote (#0529)

public extension RemoteSync {

    /// The `operation` Prune's journal entry records: Edit ▸ Undo Prune.
    static let pruneOperation = "prune"

    /// Fetch “<name>”: `git fetch -- <name>`, journaled as one `fetch`
    /// entry written before the fetch runs — `fetch(at:git:)` for one
    /// remote, so Edit ▸ Undo Fetch restores that remote's remote-tracking
    /// refs. `RemoteConfig.Refusal.unknownRemote` when no remote has the
    /// name; nothing is written then.
    static func fetch(remote name: String, at path: String, git: GitProcess = GitProcess()) async throws {
        let context = try await WorktreeContext.resolve(path: path, git: git)
        guard try await remoteNames(at: path, git: git).contains(name) else {
            throw RemoteConfig.Refusal.unknownRemote(name)
        }
        try JournalCheckpoint.checkpoint(operation: "fetch", in: context, git: git)
        try await git.run(["fetch", "--", name], workingDirectory: path)
    }

    /// Prune “<name>”: `git remote prune -- <name>`, which deletes the
    /// remote-tracking branches whose branch the remote no longer has and
    /// fetches nothing. Journaled as one `prune` entry written before it
    /// runs, so Edit ▸ Undo Prune brings the deleted refs back: they are in
    /// the entry's snapshot. It asks the remote which branches it has, so it
    /// needs the network like Fetch, and a cancel terminates it.
    static func prune(remote name: String, at path: String, git: GitProcess = GitProcess()) async throws {
        let context = try await WorktreeContext.resolve(path: path, git: git)
        guard try await remoteNames(at: path, git: git).contains(name) else {
            throw RemoteConfig.Refusal.unknownRemote(name)
        }
        try JournalCheckpoint.checkpoint(operation: pruneOperation, in: context, git: git)
        try await git.run(["remote", "prune", "--", name], workingDirectory: path)
    }
}

/// Every refusal is the repository's own state, decided before anything
/// runs: guide §6 code 6.
extension RemoteSync.Refusal: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}

// MARK: - Shared probes

extension RemoteSync {

    /// The checked-out branch's short name, or `Refusal.detachedHead`.
    static func currentBranch(at path: String, git: GitProcess) throws -> String {
        let out = try git.capture(["symbolic-ref", "-q", "--short", "HEAD"], workingDirectory: path)
        let name = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard out.exitCode == 0, !name.isEmpty else { throw Refusal.detachedHead }
        return name
    }

    /// One config value, or nil when the key is unset (`git config --get`
    /// exits 1).
    static func configValue(_ key: String, at path: String, git: GitProcess) throws -> String? {
        let out = try git.capture(["config", "--get", key], workingDirectory: path)
        guard out.exitCode == 0 else { return nil }
        let value = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func headOID(at path: String, git: GitProcess) throws -> String {
        try git.run(["rev-parse", "HEAD"], workingDirectory: path).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Pull (#0453)

public extension RemoteSync {

    /// What a pull did.
    enum PullResult: Equatable, Sendable {
        /// The branch already contained its upstream. Nothing moved.
        case upToDate
        /// The branch fast-forwarded from `from` to `to`, worktree included.
        case fastForwarded(from: String, to: String)
    }

    /// Pulls the current branch's upstream, fast-forward only: `git fetch
    /// <remote>` then `git merge --ff-only @{upstream}`, journaled as one
    /// `pull` entry written before the fetch.
    ///
    /// Not `git pull`: `pull.rebase`, `pull.ff` and `branch.<name>.rebase`
    /// would each change what it does, and a fast-forward is the one
    /// outcome that never rewrites or merges anything. A branch that has
    /// diverged from its upstream fails with git's own stderr (`fatal: Not
    /// possible to fast-forward, aborting.`) and nothing but the fetch has
    /// happened.
    ///
    /// **Only the fetch is cancellable.** The merge runs through the
    /// synchronous `GitProcess.run`, which a task cancellation does not
    /// reach, because a merge killed halfway through updating the worktree
    /// would leave it half-checked-out. A cancel that lands during the
    /// fetch stops before the merge starts.
    ///
    /// Undo Pull restores the entry: the branch, the index and the
    /// remote-tracking refs as they were before the pull.
    @discardableResult
    static func pull(at path: String, git: GitProcess = GitProcess()) async throws -> PullResult {
        let context = try await WorktreeContext.resolve(path: path, git: git)
        let remote = try upstreamRemote(at: path, git: git)

        try JournalCheckpoint.checkpoint(operation: "pull", in: context, git: git)
        try await git.run(["fetch", remote], workingDirectory: path)
        try Task.checkCancellation()

        return try fastForwardToUpstream(at: path, git: git)
    }
}

extension RemoteSync {

    /// The checked-out branch's upstream remote, or `Refusal.noUpstream`.
    static func upstreamRemote(at path: String, git: GitProcess) throws -> String {
        let branch = try currentBranch(at: path, git: git)
        guard let remote = try configValue("branch.\(branch).remote", at: path, git: git),
              try configValue("branch.\(branch).merge", at: path, git: git) != nil
        else { throw Refusal.noUpstream(branch: branch) }
        return remote
    }

    /// `git merge --ff-only @{upstream}` through the synchronous
    /// `GitProcess.run`, which task cancellation does not reach — the
    /// reason this is its own non-`async` function: inside `pull` the
    /// compiler would pick the async overload.
    static func fastForwardToUpstream(at path: String, git: GitProcess) throws -> PullResult {
        let before = try headOID(at: path, git: git)
        try git.run(["merge", "--ff-only", "@{upstream}"], workingDirectory: path)
        let after = try headOID(at: path, git: git)
        return before == after ? .upToDate : .fastForwarded(from: before, to: after)
    }
}

// MARK: - Push (#0454)

public extension RemoteSync {

    /// Where a push went.
    struct PushResult: Equatable, Sendable {
        /// The remote pushed to, e.g. `origin`.
        public let remote: String
        /// The ref updated on the remote, e.g. `refs/heads/main`.
        public let remoteRef: String
        /// True when this push also set the branch's upstream (the first
        /// push of a branch that had none).
        public let setUpstream: Bool
    }

    /// Pushes the current branch to its upstream, or — when it has none —
    /// to a branch of the same name on `origin` (or the only remote),
    /// setting the upstream (`--set-upstream`).
    ///
    /// The refspec is always explicit, `refs/heads/<branch>:<remote ref>`,
    /// so `push.default` (`matching` pushes every branch) cannot widen it.
    /// Never forced: a rejected push fails with git's stderr.
    ///
    /// **Journaled after it succeeds, not before.** A push changes the
    /// remote, which no local restore can take back, so its entry is a
    /// marker of the state *after* the push: the Edit menu reads it as
    /// "Can't Undo Push" (#0459), and restoring it changes nothing. A push
    /// that fails or is cancelled writes no entry at all, so Undo still
    /// names the operation before it.
    @discardableResult
    static func push(at path: String, git: GitProcess = GitProcess()) async throws -> PushResult {
        let context = try await WorktreeContext.resolve(path: path, git: git)
        let (result, arguments) = try pushPlan(at: path, git: git)
        try await git.run(arguments, workingDirectory: path)

        try JournalCheckpoint.checkpoint(operation: JournalUndo.pushOperation, in: context, git: git)
        return result
    }
}

extension RemoteSync {

    /// Where `push` goes and the `git push` argv that sends it there.
    static func pushPlan(at path: String, git: GitProcess) throws -> (PushResult, [String]) {
        let branch = try currentBranch(at: path, git: git)
        let result: PushResult
        if let remote = try configValue("branch.\(branch).remote", at: path, git: git),
           let merge = try configValue("branch.\(branch).merge", at: path, git: git) {
            guard remote != "." else { throw Refusal.localUpstream(branch: branch) }
            result = PushResult(remote: remote, remoteRef: merge, setUpstream: false)
        } else {
            let remote = try defaultRemote(at: path, git: git)
            result = PushResult(remote: remote, remoteRef: "refs/heads/\(branch)", setUpstream: true)
        }
        var arguments = ["push"]
        if result.setUpstream { arguments.append("--set-upstream") }
        arguments += [result.remote, "refs/heads/\(branch):\(result.remoteRef)"]
        return (result, arguments)
    }

    /// `origin` when it exists, else the only remote; a refusal otherwise.
    static func defaultRemote(at path: String, git: GitProcess) throws -> String {
        let names = try git.run(["remote"], workingDirectory: path).lines.filter { !$0.isEmpty }
        if names.contains("origin") { return "origin" }
        if names.count == 1 { return names[0] }
        if names.isEmpty { throw Refusal.noRemote }
        throw Refusal.ambiguousRemote(names)
    }
}

// MARK: - Synchronous twins (guide §11 decision 37)

/// The CLI's `fetch`, `pull` and `push` arms run inside `runEngineCommand`,
/// which is synchronous, so each operation has a synchronous twin, as
/// `Stash.list` has an async one. Same probes, same journal entries, same
/// refusals; the only difference is that nothing here is cancellable — a
/// CLI caller has no Cancel button, and interrupting the CLI does not stop
/// the app's work.
public extension RemoteSync {

    /// Synchronous twin of `fetch(at:git:) async`.
    static func fetch(at path: String, git: GitProcess = GitProcess()) throws {
        let context = try WorktreeContext.resolve(path: path, git: git)
        try JournalCheckpoint.checkpoint(operation: "fetch", in: context, git: git)
        try git.run(["fetch", "--all"], workingDirectory: path)
    }

    /// Synchronous twin of `fetch(remote:at:git:) async` (guide §11
    /// decision 43): one remote, one `fetch` entry written first.
    static func fetch(remote name: String, at path: String, git: GitProcess = GitProcess()) throws {
        let context = try WorktreeContext.resolve(path: path, git: git)
        guard try RemoteConfig.names(at: path, git: git).contains(name) else {
            throw RemoteConfig.Refusal.unknownRemote(name)
        }
        try JournalCheckpoint.checkpoint(operation: "fetch", in: context, git: git)
        try git.run(["fetch", "--", name], workingDirectory: path)
    }

    /// Synchronous twin of `prune(remote:at:git:) async` (guide §11
    /// decision 43): one `prune` entry written first, so undo brings the
    /// pruned remote-tracking branches back.
    static func prune(remote name: String, at path: String, git: GitProcess = GitProcess()) throws {
        let context = try WorktreeContext.resolve(path: path, git: git)
        guard try RemoteConfig.names(at: path, git: git).contains(name) else {
            throw RemoteConfig.Refusal.unknownRemote(name)
        }
        try JournalCheckpoint.checkpoint(operation: pruneOperation, in: context, git: git)
        try git.run(["remote", "prune", "--", name], workingDirectory: path)
    }

    /// Synchronous twin of `pull(at:git:) async`.
    @discardableResult
    static func pull(at path: String, git: GitProcess = GitProcess()) throws -> PullResult {
        let context = try WorktreeContext.resolve(path: path, git: git)
        let remote = try upstreamRemote(at: path, git: git)
        try JournalCheckpoint.checkpoint(operation: "pull", in: context, git: git)
        try git.run(["fetch", remote], workingDirectory: path)
        return try fastForwardToUpstream(at: path, git: git)
    }

    /// Synchronous twin of `push(at:git:) async`: journaled after it
    /// succeeds, never before.
    @discardableResult
    static func push(at path: String, git: GitProcess = GitProcess()) throws -> PushResult {
        let context = try WorktreeContext.resolve(path: path, git: git)
        let (result, arguments) = try pushPlan(at: path, git: git)
        try git.run(arguments, workingDirectory: path)
        try JournalCheckpoint.checkpoint(operation: JournalUndo.pushOperation, in: context, git: git)
        return result
    }
}
