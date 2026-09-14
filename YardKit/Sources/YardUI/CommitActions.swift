// CommitActions.swift
//
// #0359: the commit-node actions, their menu titles and shortcuts, when each
// is available, what gets selected afterwards, and the engine request each
// dispatches to. Pure and `nonisolated`, so every rule is reachable from
// `swift test`; the views only render `CommitActionState`s and call back
// with a `CommitAction`.
//
// The disabled reasons mirror the engines' typed refusals (guide §6): a
// merge node, the tip position, a target off the branch, an in-progress
// operation. Where the engine has no typed refusal — a merge above the
// commit breaking the cherry-pick replay, measured in
// `rewordBelowAMergeFailsTheReplayAndTouchesNothing` — the rule names the
// measured git behaviour instead of letting the user reach its error.

import SwiftUI
import YardGit

/// One action the History row's context menu (and the menu bar's Commit
/// menu) offers for a commit node. Every case maps to an existing engine
/// call — nothing here reimplements git.
public nonisolated enum CommitAction: String, CaseIterable, Sendable {
    case editMessage
    case fixupIntoParent
    case squashIntoParent
    case split
    case swapWithParent
    case swapWithChild
    case delete
    case revert
    case cherryPick
    case merge
    case rebaseOnto
    case setBranchTip
    case addTag
    case createBranch
    case editLocalBranch

    /// Menu title. An ellipsis marks exactly the actions that ask for more
    /// input or a confirmation before they run (HIG).
    public var title: String { title(branchName: nil) }

    /// The branch-aware titles: the tip-setter names the branch it would
    /// move (#0362's wording), so the menu says which history is at stake.
    public func title(branchName: String?) -> String {
        switch self {
        case .editMessage: "Edit Message…"
        case .fixupIntoParent: "Fixup with Parent"
        case .squashIntoParent: "Squash with Parent…"
        case .split: "Split…"
        case .swapWithParent: "Swap with Parent"
        case .swapWithChild: "Swap with Child"
        case .delete: "Delete Commit…"
        case .revert: "Revert"
        case .cherryPick: "Cherry-Pick"
        case .merge: "Merge into Current Branch"
        case .rebaseOnto: "Rebase onto Here"
        case .setBranchTip:
            branchName.map { "Set “\($0)” Tip Here…" } ?? "Set Branch Tip Here…"
        case .addTag: "Add Tag…"
        case .createBranch: "Create Branch…"
        case .editLocalBranch: "Edit Local Branch…"
        }
    }

    /// Key equivalent, shown in both menus. `nil` where no shortcut was
    /// allocated (#0362: Set Branch Tip is deliberately unshortened).
    ///
    /// These register on the context-menu buttons as well; whether a
    /// context-menu key equivalent fires while the menu is closed is
    /// #0382's spike, so the app also carries the menu bar's Commit menu —
    /// the form guaranteed to fire. ⌥⌘↑/↓ reaching the menu with the list
    /// focused is #0383's spike, likewise noted, not settled.
    public var shortcut: KeyboardShortcut? {
        switch self {
        case .editMessage: KeyboardShortcut("e", modifiers: [.command, .option])
        case .fixupIntoParent: KeyboardShortcut("f", modifiers: [.command, .option])
        case .squashIntoParent: KeyboardShortcut("f", modifiers: [.command, .option, .shift])
        case .split: KeyboardShortcut("s", modifiers: [.command, .option])
        case .swapWithParent: KeyboardShortcut(.downArrow, modifiers: [.command, .option])
        case .swapWithChild: KeyboardShortcut(.upArrow, modifiers: [.command, .option])
        case .delete: KeyboardShortcut(.delete, modifiers: .command)
        case .revert: KeyboardShortcut("r", modifiers: [.command, .option])
        case .cherryPick: KeyboardShortcut("c", modifiers: [.command, .option])
        case .merge: KeyboardShortcut("m", modifiers: [.command, .shift])
        case .rebaseOnto: KeyboardShortcut("r", modifiers: [.command, .shift])
        case .setBranchTip, .editLocalBranch: nil
        case .addTag: KeyboardShortcut("t", modifiers: [.command, .shift])
        case .createBranch: KeyboardShortcut("b", modifiers: [.command, .shift])
        }
    }

    /// The header line shown while the action runs. Present tense, no
    /// modal, no Cancel button: the engine calls are synchronous and cannot
    /// be cancelled, and signing may raise a prompt the user must reach.
    public var progressLabel: String {
        switch self {
        case .editMessage: "Editing message…"
        case .fixupIntoParent: "Folding into parent…"
        case .squashIntoParent: "Squashing into parent…"
        case .split: "Splitting…"
        case .swapWithParent, .swapWithChild: "Moving commit…"
        case .delete: "Deleting commit…"
        case .revert: "Reverting…"
        case .cherryPick: "Cherry-picking…"
        case .merge: "Merging…"
        case .rebaseOnto: "Rebasing…"
        case .setBranchTip: "Setting branch tip…"
        case .addTag: "Adding tag…"
        case .createBranch: "Creating branch…"
        case .editLocalBranch: "Renaming branch…"
        }
    }

    /// Menu sections, top to bottom; a `Divider` between each.
    public static let menuGroups: [[CommitAction]] = [
        [.editMessage, .fixupIntoParent, .squashIntoParent, .split],
        [.swapWithParent, .swapWithChild],
        [.delete],
        [.revert, .cherryPick],
        [.merge, .rebaseOnto, .setBranchTip],
        [.addTag, .createBranch, .editLocalBranch],
    ]

    /// The action a composed request runs — the failure alert's verb and
    /// the busy line's label both read from it.
    public static func action(of request: CommitActionRequest) -> CommitAction {
        switch request {
        case .editMessage: .editMessage
        case .fixupIntoParent: .fixupIntoParent
        case .squashIntoParent: .squashIntoParent
        case .split: .split
        case .swapWithParent: .swapWithParent
        case .swapWithChild: .swapWithChild
        case .delete: .delete
        case .revert: .revert
        case .cherryPick: .cherryPick
        case .merge: .merge
        case .rebaseOnto: .rebaseOnto
        case .setBranchTip: .setBranchTip
        case .addTag: .addTag
        case .createBranch: .createBranch
        case .renameBranch: .editLocalBranch
        }
    }
}

