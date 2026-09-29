// Stash.swift — list, push, apply, pop and drop stashes, journaled (#0491, #0492)

import Foundation

/// The stash, as the sidebar lists it and the Changes view and the stash
/// detail pane change it (guide §11 decision 36).
///
/// **Every mutation is one journal entry.** `push`, `apply`, `pop` and
/// `drop` each run inside one `JournalCheckpoint.around`, and every
/// checkpoint captures the stash list itself (`StashSnapshot`, #0490), so
/// Edit ▸ Undo puts back the worktree, the index *and* the list: Undo Drop
/// brings the dropped entry back with its message, Undo Stash Changes
/// puts the changes back and removes the stash.
///
/// **Always `git stash`, never plumbing.** git's own `stash push` and
/// `stash apply` handle untracked files, the index commit and the merge a
/// moved `HEAD` needs; nothing here reimplements them. A stash is named by
/// its commit oid, not by `stash@{n}`: the index is looked up from the oid
/// at the moment of the call, so a list that moved since the caller read
/// it refuses (`Refusal.notFound`) rather than acting on a neighbour.
public enum Stash {

    /// The journal operations; Edit ▸ Undo reads "Undo Stash Changes",
    /// "Undo Apply Stash", "Undo Pop Stash" and "Undo Drop Stash". Not
    /// `"drop"`, which is Delete Commit's (`JournalMenuTitles`).
    public static let pushOperation = "stash"
    public static let applyOperation = "stash-apply"
    public static let popOperation = "stash-pop"
    public static let dropOperation = "stash-drop"

    /// One stash entry as the sidebar lists it.
    public struct Item: Sendable, Equatable, Identifiable {
        /// Its position: `stash@{index}`.
        public let index: Int
        /// The stash commit.
        public let oid: String
        /// The commit it was made on (the stash commit's first parent).
        public let baseOID: String
        /// Whether it holds untracked files (a third parent).
        public let includesUntracked: Bool
        /// The stash commit's committer date, Unix seconds. Not the reflog
        /// date, which a journal restore rewrites (`StashSnapshot`).
        public let date: Int
        /// The reflog message: `On main: <message>`, or `WIP on main:
        /// <short oid> <subject>` with no message.
        public let message: String

        public var id: String { oid }
        /// `stash@{n}`, what git calls it.
        public var name: String { "stash@{\(index)}" }

        public init(index: Int, oid: String, baseOID: String, includesUntracked: Bool,
                    date: Int, message: String) {
            self.index = index
            self.oid = oid
            self.baseOID = baseOID
            self.includesUntracked = includesUntracked
            self.date = date
            self.message = message
        }
    }

    /// Why the engine will not run a stash command, decided before the
    /// checkpoint, so a refusal writes no entry and changes nothing.
    public enum Refusal: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        /// The branch has no commits. `git stash` needs `HEAD`: "You do not
        /// have the initial commit yet", exit 1 (measured).
        case noCommits
        /// Nothing a stash would save. `git stash push` prints "No local
        /// changes to save" and exits **0** (measured), which would leave a
        /// journal entry for nothing.
        case nothingToStash
        /// The index has unmerged paths. `stash push` and `stash apply` both
        /// fail with "could not write index" / "needs merge" (measured).
        case conflicted
        /// `git add -N`: `stash push` fails with "Entry '<path>' not
        /// uptodate. Cannot merge." (measured).
        case intentToAdd(path: String)
        /// No stash has this oid any more.
        case notFound(oid: String)

        public var description: String {
            switch self {
            case .noCommits:
                "There is nothing to stash on a branch with no commits."
            case .nothingToStash:
                "There are no changes to stash."
            case .conflicted:
                "Resolve the conflicted files first."
            case let .intentToAdd(path):
                "\(path) is marked intent-to-add. Stage or unstage it first."
            case let .notFound(oid):
                "The stash \(oid.prefix(7)) is no longer in the stash list."
            }
        }
    }

    // MARK: - List

    /// Every stash, `stash@{0}` first. Empty when there is none: `git stash
    /// list` prints nothing, exit 0, without `refs/stash` (measured).
    /// `%P` gives the stash commit's parents — base, index, and the
    /// untracked commit when `-u` made one.
    public static func list(at path: String, git: GitProcess = GitProcess()) throws -> [Item] {
        try parseList(git.run(listArguments, workingDirectory: path).text)
    }

    /// Async twin of `list(at:git:)`, for the sidebar's `@concurrent` load.
    public static func list(at path: String, git: GitProcess = GitProcess()) async throws -> [Item] {
        try parseList(await git.run(listArguments, workingDirectory: path).text)
    }

    static let listArguments = [
        "stash", "list", "--no-show-signature", "--format=%H%x00%P%x00%ct%x00%gs",
    ]

    static func parseList(_ text: String) throws -> [Item] {
        var items: [Item] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\0", maxSplits: 3, omittingEmptySubsequences: false)
            let parents = fields.count == 4 ? fields[1].split(separator: " ") : []
            guard fields.count == 4, parents.count >= 2, let date = Int(fields[2]) else {
                throw StashSnapshot.Error.malformedLine(String(line))
            }
            items.append(Item(
                index: items.count, oid: String(fields[0]), baseOID: String(parents[0]),
                includesUntracked: parents.count >= 3, date: date, message: String(fields[3])))
        }
        return items
    }

    // MARK: - Push

    /// Stash Changes: `git stash push`, with `--include-untracked` when
    /// `includeUntracked`, and `-m message` when the message is not blank.
    /// Staged and unstaged changes are both saved and the working tree and
    /// index go back to `HEAD`, as git does. Works on a detached `HEAD`
    /// (git names the branch `(no branch)`, measured).
    ///
    /// **Writes exactly one journal entry**, operation `stash`.
    public static func push(
        message: String?,
        includeUntracked: Bool,
        at path: String,
        git: GitProcess = GitProcess()
    ) throws {
        let context = try WorktreeContext.resolve(path: path, git: git)
        let top = context.topLevel ?? path
        guard try git.capture(["rev-parse", "--verify", "-q", "HEAD"],
                              workingDirectory: top).exitCode == 0
        else { throw Refusal.noCommits }
        let status = try gitStatus(at: top, git: git)
        try refuseConflicts(in: status)
        if let ita = status.entries.first(where: { $0.worktree == .added && $0.staged == .unmodified }) {
            throw Refusal.intentToAdd(path: ita.path)
        }
        let tracked = status.entries.contains { $0.worktree != .untracked }
        let untracked = status.entries.contains { $0.worktree == .untracked }
        guard tracked || (includeUntracked && untracked) else { throw Refusal.nothingToStash }

        var arguments = ["stash", "push", "-q"]
        if includeUntracked { arguments.append("--include-untracked") }
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["-m", message]
        }
        try JournalCheckpoint.around(operation: pushOperation, at: path, git: git) { git in
            _ = try git.run(arguments, workingDirectory: top)
        }
    }

    private static func refuseConflicts(in status: WorktreeStatus) throws {
        if status.entries.contains(where: { $0.staged == .conflicted }) {
            throw Refusal.conflicted
        }
    }
}

// MARK: - §6 exit class (#0141)

/// Every refusal is decided before anything runs, from the repository's own
/// state — guide §6 code 6, the class `DiscardChanges.Refusal` carries.
extension Stash.Refusal: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
