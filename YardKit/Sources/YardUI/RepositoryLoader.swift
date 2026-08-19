// RepositoryLoader.swift

import Foundation
import YardGit

/// A repository's `whereAmI` state and worktree status, loaded together so a
/// view has one snapshot to render instead of two independently-arriving
/// values (#0339).
///
/// `nonisolated`: `YardUI`'s default isolation makes an unannotated type's
/// initialiser `@MainActor`, which the `@concurrent` loader below — running
/// off the main actor — cannot call. This is a plain immutable value type,
/// so `nonisolated` is correct regardless of the isolation default.
public nonisolated struct RepositorySummary: Sendable {
    public let whereAmI: WhereAmI
    public let status: WorktreeStatus

    public init(whereAmI: WhereAmI, status: WorktreeStatus) {
        self.whereAmI = whereAmI
        self.status = status
    }
}

/// Loads `whereAmI` and `gitStatus` for the repository at `path`.
///
/// `YardUI` sets `.defaultIsolation(MainActor.self)` (`Package.swift`), which
/// makes every unannotated declaration in this target implicitly
/// `@MainActor` — including free functions. `whereAmI(path:)` and
/// `gitStatus(at:)` both shell out to `git` synchronously
/// (`GitProcess.run`), so calling them from a `@MainActor` context blocks
/// the window. `@concurrent` forces this function onto the concurrent
/// executor regardless of the caller's isolation; callers `await` it from
/// the main actor and get control back there once it returns, so assigning
/// the result to `@State` needs no further hop.
///
/// - Throws: `WorktreeContext.Error.notARepository` when `path` is not
///   inside a git repository (#0140) — callers must show that error, not an
///   empty list (guide §9 M1 criterion 3).
@concurrent
public func loadRepositorySummary(at path: String) async throws -> RepositorySummary {
    let info = try whereAmI(path: path)
    let status = try gitStatus(at: path)
    return RepositorySummary(whereAmI: info, status: status)
}

/// Loads the most recent commits reachable from `HEAD` at `path`, for the
/// History pane (#0340).
///
/// `["-100", "HEAD"]` is a placeholder bound for paging, not a decision: an
/// unbounded `git log` on a large repository is the first thing that would
/// make this window feel broken.
///
/// `YardUI` sets `.defaultIsolation(MainActor.self)` (`Package.swift`), so
/// this needs `@concurrent` for the same reason `loadRepositorySummary`
/// above does: `CommitLog.run` shells out to `git` synchronously
/// (`GitProcess.run`), and running that on the main actor blocks the
/// window. `@concurrent` forces this function onto the concurrent executor
/// regardless of the caller's isolation; callers `await` it from the main
/// actor and get control back there once it returns.
@concurrent
public func loadCommitHistory(at path: String) async throws -> [CommitLogEntry] {
    try CommitLog.run(path: path, rangeArguments: ["-100", "HEAD"])
}

/// Loads the lane-assigned commit graph for the History pane's lane gutter
/// (#0052).
///
/// Bounded to `limit: 100` -- the same bound `loadCommitHistory` above
/// applies via `["-100", "HEAD"]` -- so the two collections cover the same
/// commits. `CommitHistoryView` joins them by `oid`; a commit with no
/// matching `GraphRow` renders without a gutter rather than crashing or
/// shifting the row, since the two calls are independent reads and are not
/// guaranteed to agree to the commit.
///
/// `YardUI` sets `.defaultIsolation(MainActor.self)` (`Package.swift`), so
/// this needs `@concurrent` for the same reason `loadRepositorySummary`,
/// `loadCommitHistory` and `loadCommitDiff` above do: `graphRows` shells out
/// to `git` synchronously (`GitProcess.run`), and running that on the main
/// actor blocks the window. `@concurrent` forces this function onto the
/// concurrent executor regardless of the caller's isolation; callers `await`
/// it from the main actor and get control back there once it returns.
///
/// `GraphRow` is declared in `YardGit`, which does not set `YardUI`'s
/// default isolation, so it is already a `nonisolated` `Sendable` value type
/// and needs no wrapper type here -- same reasoning as `loadCommitDiff`
/// above for `FileDiff`/`Hunk`.
@concurrent
public func loadCommitGraph(at path: String) async throws -> [GraphRow] {
    try graphRows(at: path, limit: 100)
}