/// The first-parent chain from a tip, newest first, within the loaded rows.
public nonisolated enum FirstParentChain {
    public static func oids(in rows: [GraphRow], from tip: String) -> [String] {
        let byOid = Dictionary(rows.map { ($0.oid, $0) }, uniquingKeysWith: { first, _ in first })
        var chain: [String] = []
        var next: String? = tip
        while let oid = next, let row = byOid[oid] {
            chain.append(oid)
            next = row.parents.first
        }
        return chain
    }
}

/// Everything the availability rules need to know about one node.
public nonisolated struct CommitActionContext: Equatable, Sendable {
    public let oid: String
    public let isMerge: Bool
    public let isRoot: Bool
    /// Index on `HEAD`'s first-parent chain, 0 = the commit `HEAD` names;
    /// `nil` when the node is off that chain.
    public let chainIndex: Int?
    public let parentIsRoot: Bool
    public let parentIsMerge: Bool
    /// A merge sits between this node and `HEAD` on the chain — the replay
    /// would have to cherry-pick it, which git refuses.
    public let mergeAbove: Bool
    public let branchName: String?
    public let hasStagedChanges: Bool
    public let operationInProgress: String?
    public let isBusy: Bool
    /// The local branch whose tip names this node, if any — the branch
    /// Edit Local Branch… edits.
    public let localBranchHere: String?
    /// The branch owning this node per `BranchOwnership.owners` — the branch
    /// Merge into Current Branch merges — with whether it is a
    /// remote-tracking name.
    public let owningBranch: String?
    public let owningBranchIsRemote: Bool

    public init(
        oid: String, isMerge: Bool, isRoot: Bool, chainIndex: Int?, parentIsRoot: Bool,
        parentIsMerge: Bool, mergeAbove: Bool, branchName: String?, hasStagedChanges: Bool,
        operationInProgress: String?, isBusy: Bool, localBranchHere: String? = nil,
        owningBranch: String? = nil, owningBranchIsRemote: Bool = false
    ) {
        self.oid = oid
        self.isMerge = isMerge
        self.isRoot = isRoot
        self.chainIndex = chainIndex
        self.parentIsRoot = parentIsRoot
        self.parentIsMerge = parentIsMerge
        self.mergeAbove = mergeAbove
        self.branchName = branchName
        self.hasStagedChanges = hasStagedChanges
        self.operationInProgress = operationInProgress
        self.isBusy = isBusy
        self.localBranchHere = localBranchHere
        self.owningBranch = owningBranch
        self.owningBranchIsRemote = owningBranchIsRemote
    }

    /// `nil` when `oid` is not in `rows`.
    public static func make(
        oid: String, rows: [GraphRow], whereAmI: WhereAmI,
        owners: [String: BranchTip] = [:], isBusy: Bool
    ) -> CommitActionContext? {
        let byOid = Dictionary(rows.map { ($0.oid, $0) }, uniquingKeysWith: { first, _ in first })
        guard let row = byOid[oid] else { return nil }
        let chain = whereAmI.rawHead.isEmpty ? [] : FirstParentChain.oids(in: rows, from: whereAmI.rawHead)
        let index = chain.firstIndex(of: oid)
        let parent = row.parents.first.flatMap { byOid[$0] }
        let mergeAbove = index.map { chain[..<$0].contains { (byOid[$0]?.parents.count ?? 0) > 1 } } ?? false
        let owner = owners[oid]
        return CommitActionContext(
            oid: oid,
            isMerge: row.parents.count > 1,
            isRoot: row.parents.isEmpty,
            chainIndex: index,
            parentIsRoot: parent?.parents.isEmpty ?? false,
            parentIsMerge: (parent?.parents.count ?? 0) > 1,
            mergeAbove: mergeAbove,
            branchName: whereAmI.branch,
            hasStagedChanges: whereAmI.stagedCount > 0,
            operationInProgress: TrackingSummary.operationInProgress(for: whereAmI),
            isBusy: isBusy,
            localBranchHere: owner.flatMap { (!$0.isRemote && $0.oid == oid) ? $0.name : nil },
            owningBranch: owner?.name,
            owningBranchIsRemote: owner?.isRemote ?? false)
    }
}

