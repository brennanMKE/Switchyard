// WorkingChanges.swift
//
// #0441: the data layer of the Detail pane's Changes view (guide §11
// decision 30). The pure pieces — the status partition, the paths an
// action hands the engine, the failure alert's text — live here so
// WorkingChangesTests reach them without a view; the loaders follow
// RepositoryLoader.swift's `@concurrent` shape.

import Foundation
import YardGit

/// `git status` split the way the Changes view lists it: what the next
/// commit will hold, what it will not, and what git refuses to commit
/// until it is resolved.
///
/// `nonisolated` for the reason `RepositorySummary` gives: a plain value
/// type in a `.defaultIsolation(MainActor.self)` target.
public nonisolated struct WorkingChanges: Equatable, Sendable {

    /// Which list a row is in.
    public enum Side: String, Sendable {
        case staged, unstaged, conflicted
    }

    /// One file on one side of the index.
    public struct Row: Equatable, Sendable, Identifiable {
        public let side: Side
        public let path: String
        /// The old name of a staged rename; `nil` otherwise.
        public let originalPath: String?
        /// The state on this row's side: `staged` for a staged row,
        /// `worktree` for an unstaged one, `.conflicted` for a conflict.
        public let state: WorktreeStatusEntry.State

        /// Side and path: an `MM` file is a row in both lists, and two rows
        /// with one id in one `List` make SwiftUI reuse the wrong row's view
        /// (measured in the VM, 2026-09-28: after Stage Hunk the staged
        /// section drew tracked.txt with its unstaged row's identifier and
        /// Stage button).
        public var id: String { "\(side.rawValue):\(path)" }

        public init(
            side: Side, path: String, originalPath: String? = nil, state: WorktreeStatusEntry.State
        ) {
            self.side = side
            self.path = path
            self.originalPath = originalPath
            self.state = state
        }

        /// The one-letter badge the row shows.
        public var badge: String {
            switch state {
            case .modified: "M"
            case .added: "A"
            case .deleted: "D"
            case .untracked: "U"
            case .typechange: "T"
            case .conflicted, .unmerged: "C"
            case .unmodified, .ignored: ""
            }
        }

        /// The badge's meaning, for its help tag and accessibility label.
        public var stateName: String {
            switch state {
            case .modified: originalPath == nil ? "modified" : "renamed"
            case .added: "added"
            case .deleted: "deleted"
            case .untracked: "untracked"
            case .typechange: "type changed"
            case .conflicted, .unmerged: "conflicted"
            case .unmodified, .ignored: ""
            }
        }
    }

    /// Changes the next commit will hold, in `git status` order.
    public let staged: [Row]
    /// Changes it will not: worktree edits and untracked files.
    public let unstaged: [Row]
    /// Unmerged paths. Neither list shows them; staging one would mark a
    /// file that may still hold conflict markers as resolved.
    public let conflicted: [Row]

    public init(staged: [Row], unstaged: [Row], conflicted: [Row]) {
        self.staged = staged
        self.unstaged = unstaged
        self.conflicted = conflicted
    }

    /// Partitions `status`. An entry with both a staged and a worktree
    /// change (`MM`) appears in both lists; an unmerged entry (the parser
    /// sets `staged` to `.conflicted` for every `u` record) only in
    /// `conflicted`.
    public init(status: WorktreeStatus) {
        var staged: [Row] = []
        var unstaged: [Row] = []
        var conflicted: [Row] = []
        for entry in status.entries {
            if entry.staged == .conflicted {
                conflicted.append(Row(side: .conflicted, path: entry.path, state: .conflicted))
                continue
            }
            if entry.staged != .unmodified {
                staged.append(Row(
                    side: .staged, path: entry.path, originalPath: entry.originalPath,
                    state: entry.staged))
            }
            if entry.worktree != .unmodified {
                unstaged.append(Row(side: .unstaged, path: entry.path, state: entry.worktree))
            }
        }
        self.init(staged: staged, unstaged: unstaged, conflicted: conflicted)
    }

    /// Nothing to show: the view reads "Working tree clean".
    public var isClean: Bool { staged.isEmpty && unstaged.isEmpty && conflicted.isEmpty }

    /// The paths `unstagePaths` needs for `rows`: each row's path, plus a
    /// rename's old path — resetting only the new name leaves the old one
    /// staged as a deletion (measured, #0439).
    public static func unstagePaths(for rows: [Row]) -> [String] {
        rows.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
    }

    /// Why Commit is disabled, or `nil` when it is enabled. The view shows
    /// the sentence as the button's help tag.
    public func commitBlockedReason(message: String) -> String? {
        if !conflicted.isEmpty { return "Resolve the conflicted files first" }
        if staged.isEmpty { return "Stage a change to commit" }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Write a commit message"
        }
        return nil
    }
}

// MARK: - #0465: Amend (guide §11 decision 33)

