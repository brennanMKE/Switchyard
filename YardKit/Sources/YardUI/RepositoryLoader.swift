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