public nonisolated struct CommitActionState: Equatable, Sendable {
    public let action: CommitAction
    /// `nil` when the action is available; otherwise the reason it is not.
    public let disabledReason: String?

    public init(action: CommitAction, disabledReason: String?) {
        self.action = action
        self.disabledReason = disabledReason
    }

    public var isEnabled: Bool { disabledReason == nil }
}

public nonisolated enum CommitActionRules {
    public static func states(for context: CommitActionContext) -> [CommitActionState] {
        CommitAction.allCases.map { CommitActionState(action: $0, disabledReason: reason($0, context)) }
    }

    /// Every item disabled with one reason — the menu bar's state when no
    /// commit is selected.
    public static func allDisabled(reason: String) -> [CommitActionState] {
        CommitAction.allCases.map { CommitActionState(action: $0, disabledReason: reason) }
    }

    public static func reason(_ action: CommitAction, _ c: CommitActionContext) -> String? {
        if c.isBusy { return "Another operation is still running" }
        if let operation = c.operationInProgress { return "\(operation) — finish or abort it first" }
        switch action {
        case .editMessage, .fixupIntoParent, .squashIntoParent, .split,
             .swapWithParent, .swapWithChild, .delete:
            return rewriteReason(action, c)
        case .revert:
            return c.isMerge ? "A merge commit can’t be reverted" : nil
        case .cherryPick:
            if c.isMerge { return "A merge commit can’t be cherry-picked without choosing a parent" }
            if let branch = c.branchName, c.chainIndex != nil {
                return "Its change is already in “\(branch)”"
            }
            return nil
        case .merge:
            guard let owner = c.owningBranch else { return "No branch contains this commit" }
            if c.owningBranchIsRemote { return "Only a local branch can be merged" }
            if owner == c.branchName { return "Already part of “\(owner)”" }
            return nil
        case .rebaseOnto:
            guard c.branchName != nil else {
                return "HEAD is detached — there is no branch to rebase"
            }
            if let branch = c.branchName, c.chainIndex != nil {
                return "This commit is already in “\(branch)”’s history"
            }
            return nil
        case .setBranchTip:
            guard c.branchName != nil else {
                return "HEAD is detached — there is no branch tip to move"
            }
            if c.chainIndex == 0 { return "The branch tip already names this commit" }
            return nil
        case .addTag, .createBranch:
            return nil
        case .editLocalBranch:
            return c.localBranchHere == nil ? "No local branch points here" : nil
        }
    }

    /// The guards shared by every action that rewrites `HEAD`'s own history.
    /// The replay-and-ref actions are not rewrites and never reach this.
    private static func rewriteReason(_ action: CommitAction, _ c: CommitActionContext) -> String? {
        let branch = c.branchName.map { "“\($0)”" } ?? "HEAD"
        guard let index = c.chainIndex else {
            return "Only commits in \(branch)’s own history can be rewritten"
        }
        switch action {
        case .editMessage, .split:
            return c.mergeAbove ? "A merge commit above this one can’t be replayed" : nil
        case .fixupIntoParent, .squashIntoParent:
            if index != 0 {
                return "Only the newest commit on \(branch) can be folded into its parent"
            }
            if c.isRoot { return "This commit has no parent" }
            if c.isMerge { return "A merge commit can’t be folded into its parent" }
            if c.hasStagedChanges { return "Commit or unstage your staged changes first" }
            return nil
        case .swapWithChild:
            if index == 0 { return "Already the newest commit on \(branch)" }
            if c.isRoot { return "The root commit can’t be moved" }
            if c.isMerge || c.mergeAbove { return "Merge commits can’t be reordered" }
            return nil
        case .swapWithParent:
            if c.isRoot { return "Already the oldest commit" }
            if c.parentIsRoot { return "A commit can’t move below the root commit" }
            if c.isMerge || c.parentIsMerge || c.mergeAbove {
                return "Merge commits can’t be reordered"
            }
            return nil
        case .delete:
            if c.isMerge { return "A merge commit can’t be deleted" }
            if c.isRoot { return "The root commit can’t be deleted" }
            return c.mergeAbove ? "A merge commit above this one can’t be replayed" : nil
        default:
            return nil
        }
    }
}