nonisolated extension WorkingChanges {

    /// Why the Amend button is disabled, or `nil` when it is enabled.
    /// Unlike Commit, nothing staged is fine: that is a message-only amend.
    public func amendBlockedReason(message: String) -> String? {
        if !conflicted.isEmpty { return "Resolve the conflicted files first" }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Write a commit message"
        }
        return nil
    }

    /// Why the Amend checkbox is disabled, or `nil` when it is enabled.
    /// `target` is `nil` while `loadAmendTarget` has not answered (or
    /// failed). An operation in progress comes first: git refuses to amend
    /// during a merge, and amending in the middle of a rebase, cherry-pick
    /// or revert would rewrite the commit the sequencer just made.
    public static func amendUnavailableReason(
        target: AmendHead.Target?, whereAmI: WhereAmI
    ) -> String? {
        if whereAmI.isMidMerge { return "Finish or abort the merge first" }
        if whereAmI.isMidRebase { return "Finish or abort the rebase first" }
        if whereAmI.isMidCherryPick { return "Finish or abort the cherry-pick first" }
        if whereAmI.isMidRevert { return "Finish or abort the revert first" }
        guard let target else { return "Reading the last commit…" }
        return target.refusal.map(\.description)
    }
}

/// The Changes view's message editor and Amend checkbox, one value so the
/// draft set aside while amending travels with the message (#0465). Owned
/// by `ContentView`, so it survives selecting a commit and coming back.
public nonisolated struct CommitDraft: Equatable, Sendable {
    /// What the editor shows.
    public var message: String
    /// Whether the button amends `HEAD` instead of committing.
    public private(set) var isAmending: Bool
    /// The draft set aside when Amend was turned on, put back when it is
    /// turned off.
    private var setAside: String

    public init(message: String = "") {
        self.message = message
        self.isAmending = false
        self.setAside = ""
    }

    /// Turns Amend on or off. On sets the draft aside and shows
    /// `headMessage`; off puts the draft back, discarding any edit to the
    /// amend message. Setting the current value changes nothing.
    public mutating func setAmending(_ amending: Bool, headMessage: String) {
        guard amending != isAmending else { return }
        if amending {
            setAside = message
            message = headMessage
        } else {
            message = setAside
            setAside = ""
        }
        isAmending = amending
    }

    /// What the button sends.
    public var change: WorkingChange {
        isAmending ? .amend(message: message) : .commit(message: message)
    }

    /// Why the button is disabled, or `nil`. `amendUnavailable` is
    /// `WorkingChanges.amendUnavailableReason`'s answer: amending stays
    /// blocked if the checkbox is on when `HEAD` stops being amendable (a
    /// push from the toolbar, say).
    public func blockedReason(for changes: WorkingChanges, amendUnavailable: String?) -> String? {
        guard isAmending else { return changes.commitBlockedReason(message: message) }
        return amendUnavailable ?? changes.amendBlockedReason(message: message)
    }
}

// MARK: - #0470: Discard (guide §11 decision 34)

nonisolated extension WorkingChanges {

    /// Whether `row` offers Discard: an unstaged row that is not
    /// intent-to-add (`git add -N`, badge "A" on the unstaged side), which
    /// the engine refuses because restoring it would empty the file.
    public static func canDiscard(_ row: Row) -> Bool {
        row.side == .unstaged && row.state != .added
    }

    /// What Discard All… discards: every unstaged row that `canDiscard`.
    public var discardableRows: [Row] { unstaged.filter(Self.canDiscard) }
}

/// A Discard confirmation: what the dialog says, and what its Discard
/// button sends (#0470). Every discard asks first; the dialog names what
/// goes and how to get it back.
public nonisolated struct DiscardConfirmation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let change: WorkingChange

    /// How many file names the message lists before "and N more".
    static let listedNames = 10

    /// Discarding whole files: `rows` are unstaged rows.
    public init(rows: [WorkingChanges.Row]) {
        let paths = rows.map(\.path)
        title = paths.count == 1
            ? "Discard changes to \(paths[0])?" : "Discard changes to \(paths.count) files?"
        var names = paths.prefix(Self.listedNames).joined(separator: "\n")
        if paths.count > Self.listedNames {
            names += "\nand \(paths.count - Self.listedNames) more"
        }
        let lost = rows.contains { $0.state == .untracked }
            ? "Unstaged changes are thrown away and untracked files are deleted."
            : "Unstaged changes are thrown away."
        message = names + "\n\n" + lost
            + " Staged changes stay. Edit ▸ Undo Discard brings them back."
        change = .discardFiles(paths)
    }

    /// Discarding one unstaged hunk.
    public init(hunk: Hunk) {
        title = "Discard this change to \(hunk.path)?"
        message = "The change at line \(hunk.newStart) goes back to the staged version. "
            + "Edit ▸ Undo Discard brings it back."
        change = .discardHunk(id: hunk.id)
    }
}