/// Loads the diff `revision` introduced, for the Detail pane's commit view
/// (#0082).
///
/// `YardUI` sets `.defaultIsolation(MainActor.self)` (`Package.swift`), so
/// this needs `@concurrent` for the same reason `loadRepositorySummary` and
/// `loadCommitHistory` above do: `commitDiff` shells out to `git`
/// synchronously (`GitProcess.run`), and running that on the main actor
/// blocks the window. `@concurrent` forces this function onto the concurrent
/// executor regardless of the caller's isolation; callers `await` it from
/// the main actor and get control back there once it returns.
///
/// `FileDiff` and `Hunk` are declared in `YardGit`, which does not set
/// `YardUI`'s default isolation, so they are already `nonisolated`
/// `Sendable` value types and need no wrapper type here — unlike
/// `RepositorySummary` above, which is declared in this target.
///
/// Empty for a merge commit (`commitDiff`'s own documented behaviour,
/// measured #0341) — callers branch on `CommitLogEntry.parents.count > 1`
/// to show an explicit note instead of treating that as "nothing changed".
@concurrent
public func loadCommitDiff(at path: String, revision: String) async throws -> [FileDiff] {
    try commitDiff(at: path, revision: revision)
}

/// A repository's refs and worktree list, loaded together for the Sidebar
/// pane (#0081).
///
/// `nonisolated`: same reasoning as `RepositorySummary` above -- a plain
/// immutable value type declared in this target would otherwise pick up
/// `YardUI`'s `.defaultIsolation(MainActor.self)`, and `loadRepositorySidebar`
/// below, running `@concurrent`, cannot call a `@MainActor` initialiser.
///
/// `currentWorktreePath` is `WorktreeContext.topLevel` for the opened path,
/// not the raw `path` argument: both `git worktree list --porcelain`'s
/// `worktree` field and `git rev-parse --show-toplevel` report git's
/// canonicalized (`realpath(3)`-resolved) form, so comparing the two
/// directly finds the opened worktree even when the caller passed a path
/// containing a symlink. Comparing against the raw argument would miss that
/// case.
public nonisolated struct RepositorySidebarSummary: Sendable {
    public let refs: RefSnapshot
    public let worktrees: [WorktreeEntry]
    public let currentWorktreePath: String?

    public init(refs: RefSnapshot, worktrees: [WorktreeEntry], currentWorktreePath: String?) {
        self.refs = refs
        self.worktrees = worktrees
        self.currentWorktreePath = currentWorktreePath
    }
}

/// Loads the ref snapshot and worktree list for the repository at `path`, for
/// the Sidebar pane (#0081).
///
/// `YardUI` sets `.defaultIsolation(MainActor.self)` (`Package.swift`), so
/// this needs `@concurrent` for the same reason `loadRepositorySummary`,
/// `loadCommitHistory` and `loadCommitDiff` above do: `WorktreeContext.resolve`,
/// `RefSnapshot.capture` and `worktreeList` all shell out to `git`
/// synchronously (`GitProcess.run`), and running that on the main actor
/// blocks the window. `@concurrent` forces this function onto the concurrent
/// executor regardless of the caller's isolation; callers `await` it from the
/// main actor and get control back there once it returns.
///
/// `RefSnapshot.capture` already excludes `refs/switchyard/*`
/// (`RefSnapshot.switchyardNamespace`, `RefSnapshot.swift:166`) -- the
/// journal's own ref namespace never reaches this summary, and
/// `RepositorySidebarViewFixtureTests` asserts that against a real anchor
/// ref rather than trusting the filter silently.
@concurrent
public func loadRepositorySidebar(at path: String) async throws -> RepositorySidebarSummary {
    let context = try WorktreeContext.resolve(path: path)
    let refs = try RefSnapshot.capture(in: context)
    let worktrees = try worktreeList(path: path)
    return RepositorySidebarSummary(refs: refs, worktrees: worktrees, currentWorktreePath: context.topLevel)
}