/// The engine request an action becomes. Sheet-composed actions (message
/// and name entries, the Split sheet) are built by their sheets; the rest
/// derive here from the clicked node and the first-parent chain, and `nil`
/// means the context cannot supply what the engine call needs — the menu's
/// disabled state should have caught it.
public nonisolated enum CommitActionRequest: Equatable, Sendable {
    case editMessage(commit: String, message: String)
    case fixupIntoParent(parent: String)
    case squashIntoParent(message: String)
    case split(commit: String, hunkID: String, first: String?, second: String?)
    case swapWithParent(commit: String, parent: String)
    case swapWithChild(commit: String, child: String)
    case delete(commit: String)
    case revert(commit: String)
    case cherryPick(commit: String)
    case merge(branch: String)
    case rebaseOnto(base: String)
    case setBranchTip(commit: String)
    case addTag(commit: String, name: String, annotated: Bool, message: String?)
    case createBranch(name: String, start: String)
    case renameBranch(old: String, new: String)

    /// The request derivable from the node alone; `nil` for the six
    /// sheet-composed actions, which the caller builds once the sheet
    /// returns.
    public static func make(
        for action: CommitAction, oid: String, chain: [String],
        owners: [String: BranchTip]
    ) -> CommitActionRequest? {
        switch action {
        case .editMessage, .squashIntoParent, .split, .addTag, .createBranch, .editLocalBranch:
            return nil
        case .fixupIntoParent:
            guard chain.first == oid, chain.count > 1 else { return nil }
            return .fixupIntoParent(parent: chain[1])
        case .swapWithParent:
            guard let index = chain.firstIndex(of: oid), index + 1 < chain.count else { return nil }
            return .swapWithParent(commit: oid, parent: chain[index + 1])
        case .swapWithChild:
            guard let index = chain.firstIndex(of: oid), index > 0 else { return nil }
            return .swapWithChild(commit: oid, child: chain[index - 1])
        case .delete:
            return .delete(commit: oid)
        case .revert:
            return .revert(commit: oid)
        case .cherryPick:
            return .cherryPick(commit: oid)
        case .merge:
            guard let owner = owners[oid], !owner.isRemote else { return nil }
            return .merge(branch: owner.name)
        case .rebaseOnto:
            return .rebaseOnto(base: oid)
        case .setBranchTip:
            return .setBranchTip(commit: oid)
        }
    }
}

