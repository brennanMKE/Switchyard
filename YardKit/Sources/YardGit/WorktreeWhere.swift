// WorktreeWhere.swift

import Foundation

/// The result of resolving the current worktree context.
public struct WorktreeWhere: Sendable, Equatable {

    /// Worktree name as git reports it — `nil` in the main worktree, `nil` also
    /// in a bare repository. Never an empty string.
    public let worktreeName: String?

    /// The path of the current worktree — `$GIT_WORK_TREE`, which is also
    /// `topLevel` from `WorktreeContext`. Nil for a bare repository.
    public let path: String?

    /// `$GIT_DIR`. Always non-empty (the main worktree's `$GIT_DIR` equals
    /// `$GIT_COMMON_DIR`, which is under `.git/`).
    public let gitDir: String

    /// `$GIT_COMMON_DIR`. The shared part of the repository state.
    public let commonDir: String

    /// Path of the main (primary) worktree, as read from
    /// `git worktree list --porcelain -z`. Nil for a bare repository. The
    /// first record in the porcelain output is by definition the main
    /// worktree, regardless of which linked worktree the command runs from.
    public let mainWorktreePath: String?

    public init(worktreeName: String?,
                path: String?,
                gitDir: String,
                commonDir: String,
                mainWorktreePath: String?) {
        self.worktreeName = worktreeName
        self.path = path
        self.gitDir = gitDir
        self.commonDir = commonDir
        self.mainWorktreePath = mainWorktreePath
    }
}

/// Resolves the current worktree's context: its name, path, `$GIT_DIR`,
/// `$GIT_COMMON_DIR`, and the main worktree's path.
public func yardWhere(path: String, git: GitProcess = GitProcess()) throws -> WorktreeWhere {
    let ctx = try WorktreeContext.resolve(path: path, git: git)

    // Pull the main worktree's path from porcelain. `-z` is required here for
    // the same reason `WorktreeList` requires it: a worktree path may itself
    // contain a newline, which would corrupt a newline-split parse. Reuse
    // `parsePorcelain` (WorktreeList.swift) rather than writing a second NUL
    // parser for the same git output — the first usable record is always the
    // primary checkout, even when resolving from a linked worktree.
    let list = try git.capture(
        ["worktree", "list", "--porcelain", "-z"],
        workingDirectory: ctx.topLevel ?? ctx.gitDir
    )
    guard list.exitCode == 0 else {
        throw WorktreeWhere.Error.couldNotListWorktrees(detail: list.standardError)
    }

    let mainPath: String? = {
        // Bare repos report the bare dir as the first (and only) worktree.
        // That is not a "main worktree" — there is no primary checkout.
        guard !ctx.isBare else { return nil }
        let entries = parsePorcelain(list.standardOutput, path: ctx.topLevel ?? ctx.gitDir)
        guard let mainEntry = entries.first(where: { $0.isMainWorktree }),
              let entryPath = mainEntry.path, !entryPath.isEmpty else {
            return nil
        }
        return WorktreeContext.canonicalize(entryPath)
    }()

    return WorktreeWhere(
        worktreeName: ctx.worktreeName,
        path: ctx.topLevel,
        gitDir: ctx.gitDir,
        commonDir: ctx.commonDir,
        mainWorktreePath: mainPath
    )
}

extension WorktreeWhere {
    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        case couldNotListWorktrees(detail: String)

        public var description: String {
            switch self {
            case let .couldNotListWorktrees(detail):
                return "could not list worktrees: \(detail)"
            }
        }
    }
}

// MARK: - Wire encoding (#0130)

/// `WorktreeWhere` is a `schemaVersion: 1` payload: it encodes through
/// `YardKit`'s `Envelope` via `EncodableResult` (`Encodable & Sendable`).
/// Plain-stdlib `Encodable` — the engine still imports nothing.
extension WorktreeWhere: Encodable {
    /// Stable wire keys, identical to the member names; no raw values. The
    /// enum is rename-safety; `WorktreeIdentityWireTests` pins the bytes.
    private enum CodingKeys: String, CodingKey {
        case worktreeName, path, gitDir, commonDir, mainWorktreePath
    }
}

// MARK: - §6 exit class (#0146)

/// An unlistable worktree set is a repository-state failure — guide §6
/// code 6.
extension WorktreeWhere.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
