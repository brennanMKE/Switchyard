// RefActions.swift
//
// #0509: the data layer behind switching branches, checking out a remote
// branch or a commit, and deleting a branch or a tag (guide §11 decision
// 38) — what each sends, when the sidebar offers it, what the header says
// while it runs, what a failure presents, and the three dialogs. Pure
// values, so RefActionsTests reach them without a view; the runner follows
// StashActions.swift's `@concurrent` shape.

import Foundation
import YardGit

/// One ref mutation the sidebar or the commit menu asks for. Each runs
/// inside exactly one journal checkpoint in the engine, so Edit ▸ Undo
/// reverts it — except `stashChanges(then:)`, which is two: the stash, then
/// the checkout.
public nonisolated indirect enum RefAction: Equatable, Sendable {
    /// Switch to a local branch (`git switch`).
    case switchBranch(name: String)
    /// Check Out as Local Branch: `origin/feature` → a new `feature`
    /// tracking it.
    case trackRemote(remoteBranch: String)
    /// Check Out (Detached) at a commit.
    case detach(commit: String)
    /// Delete Branch…; `force` only after the unmerged confirmation.
    case deleteBranch(name: String, force: Bool)
    /// Delete Tag….
    case deleteTag(name: String)
    /// The dirty-tree alert's Stash Changes and Switch: stash everything,
    /// untracked files included, then run the checkout.
    case stashChanges(then: RefAction)

    /// The header's progress line while this action runs.
    public var progressLabel: String {
        switch self {
        case let .switchBranch(name): "Switching to “\(name)”…"
        case let .trackRemote(remoteBranch): "Checking out “\(remoteBranch)”…"
        case .detach: "Checking out commit…"
        case .deleteBranch: "Deleting branch…"
        case .deleteTag: "Deleting tag…"
        case .stashChanges: "Stashing changes…"
        }
    }

    /// What the checkout is called in the dirty-tree alert and the stash
    /// message: the branch, the remote branch, or the short commit. `nil`
    /// for the deletions, which never need a stash.
    public var checkoutTarget: String? {
        switch self {
        case let .switchBranch(name): name
        case let .trackRemote(remoteBranch): remoteBranch
        case let .detach(commit): String(commit.prefix(7))
        case .deleteBranch, .deleteTag: nil
        case let .stashChanges(then): then.checkoutTarget
        }
    }

    /// The alert a failure presents: the engine's refusal sentence, or
    /// git's own stderr without the argument vector.
    public func failure(for error: any Error) -> CommitActionFailure {
        let title = switch self {
        case .switchBranch: "Couldn’t Switch Branch"
        case .trackRemote: "Couldn’t Check Out Branch"
        case .detach: "Couldn’t Check Out Commit"
        case .deleteBranch: "Couldn’t Delete Branch"
        case .deleteTag: "Couldn’t Delete Tag"
        case .stashChanges: "Couldn’t Stash Changes"
        }
        var message = String(describing: error)
        if case let .exited(_, stderr, _) = error as? GitProcess.Failure {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty { message = detail }
        }
        return CommitActionFailure(title: title, message: message)
    }
}

/// What the sidebar's ref rules need to know about the repository.
public nonisolated struct RefActionContext: Equatable, Sendable {
    /// The checked-out branch's short name; `nil` when detached.
    public let currentBranch: String?
    /// Branches other worktrees have checked out → that worktree's path.
    public let heldElsewhere: [String: String]
    /// Every local branch's short name.
    public let localBranches: Set<String>
    /// `TrackingSummary.operationInProgress`'s sentence, when one applies.
    public let operationInProgress: String?
    public let isBusy: Bool

    public init(
        currentBranch: String?, heldElsewhere: [String: String], localBranches: Set<String>,
        operationInProgress: String?, isBusy: Bool
    ) {
        self.currentBranch = currentBranch
        self.heldElsewhere = heldElsewhere
        self.localBranches = localBranches
        self.operationInProgress = operationInProgress
        self.isBusy = isBusy
    }

    public static func make(
        summary: RepositorySidebarSummary, whereAmI: WhereAmI?, isBusy: Bool
    ) -> RefActionContext {
        var held: [String: String] = [:]
        for entry in summary.worktrees
        where entry.path != summary.currentWorktreePath {
            if let branch = entry.branch { held[branch] = entry.path ?? "another worktree" }
        }
        let heads = "refs/heads/"
        let current: String? = if case let .symbolic(target) = summary.refs.head,
                                  target.hasPrefix(heads) {
            String(target.dropFirst(heads.count))
        } else {
            nil
        }
        return RefActionContext(
            currentBranch: current,
            heldElsewhere: held,
            localBranches: Set(summary.refs.refs.compactMap {
                $0.name.hasPrefix(heads) ? String($0.name.dropFirst(heads.count)) : nil
            }),
            operationInProgress: whereAmI.flatMap(TrackingSummary.operationInProgress(for:)),
            isBusy: isBusy)
    }
}