public nonisolated enum RewriteSelection {
    /// Where the acted-on commit sits on the chain afterwards.
    public static func chainIndex(after action: CommitAction, from index: Int) -> Int {
        switch action {
        case .swapWithChild: max(index - 1, 0)
        case .swapWithParent: index + 1
        case .revert, .cherryPick, .rebaseOnto, .setBranchTip: 0
        case .editMessage, .fixupIntoParent, .squashIntoParent, .split, .delete,
             .merge, .addTag, .createBranch, .editLocalBranch:
            index
        }
    }

    /// The oid to select once the refreshed rows arrive. `newHead` is the
    /// refreshed `WhereAmI.rawHead`.
    public static func oid(
        after action: CommitAction, from index: Int, rows: [GraphRow], newHead: String
    ) -> String? {
        let chain = FirstParentChain.oids(in: rows, from: newHead)
        guard !chain.isEmpty else { return nil }
        return chain[min(chainIndex(after: action, from: index), chain.count - 1)]
    }
}

public nonisolated struct CommitActionFailure: Equatable, Sendable {
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    public static func make(for action: CommitAction, error: any Error) -> CommitActionFailure {
        let verb: String = switch action {
        case .editMessage: "Edit Message"
        case .fixupIntoParent: "Fixup Commit"
        case .squashIntoParent: "Squash Commit"
        case .split: "Split Commit"
        case .swapWithParent, .swapWithChild: "Move Commit"
        case .delete: "Delete Commit"
        case .revert: "Revert Commit"
        case .cherryPick: "Cherry-Pick Commit"
        case .merge: "Merge Branch"
        case .rebaseOnto: "Rebase Branch"
        case .setBranchTip: "Set Branch Tip"
        case .addTag: "Add Tag"
        case .createBranch: "Create Branch"
        case .editLocalBranch: "Rename Branch"
        }
        var message = String(describing: error)
        switch (error as? any ExitClassCarrying)?.exitClass {
        case .blockedOnConflicts:
            message += "\n\nGit stopped on a conflict. Resolve the conflicted files, then continue the operation in git."
        case .signingFailed:
            message += "\n\nHistory was not changed. Check that your signing key or agent is available, then try again."
        case .repositoryError, nil:
            break
        }
        return CommitActionFailure(title: "Couldn’t \(verb)", message: message)
    }
}
