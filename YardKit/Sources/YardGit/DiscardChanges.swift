// DiscardChanges.swift — discard unstaged changes, journaled (#0468, #0469)

import Foundation

/// Discard: put a file's worktree back to what the index holds, or remove an
/// untracked file (guide §11 decision 34). The Changes view's Discard
/// Changes… is the caller.
///
/// **Undo needs nothing new.** Every `JournalCheckpoint` already captures
/// the whole worktree — `WorktreeSnapshot` records every tracked file's
/// bytes and mode (from a copy of the index plus `add -u`) and every
/// untracked, non-ignored file — and `JournalUndo` restores it. So a
/// discard is one `JournalCheckpoint.around(operation: "discard")`, and
/// Edit ▸ Undo Discard brings the discarded bytes back (measured for text,
/// binary, an executable bit, a symlink replaced by a file, a deleted file
/// and an untracked directory, #0468).
///
/// **Staged changes are never touched.** A tracked path goes back to its
/// *index* version (`git restore --worktree`, whose source is the index), so
/// a file with staged and unstaged edits keeps the staged ones. Throwing a
/// staged change away is Unstage, then Discard.
///
/// **Untracked paths go through `git clean -f`, never `FileManager`.**
/// Clean removes exactly the untracked, non-ignored files the snapshot
/// captured: an ignored file inside an untracked directory stays, where a
/// recursive delete would destroy it with no copy anywhere (measured).
/// `-d` is not passed: with a pathspec naming an untracked directory git
/// removes it anyway (git-clean(1); measured, `gen/` in the tests).
public enum DiscardChanges {

    /// The journal entry's operation; Edit ▸ Undo reads "Undo Discard".
    public static let operation = "discard"

    /// Why the engine will not discard a path, decided from `git status`
    /// before the checkpoint, so a refusal writes no entry and changes
    /// nothing. One refused path refuses the whole call.
    public enum Refusal: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        /// The path is unmerged; resolving it is the way through.
        case conflicted(path: String)
        /// `git add -N`: the index holds an empty placeholder, so restoring
        /// from it would empty the file (measured).
        case intentToAdd(path: String)
        /// An untracked directory holding its own repository. `git clean -f`
        /// skips it silently (exit 0) and the journal cannot capture it
        /// (`update-index` prints "Ignoring path"), so discarding it could
        /// neither happen nor be undone.
        case nestedRepository(path: String)
        /// A submodule: its changes live in its own repository.
        case submodule(path: String)
        /// The path has no unstaged change to discard — clean, staged only,
        /// or not in the repository at all.
        case noUnstagedChange(path: String)

        public var description: String {
            switch self {
            case let .conflicted(path):
                "\(path) has conflicts. Resolve them instead of discarding."
            case let .intentToAdd(path):
                "\(path) is marked intent-to-add. Unstage it first."
            case let .nestedRepository(path):
                "\(path) is another Git repository. Switchyard will not delete it."
            case let .submodule(path):
                "\(path) is a submodule. Discard its changes inside the submodule."
            case let .noUnstagedChange(path):
                "\(path) has no unstaged changes to discard."
            }
        }
    }

    /// The paths split by the git command that discards them.
    struct Plan: Equatable {
        var tracked: [String] = []
        var untracked: [String] = []
    }

    /// Splits `paths` by what `status` says each one is, refusing the first
    /// that cannot be discarded. `isRepository` answers whether an
    /// untracked directory (a path ending in `/`) holds a `.git`.
    static func plan(
        _ paths: [String], status: WorktreeStatus, isRepository: (String) -> Bool
    ) throws -> Plan {
        let byPath = Dictionary(status.entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var plan = Plan()
        for path in paths {
            guard let entry = byPath[path] else { throw Refusal.noUnstagedChange(path: path) }
            if entry.staged == .conflicted || entry.worktree == .conflicted {
                throw Refusal.conflicted(path: path)
            }
            if entry.submodule != nil { throw Refusal.submodule(path: path) }
            switch entry.worktree {
            case .untracked:
                if path.hasSuffix("/"), isRepository(path) {
                    throw Refusal.nestedRepository(path: path)
                }
                plan.untracked.append(path)
            case .added:
                throw Refusal.intentToAdd(path: path)
            case .modified, .deleted, .typechange:
                plan.tracked.append(path)
            case .unmodified, .ignored, .conflicted, .unmerged:
                throw Refusal.noUnstagedChange(path: path)
            }
        }
        return plan
    }

    /// Discards every unstaged change to `paths`: a tracked file goes back
    /// to its index version (content, mode, symlink, a deleted file comes
    /// back), an untracked file or directory is removed. `paths` are
    /// repository-relative, as `git status` prints them — an untracked
    /// directory keeps its trailing `/`.
    ///
    /// `--literal-pathspecs` for the reason `stagePaths` gives: a file named
    /// `*.txt` must not discard every `.txt` file (measured for both
    /// commands). An empty `paths` is a no-op with no entry. A refusal is
    /// thrown before the checkpoint.
    ///
    /// **Writes exactly one journal entry per call**, operation `discard`.
    public static func discardPaths(
        _ paths: [String],
        at path: String,
        git: GitProcess = GitProcess()
    ) throws {
        guard !paths.isEmpty else { return }
        let context = try WorktreeContext.resolve(path: path, git: git)
        let top = context.topLevel ?? path
        let plan = try Self.plan(
            paths, status: try gitStatus(at: path, git: git),
            isRepository: { FileManager.default.fileExists(atPath: top + "/" + $0 + ".git") })
        try JournalCheckpoint.around(operation: operation, at: path, git: git) { git in
            if !plan.tracked.isEmpty {
                try git.run(["--literal-pathspecs", "restore", "--worktree", "--"] + plan.tracked,
                            workingDirectory: top)
            }
            if !plan.untracked.isEmpty {
                try git.run(["--literal-pathspecs", "clean", "-f", "-q", "--"] + plan.untracked,
                            workingDirectory: top)
            }
        }
    }
}

// MARK: - §6 exit class (#0141)

/// Every refusal is decided before anything runs, from the repository's own
/// state — guide §6 code 6, the class `AmendHead.Refusal` carries.
extension DiscardChanges.Refusal: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