/// When each sidebar item is available: `nil`, or the reason it is not.
/// The checks mirror the engine's refusals, so a disabled item says what
/// the engine would have said.
public nonisolated enum RefActionRules {
    public static func switchReason(branch: String, _ c: RefActionContext) -> String? {
        if let reason = checkoutGuard(c) { return reason }
        if branch == c.currentBranch { return "Already on “\(branch)”" }
        if let worktree = c.heldElsewhere[branch] { return "Checked out in \(worktree)" }
        return nil
    }

    /// `remoteBranch` is the short remote name, `origin/feature`.
    public static func trackReason(remoteBranch: String, _ c: RefActionContext) -> String? {
        if let reason = checkoutGuard(c) { return reason }
        if remoteBranch.hasSuffix("/HEAD") { return "This names the remote’s default branch" }
        let local = Checkout.localName(forRemoteBranch: remoteBranch)
        if c.localBranches.contains(local) { return "A local branch “\(local)” already exists" }
        return nil
    }

    public static func deleteBranchReason(branch: String, _ c: RefActionContext) -> String? {
        if c.isBusy { return "Another operation is still running" }
        if branch == c.currentBranch { return "You can’t delete the branch you’re on" }
        if let worktree = c.heldElsewhere[branch] { return "Checked out in \(worktree)" }
        return nil
    }

    public static func deleteTagReason(_ c: RefActionContext) -> String? {
        c.isBusy ? "Another operation is still running" : nil
    }

    private static func checkoutGuard(_ c: RefActionContext) -> String? {
        if c.isBusy { return "Another operation is still running" }
        if let operation = c.operationInProgress { return "\(operation) — finish or abort it first" }
        return nil
    }
}

/// A Delete Branch… or Delete Tag… confirmation, and the second one an
/// unmerged branch needs. Undo brings each back, and every dialog says so.
public nonisolated struct RefDeleteConfirmation: Equatable, Sendable, Identifiable {
    public let title: String
    public let message: String
    /// The destructive button's title.
    public let confirmTitle: String
    public let action: RefAction
    public var id: String { title }

    /// The first dialog: the engine decides whether the branch is merged
    /// (its tip reachable from HEAD), so this never forces.
    public static func branch(_ name: String) -> RefDeleteConfirmation {
        RefDeleteConfirmation(
            title: "Delete branch “\(name)”?",
            message: "Its commits stay in the history of any branch that contains them. "
                + "Edit ▸ Undo Delete Branch brings it back.",
            confirmTitle: "Delete Branch",
            action: .deleteBranch(name: name, force: false))
    }

    /// The second dialog, after the engine refused an unmerged branch.
    public static func unmergedBranch(_ name: String) -> RefDeleteConfirmation {
        RefDeleteConfirmation(
            title: "“\(name)” is not merged into the current branch",
            message: "Deleting it takes its unmerged commits off every branch. "
                + "Edit ▸ Undo Delete Branch brings it back.",
            confirmTitle: "Delete Unmerged Branch",
            action: .deleteBranch(name: name, force: true))
    }

    public static func tag(_ name: String) -> RefDeleteConfirmation {
        RefDeleteConfirmation(
            title: "Delete tag “\(name)”?",
            message: "Edit ▸ Undo Delete Tag brings it back.",
            confirmTitle: "Delete Tag",
            action: .deleteTag(name: name))
    }

    public init(title: String, message: String, confirmTitle: String, action: RefAction) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.action = action
    }
}

/// The dirty-tree alert: the checkout was refused because it would
/// overwrite local changes (decision 38). Offers Stash Changes and Switch.
public nonisolated struct CheckoutBlocked: Equatable, Sendable, Identifiable {
    public let title: String
    public let message: String
    /// What Stash Changes and Switch runs.
    public let retry: RefAction
    public var id: String { title }

    /// `nil` unless `error` is the engine's overwrite refusal for an
    /// action that is a checkout.
    public init?(action: RefAction, error: any Error) {
        guard case let .localChangesWouldBeOverwritten(target, paths)? = error as? Checkout.Refusal,
              action.checkoutTarget != nil
        else { return nil }
        title = "Your changes would be overwritten by checking out “\(target)”"
        let files = switch paths.count {
        case 0: "Some files"
        case 1: paths[0]
        case 2...4: paths.joined(separator: ", ")
        default: paths.prefix(3).joined(separator: ", ") + " and \(paths.count - 3) more"
        }
        message = "\(files) would be overwritten. Stash your changes first — "
            + "they are kept in the Stashes list, and Edit ▸ Undo takes back each step."
        retry = .stashChanges(then: action)
    }
}

/// Runs one ref action. The engine calls are synchronous and block in git
/// subprocesses; `@concurrent` keeps them off the main actor, as
/// `performStashAction` does. Each engine call writes its own journal
/// checkpoint, so this writes none.
@concurrent
public func performRefAction(_ action: RefAction, at path: String) async throws {
    switch action {
    case let .switchBranch(name):
        try Checkout.switchBranch(name: name, at: path)
    case let .trackRemote(remoteBranch):
        try Checkout.trackRemote(remoteBranch: remoteBranch, at: path)
    case let .detach(commit):
        try Checkout.detach(commit: commit, at: path)
    case let .deleteBranch(name, force):
        _ = try Branch.delete(name: name, force: force, at: path)
    case let .deleteTag(name):
        try Tag.delete(name: name, at: path)
    case let .stashChanges(then):
        try Stash.push(
            message: "Before checking out \(then.checkoutTarget ?? "")",
            includeUntracked: true, at: path)
        try await performRefAction(then, at: path)
    }
}