/// Both hunk listings the Changes view reads a file's diff from, loaded
/// together so the two sides always describe the same index.
public nonisolated struct WorkingDiffs: Equatable, Sendable {
    public let unstaged: [FileDiff]
    public let staged: [FileDiff]

    public init(unstaged: [FileDiff], staged: [FileDiff]) {
        self.unstaged = unstaged
        self.staged = staged
    }

    /// `path`'s diff on one side, or `nil` when that side lists none — an
    /// untracked file (`git diff` omits untracked files) or a path with no
    /// change on that side.
    public func file(_ path: String, staged: Bool) -> FileDiff? {
        (staged ? self.staged : unstaged).first { $0.path == path }
    }
}

/// One mutation the Changes view asks for. Each runs inside exactly one
/// journal checkpoint in the engine, so Edit ▸ Undo reverts it.
public nonisolated enum WorkingChange: Equatable, Sendable {
    case stageFiles([String])
    case unstageFiles([String])
    case stageHunk(id: String)
    case unstageHunk(id: String)
    case commit(message: String)
    /// #0465: `git commit --amend -m` (guide §11 decision 33).
    case amend(message: String)
    /// #0470: discard every unstaged change to these paths (guide §11
    /// decision 34).
    case discardFiles([String])
    /// #0470: discard one unstaged hunk.
    case discardHunk(id: String)

    /// The header's progress line while this change runs.
    public var progressLabel: String {
        switch self {
        case .stageFiles, .stageHunk: "Staging…"
        case .unstageFiles, .unstageHunk: "Unstaging…"
        case .commit: "Committing…"
        case .amend: "Amending…"
        case .discardFiles, .discardHunk: "Discarding…"
        }
    }

    /// The alert a failure presents. A git refusal shows git's own stderr —
    /// where a hook's output lands — without the argument vector
    /// `GitProcess.Failure`'s description prepends, which for a commit
    /// would repeat the whole message.
    public func failure(for error: any Error) -> CommitActionFailure {
        let title = switch self {
        case .stageFiles, .stageHunk: "Couldn’t Stage"
        case .unstageFiles, .unstageHunk: "Couldn’t Unstage"
        case .commit: "Couldn’t Commit"
        case .amend: "Couldn’t Amend"
        case .discardFiles, .discardHunk: "Couldn’t Discard"
        }
        var message = String(describing: error)
        if case let .exited(_, stderr, _) = error as? GitProcess.Failure {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty { message = detail }
        }
        // `CommitCreate.Failure` has one case, `.signingFailed`. Matched by
        // type, not by `as? any ExitClassCarrying`: that cast is pinned to
        // one site in the package (ExitClassCoverageTests, #0359).
        if error is CommitCreate.Failure {
            message += "\n\nNothing was committed. Check that your signing key or agent is available, then try again."
        }
        return CommitActionFailure(title: title, message: message)
    }
}

/// Loads both hunk listings for the Changes view. `@concurrent` for the
/// reason every loader in `RepositoryLoader.swift` carries it; the async
/// `listHunks` releases the pool thread while git runs.
@concurrent
public func loadWorkingDiffs(at path: String) async throws -> WorkingDiffs {
    let unstaged = try await listHunks(at: path, area: .unstaged)
    let staged = try await listHunks(at: path, area: .staged)
    return WorkingDiffs(unstaged: unstaged, staged: staged)
}

/// #0465: what Amend would rewrite — `HEAD`, its message, and the
/// engine's refusal. `@concurrent` because `AmendHead.target` blocks in up
/// to three `git` subprocesses.
@concurrent
public func loadAmendTarget(at path: String) async throws -> AmendHead.Target {
    try AmendHead.target(at: path)
}

/// Runs one Changes-view mutation. The engine calls are synchronous and
/// block in git subprocesses (a commit may wait on a signing prompt);
/// `@concurrent` keeps them off the main actor, as `performCommitAction`
/// does. Each engine call writes its own journal checkpoint, so this
/// writes none.
@concurrent
public func performWorkingChange(_ change: WorkingChange, at path: String) async throws {
    switch change {
    case let .stageFiles(paths):
        try stagePaths(paths, at: path)
    case let .unstageFiles(paths):
        try unstagePaths(paths, at: path)
    case let .stageHunk(id):
        try stageHunks(ids: [id], at: path)
    case let .unstageHunk(id):
        try unstageHunks(ids: [id], at: path)
    case let .commit(message):
        _ = try commitStaged(message: message, at: path)
    case let .amend(message):
        try AmendHead.run(message: message, at: path)
    case let .discardFiles(paths):
        try DiscardChanges.discardPaths(paths, at: path)
    case let .discardHunk(id):
        try DiscardChanges.discardHunks(ids: [id], at: path)
    }
}
