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
