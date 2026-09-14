// CommitActionMenuTests.swift — #0359: the commit action menu's rules.
//
// The disabled-state table the planning pass measured on the fixture
// `c3 → c2 (merge of c1 and s1) → c1 → root`, `s1 → root`, `HEAD` at `c3`
// on `main`, asserted exactly per node shape on `LaneAssigner.assign`
// output — no repository needed — plus the guards that precede every rule
// (busy, in-progress operation), the shortcut allocations, the selection
// arithmetic, the prompt compositions and the failure sentences. One
// fixture round-trip drives `performCommitAction(.swapWithParent…)` to
// prove the dispatch reaches the engine and reorders `main`.

import Foundation
import SwiftUI
import Testing
import YardGit
@testable import YardUI

// MARK: - The planning fixture, hand-built

/// `c3 → c2 (merge of c1 and s1) → c1 → root`, `s1 → root`.
private enum Fixture {
    static let nodes: [GraphNode] = [
        GraphNode(oid: "root", parents: []),
        GraphNode(oid: "c1", parents: ["root"]),
        GraphNode(oid: "s1", parents: ["root"]),
        GraphNode(oid: "c2", parents: ["c1", "s1"]),
        GraphNode(oid: "c3", parents: ["c2"]),
    ]
    static let rows = LaneAssigner.assign(nodes)
    /// `main` claims its first-parent chain (c3, c2, c1, root); `side`
    /// claims s1 — the shape `BranchOwnership.owners` produces for the
    /// fixture repository with `HEAD` at c3 on `main`.
    static let owners: [String: BranchTip] = owners(in: rows)
    static let chain = FirstParentChain.oids(in: rows, from: "c3")

    static func owners(in rows: [GraphRow]) -> [String: BranchTip] {
        BranchOwnership.owners(
            in: rows,
            tips: [
                BranchTip(name: "main", oid: "c3", isRemote: false),
                BranchTip(name: "side", oid: "s1", isRemote: false),
            ])
    }

    static func whereAmI(
        branch: String? = "main", stagedCount: Int = 0, rawHead: String = "c3",
        isMidRebase: Bool = false, isMidMerge: Bool = false,
        isMidCherryPick: Bool = false, isMidRevert: Bool = false
    ) -> WhereAmI {
        WhereAmI(
            branch: branch, upstream: nil, ahead: nil, behind: nil,
            isMidRebase: isMidRebase, isMidMerge: isMidMerge,
            isMidCherryPick: isMidCherryPick, isMidRevert: isMidRevert,
            stashCount: 0, untrackedCount: 0, unstagedCount: 0,
            stagedCount: stagedCount, hasConflicts: false, conflictCount: 0,
            headOID: rawHead, rawHead: rawHead)
    }

    static func context(
        _ oid: String, whereAmI: WhereAmI = whereAmI(),
        owners: [String: BranchTip]? = nil, isBusy: Bool = false
    ) throws -> CommitActionContext {
        try #require(CommitActionContext.make(
            oid: oid, rows: rows, whereAmI: whereAmI,
            owners: owners ?? self.owners, isBusy: isBusy))
    }

    static func states(
        _ oid: String, whereAmI: WhereAmI = whereAmI(),
        owners: [String: BranchTip]? = nil, isBusy: Bool = false
    ) throws -> [CommitActionState] {
        CommitActionRules.states(for: try context(oid, whereAmI: whereAmI, owners: owners, isBusy: isBusy))
    }

    /// The disabled reason one action carries in a states list, failing the
    /// test when the action is absent — never a silent nil.
    static func reason(_ action: CommitAction, in states: [CommitActionState]) throws -> String? {
        try #require(states.first { $0.action == action }).disabledReason
    }
}

/// Binds the action's state out of a list; the lookup failing the test is
/// the point, so no assertion below can pass vacuously.
private func state(_ action: CommitAction, in states: [CommitActionState]) throws -> CommitActionState {
    try #require(states.first { $0.action == action })
}

// MARK: - Item set

@Test func everyActionAppearsExactlyOnceInTheMenu() {
    #expect(CommitAction.allCases.count == 15)
    #expect(CommitAction.menuGroups.flatMap { $0 }.count == 15)
    #expect(Set(CommitAction.menuGroups.flatMap { $0 }) == Set(CommitAction.allCases))
}

@Test func allFifteenActionsAreCoveredByTheRules() throws {
    let states = try Fixture.states("c3")
    #expect(states.count == 15)
    #expect(Set(states.map(\.action)) == Set(CommitAction.allCases))
}

// MARK: - The measured table: tip (c3)

@Test func tipNodeDisablesReorderAndReplayItemsWithTheirReasons() throws {
    let states = try Fixture.states("c3")
    for action in [CommitAction.editMessage, .fixupIntoParent, .squashIntoParent,
                   .split, .delete, .revert, .addTag, .createBranch, .editLocalBranch] {
        #expect(try state(action, in: states).isEnabled, "\(action) should be enabled")
    }
    #expect(try Fixture.reason(.swapWithChild, in: states) == "Already the newest commit on “main”")
    #expect(try Fixture.reason(.swapWithParent, in: states) == "Merge commits can’t be reordered")
    #expect(try Fixture.reason(.cherryPick, in: states) == "Its change is already in “main”")
    #expect(try Fixture.reason(.merge, in: states) == "Already part of “main”")
    #expect(try Fixture.reason(.rebaseOnto, in: states) == "This commit is already in “main”’s history")
    #expect(try Fixture.reason(.setBranchTip, in: states) == "The branch tip already names this commit")
}

// MARK: - Merge node (c2)

@Test func mergeNodeKeepsMessageAndSplitButRefusesTheRest() throws {
    let states = try Fixture.states("c2")
    for action in [CommitAction.editMessage, .split, .setBranchTip, .addTag, .createBranch] {
        #expect(try state(action, in: states).isEnabled, "\(action) should be enabled")
    }
    #expect(try Fixture.reason(.fixupIntoParent, in: states)
            == "Only the newest commit on “main” can be folded into its parent")
    #expect(try Fixture.reason(.squashIntoParent, in: states)
            == "Only the newest commit on “main” can be folded into its parent")
    #expect(try Fixture.reason(.swapWithChild, in: states) == "Merge commits can’t be reordered")
    #expect(try Fixture.reason(.swapWithParent, in: states) == "Merge commits can’t be reordered")
    #expect(try Fixture.reason(.delete, in: states) == "A merge commit can’t be deleted")
    #expect(try Fixture.reason(.revert, in: states) == "A merge commit can’t be reverted")
    #expect(try Fixture.reason(.cherryPick, in: states)
            == "A merge commit can’t be cherry-picked without choosing a parent")
    #expect(try Fixture.reason(.merge, in: states) == "Already part of “main”")
    #expect(try Fixture.reason(.rebaseOnto, in: states)
            == "This commit is already in “main”’s history")
    #expect(try Fixture.reason(.editLocalBranch, in: states) == "No local branch points here")
}

// MARK: - Inner node (c1)

@Test func innerNodeBelowAMergeDisablesEveryRewriteWithTheReplayReason() throws {
    let states = try Fixture.states("c1")
    for action in [CommitAction.editMessage, .split, .delete] {
        #expect(try Fixture.reason(action, in: states)
                == "A merge commit above this one can’t be replayed")
    }
    #expect(try Fixture.reason(.swapWithParent, in: states)
            == "A commit can’t move below the root commit")
    #expect(try Fixture.reason(.swapWithChild, in: states) == "Merge commits can’t be reordered")
    #expect(try Fixture.reason(.fixupIntoParent, in: states)
            == "Only the newest commit on “main” can be folded into its parent")
    #expect(try Fixture.reason(.squashIntoParent, in: states)
            == "Only the newest commit on “main” can be folded into its parent")
    #expect(try Fixture.reason(.cherryPick, in: states) == "Its change is already in “main”")
    #expect(try Fixture.reason(.merge, in: states) == "Already part of “main”")
    #expect(try Fixture.reason(.rebaseOnto, in: states)
            == "This commit is already in “main”’s history")
    #expect(try Fixture.reason(.setBranchTip, in: states) == nil)
    #expect(try Fixture.reason(.addTag, in: states) == nil)
    #expect(try Fixture.reason(.createBranch, in: states) == nil)
    #expect(try Fixture.reason(.editLocalBranch, in: states) == "No local branch points here")
}

// MARK: - Off-chain node (s1)

@Test func offChainNodeDisablesEveryRewriteWithTheChainReason() throws {
    let states = try Fixture.states("s1")
    let chainReason = "Only commits in “main”’s own history can be rewritten"
    for action in [CommitAction.editMessage, .fixupIntoParent, .squashIntoParent,
                   .split, .swapWithParent, .swapWithChild, .delete] {
        #expect(try Fixture.reason(action, in: states) == chainReason)
    }
    // The replay-and-ref actions are not rewrites: they act on any commit.
    #expect(try Fixture.reason(.revert, in: states) == nil)
    #expect(try Fixture.reason(.cherryPick, in: states) == nil)
    #expect(try Fixture.reason(.merge, in: states) == nil)
    #expect(try Fixture.reason(.rebaseOnto, in: states) == nil)
    #expect(try Fixture.reason(.setBranchTip, in: states) == nil)
    #expect(try Fixture.reason(.addTag, in: states) == nil)
    #expect(try Fixture.reason(.createBranch, in: states) == nil)
    // s1 is `side`'s tip, so Edit Local Branch… is offered here.
    #expect(try Fixture.reason(.editLocalBranch, in: states) == nil)
}

// MARK: - Root node

@Test func rootNodeDisablesDeleteAndMoveWithTheirReasons() throws {
    let states = try Fixture.states("root")
    #expect(try Fixture.reason(.delete, in: states) == "The root commit can’t be deleted")
    #expect(try Fixture.reason(.swapWithChild, in: states) == "The root commit can’t be moved")
    #expect(try Fixture.reason(.swapWithParent, in: states) == "Already the oldest commit")
    #expect(try Fixture.reason(.editMessage, in: states)
            == "A merge commit above this one can’t be replayed")
    #expect(try Fixture.reason(.split, in: states)
            == "A merge commit above this one can’t be replayed")
    #expect(try Fixture.reason(.fixupIntoParent, in: states)
            == "Only the newest commit on “main” can be folded into its parent")
    #expect(try Fixture.reason(.revert, in: states) == nil)
    #expect(try Fixture.reason(.cherryPick, in: states) == "Its change is already in “main”")
    #expect(try Fixture.reason(.merge, in: states) == "Already part of “main”")
}

// MARK: - The guards that precede every rule

@Test func busyDisablesAllFifteenWithOneSentenceBeforeAnyOtherRule() throws {
    let states = try Fixture.states("c3", isBusy: true)
    #expect(states.count == 15)
    for entry in states {
        #expect(!entry.isEnabled)
        #expect(entry.disabledReason == "Another operation is still running")
    }
}

@Test func anInProgressRebaseDisablesAllFifteenBeforeAnyOtherRule() throws {
    let states = try Fixture.states("c3", whereAmI: Fixture.whereAmI(isMidRebase: true))
    for entry in states {
        #expect(entry.disabledReason == "A rebase is in progress — finish or abort it first")
    }
}

@Test func anInProgressRevertDisablesAllFifteenWithItsSentence() throws {
    let states = try Fixture.states("c3", whereAmI: Fixture.whereAmI(isMidRevert: true))
    for entry in states {
        #expect(entry.disabledReason == "A revert is in progress — finish or abort it first")
    }
}

@Test func stagedChangesDisableOnlyTheFoldItems() throws {
    let states = try Fixture.states("c3", whereAmI: Fixture.whereAmI(stagedCount: 1))
    #expect(try Fixture.reason(.fixupIntoParent, in: states)
            == "Commit or unstage your staged changes first")
    #expect(try Fixture.reason(.squashIntoParent, in: states)
            == "Commit or unstage your staged changes first")
    #expect(try Fixture.reason(.editMessage, in: states) == nil)
    #expect(try Fixture.reason(.revert, in: states) == nil)
}

@Test func detachedHeadNamesHeadInTheChainGuardAndDisablesTheBranchMoves() throws {
    // Detached at c3: the node is still the chain's newest commit, so the
    // rewrites stay available and the guard text names HEAD; only the
    // branch-moving actions refuse — there is no branch to move.
    let states = try Fixture.states(
        "c3", whereAmI: Fixture.whereAmI(branch: nil, rawHead: "c3"))
    #expect(try Fixture.reason(.editMessage, in: states) == nil)
    #expect(try Fixture.reason(.delete, in: states) == nil)
    #expect(try Fixture.reason(.fixupIntoParent, in: states) == nil)
    #expect(try Fixture.reason(.swapWithChild, in: states)
            == "Already the newest commit on HEAD")
    #expect(try Fixture.reason(.cherryPick, in: states) == nil)
    #expect(try Fixture.reason(.rebaseOnto, in: states)
            == "HEAD is detached — there is no branch to rebase")
    #expect(try Fixture.reason(.setBranchTip, in: states)
            == "HEAD is detached — there is no branch tip to move")
}

@Test func anUnownedNodeDisablesMergeWithItsReason() throws {
    // A commit no tip's first-parent chain reaches has no owner: Merge has
    // nothing to name.
    let states = try Fixture.states("s1", owners: [:])
    #expect(try Fixture.reason(.merge, in: states) == "No branch contains this commit")
}

@Test func aRemoteOwnedNodeRefusesTheMerge() throws {
    var remoteOwners = Fixture.owners
    remoteOwners["s1"] = BranchTip(name: "origin/side", oid: "s1", isRemote: true)
    let states = try Fixture.states("s1", owners: remoteOwners)
    #expect(try Fixture.reason(.merge, in: states) == "Only a local branch can be merged")
    // Edit Local Branch reads local tips only.
    #expect(try Fixture.reason(.editLocalBranch, in: states) == "No local branch points here")
}

// MARK: - Context construction

@Test func makeReturnsNilForAnOidOutsideTheRows() throws {
    #expect(
        CommitActionContext.make(
            oid: "absent", rows: Fixture.rows, whereAmI: Fixture.whereAmI(),
            owners: Fixture.owners, isBusy: false) == nil)
}

@Test func contextReadsMergeRootAndChainPositionOffTheRows() throws {
    let tip = try Fixture.context("c3")
    #expect(!tip.isMerge)
    #expect(!tip.isRoot)
    #expect(tip.chainIndex == 0)
    #expect(tip.parentIsMerge)
    let merge = try Fixture.context("c2")
    #expect(merge.isMerge)
    #expect(merge.chainIndex == 1)
    let side = try Fixture.context("s1")
    #expect(side.chainIndex == nil)
    #expect(side.localBranchHere == "side")
    #expect(side.owningBranch == "side")
    let root = try Fixture.context("root")
    #expect(root.isRoot)
    #expect(root.chainIndex == 3)
}

@Test func chainFollowsFirstParentsNewestFirst() throws {
    #expect(Fixture.chain == ["c3", "c2", "c1", "root"])
}

// MARK: - Shortcuts

@Test func allocatedShortcutsAreDistinctAndAvoidTheReservedSet() {
    let allocated = CommitAction.allCases.compactMap(\.shortcut)
    #expect(allocated.count == 13)
    #expect(Set(allocated).count == 13)
    let reserved: [KeyboardShortcut] = [
        KeyboardShortcut("z", modifiers: .command),
        KeyboardShortcut("z", modifiers: [.command, .shift]),
        KeyboardShortcut("e", modifiers: .command),
        KeyboardShortcut("f", modifiers: .command),
        KeyboardShortcut("d", modifiers: .command),
        KeyboardShortcut("m", modifiers: .command),
        KeyboardShortcut("h", modifiers: .command),
        KeyboardShortcut("t", modifiers: .command),
        KeyboardShortcut("f", modifiers: [.control, .command]),
    ]
    for shortcut in allocated {
        #expect(!reserved.contains(shortcut), "\(shortcut) collides with a reserved equivalent")
    }
}

@Test func setBranchTipAndEditLocalBranchAreTheDeliberatelyUnallocatedItems() {
    let unallocated = CommitAction.allCases.filter { $0.shortcut == nil }
    #expect(Set(unallocated) == [.setBranchTip, .editLocalBranch])
}

@Test func titlesThatAskForInputOrConfirmationEndWithAnEllipsis() {
    let asking: [CommitAction] = [
        .editMessage, .squashIntoParent, .split, .delete,
        .setBranchTip, .addTag, .createBranch, .editLocalBranch,
    ]
    for action in asking {
        #expect(action.title(branchName: "main").hasSuffix("…"), "\(action) should ask")
        #expect(action.title(branchName: nil).hasSuffix("…"))
    }
    #expect(CommitAction.setBranchTip.title(branchName: "main") == "Set “main” Tip Here…")
    #expect(CommitAction.setBranchTip.title(branchName: nil) == "Set Branch Tip Here…")
    let direct: [CommitAction] = [
        .fixupIntoParent, .swapWithParent, .swapWithChild, .revert,
        .cherryPick, .merge, .rebaseOnto,
    ]
    for action in direct {
        #expect(!action.title.hasSuffix("…"), "\(action) asks for nothing")
    }
}

@Test func everyActionCarriesAProgressLabel() {
    for action in CommitAction.allCases {
        #expect(!action.progressLabel.isEmpty)
    }
    #expect(CommitAction.editMessage.progressLabel == "Editing message…")
    #expect(CommitAction.split.progressLabel == "Splitting…")
}

// MARK: - Selection arithmetic

@Test func chainIndexAfterEachAction() {
    #expect(RewriteSelection.chainIndex(after: .swapWithChild, from: 2) == 1)
    #expect(RewriteSelection.chainIndex(after: .swapWithChild, from: 0) == 0)
    #expect(RewriteSelection.chainIndex(after: .swapWithParent, from: 2) == 3)
    for action in [CommitAction.revert, .cherryPick, .rebaseOnto, .setBranchTip] {
        #expect(RewriteSelection.chainIndex(after: action, from: 2) == 0)
    }
    for action in [CommitAction.editMessage, .fixupIntoParent, .squashIntoParent,
                   .split, .delete, .merge, .addTag, .createBranch, .editLocalBranch] {
        #expect(RewriteSelection.chainIndex(after: action, from: 2) == 2)
    }
}

@Test func selectionFollowsTheMovedCommitAndClampsAtTheChainEnd() throws {
    // The planning pass pinned this exact call: swap-with-parent from the
    // tip selects the parent's position, here c2.
    #expect(RewriteSelection.oid(after: .swapWithParent, from: 0, rows: Fixture.rows, newHead: "c3") == "c2")
    #expect(RewriteSelection.oid(after: .editMessage, from: 1, rows: Fixture.rows, newHead: "c3") == "c2")
    // A swap-with-parent from the last row clamps to the chain's end.
    #expect(RewriteSelection.oid(after: .swapWithParent, from: 3, rows: Fixture.rows, newHead: "c3") == "root")
    #expect(RewriteSelection.oid(after: .revert, from: 2, rows: Fixture.rows, newHead: "c3") == "c3")
}

// MARK: - Request dispatch

@Test func nodeDerivedRequestsComeFromTheChainAndOwners() throws {
    #expect(CommitActionRequest.make(for: .fixupIntoParent, oid: "c3", chain: Fixture.chain, owners: Fixture.owners)
            == .fixupIntoParent(parent: "c2"))
    #expect(CommitActionRequest.make(for: .fixupIntoParent, oid: "c2", chain: Fixture.chain, owners: Fixture.owners) == nil)
    #expect(CommitActionRequest.make(for: .swapWithParent, oid: "c3", chain: Fixture.chain, owners: Fixture.owners)
            == .swapWithParent(commit: "c3", parent: "c2"))
    #expect(CommitActionRequest.make(for: .swapWithParent, oid: "root", chain: Fixture.chain, owners: Fixture.owners) == nil)
    #expect(CommitActionRequest.make(for: .swapWithChild, oid: "c3", chain: Fixture.chain, owners: Fixture.owners) == nil)
    #expect(CommitActionRequest.make(for: .swapWithChild, oid: "c2", chain: Fixture.chain, owners: Fixture.owners)
            == .swapWithChild(commit: "c2", child: "c3"))
    #expect(CommitActionRequest.make(for: .delete, oid: "c1", chain: Fixture.chain, owners: Fixture.owners)
            == .delete(commit: "c1"))
    #expect(CommitActionRequest.make(for: .revert, oid: "s1", chain: Fixture.chain, owners: Fixture.owners)
            == .revert(commit: "s1"))
    #expect(CommitActionRequest.make(for: .cherryPick, oid: "s1", chain: Fixture.chain, owners: Fixture.owners)
            == .cherryPick(commit: "s1"))
    #expect(CommitActionRequest.make(for: .merge, oid: "s1", chain: Fixture.chain, owners: Fixture.owners)
            == .merge(branch: "side"))
    #expect(CommitActionRequest.make(for: .rebaseOnto, oid: "s1", chain: Fixture.chain, owners: Fixture.owners)
            == .rebaseOnto(base: "s1"))
    #expect(CommitActionRequest.make(for: .setBranchTip, oid: "c2", chain: Fixture.chain, owners: Fixture.owners)
            == .setBranchTip(commit: "c2"))
}

@Test func sheetComposedActionsDeriveNoRequestFromTheNode() {
    for action in [CommitAction.editMessage, .squashIntoParent, .split,
                   .addTag, .createBranch, .editLocalBranch] {
        #expect(CommitActionRequest.make(for: action, oid: "c3", chain: Fixture.chain, owners: Fixture.owners) == nil)
    }
}

@Test func everyRequestNamesItsAction() {
    let pairs: [(CommitActionRequest, CommitAction)] = [
        (.editMessage(commit: "c", message: "m"), .editMessage),
        (.fixupIntoParent(parent: "p"), .fixupIntoParent),
        (.squashIntoParent(message: "m"), .squashIntoParent),
        (.split(commit: "c", hunkID: "h", first: nil, second: nil), .split),
        (.swapWithParent(commit: "c", parent: "p"), .swapWithParent),
        (.swapWithChild(commit: "c", child: "k"), .swapWithChild),
        (.delete(commit: "c"), .delete),
        (.revert(commit: "c"), .revert),
        (.cherryPick(commit: "c"), .cherryPick),
        (.merge(branch: "b"), .merge),
        (.rebaseOnto(base: "c"), .rebaseOnto),
        (.setBranchTip(commit: "c"), .setBranchTip),
        (.addTag(commit: "c", name: "t", annotated: false, message: nil), .addTag),
        (.createBranch(name: "b", start: "c"), .createBranch),
        (.renameBranch(old: "o", new: "n"), .editLocalBranch),
    ]
    #expect(pairs.count == 15)
    for (request, action) in pairs {
        #expect(CommitAction.action(of: request) == action)
    }
}

// MARK: - Prompt composition

@Test func messagePromptRefusesEmptyAndUnchangedMessages() {
    let prompt = CommitActionPrompt.editMessage(commit: "c3", subject: "s", message: "old")
    #expect(CommitPromptRequest.message(prompt, "old") == nil)
    #expect(CommitPromptRequest.message(prompt, "   \n ") == nil)
    #expect(CommitPromptRequest.message(prompt, "new") == .editMessage(commit: "c3", message: "new"))
    let squash = CommitActionPrompt.squash(commit: "c3", subject: "s", message: "old")
    // Squash's pre-fill already differs from nothing the engine would
    // refuse — only emptiness blocks it.
    #expect(CommitPromptRequest.message(squash, "combined") == .squashIntoParent(message: "combined"))
    #expect(CommitPromptRequest.message(squash, "  ") == nil)
}

@Test func namePromptComposesTagsBranchesAndRenames() {
    let tag = CommitActionPrompt.addTag(commit: "c3", subject: "s")
    #expect(CommitPromptRequest.name(tag, "v1", annotated: false, message: "")
            == .addTag(commit: "c3", name: "v1", annotated: false, message: nil))
    #expect(CommitPromptRequest.name(tag, "v1", annotated: true, message: "release")
            == .addTag(commit: "c3", name: "v1", annotated: true, message: "release"))
    // An annotated tag without a message is the engine's `.messageRequired`.
    #expect(CommitPromptRequest.name(tag, "v1", annotated: true, message: "  ") == nil)
    #expect(CommitPromptRequest.name(tag, "  ", annotated: false, message: "") == nil)
    let branch = CommitActionPrompt.createBranch(commit: "c2", subject: "s")
    #expect(CommitPromptRequest.name(branch, "topic", annotated: false, message: "")
            == .createBranch(name: "topic", start: "c2"))
    let rename = CommitActionPrompt.renameBranch(old: "side", commit: "s1", subject: "s")
    #expect(CommitPromptRequest.name(rename, "trunk", annotated: false, message: "")
            == .renameBranch(old: "side", new: "trunk"))
    #expect(CommitPromptRequest.name(rename, " ", annotated: false, message: "") == nil)
}

// MARK: - Delete confirmation

@Test func deleteDialogTitleNamesTheSubjectAndTruncatesLongOnes() {
    let short = PendingDelete(commit: "c3", subject: "Add a plan")
    #expect(short.dialogTitle == "Delete “Add a plan”?")
    let long = PendingDelete(
        commit: "c3",
        subject: String(repeating: "word ", count: 20).trimmingCharacters(in: .whitespaces))
    #expect(long.dialogTitle.hasSuffix("…?”"))
    #expect(long.dialogTitle.count < long.subject.count)
}

// MARK: - Failure sentences

@Test func failuresNameTheActionAndAppendTheTypedRecoverySentences() {
    let conflict = CommitActionFailure.make(
        for: .editMessage, error: RewriteError.blockedOnConflicts(files: []))
    #expect(conflict.title == "Couldn’t Edit Message")
    #expect(conflict.message.hasSuffix(
        "Git stopped on a conflict. Resolve the conflicted files, then continue the operation in git."))
    let signing = CommitActionFailure.make(
        for: .delete, error: RewriteError.signingFailed(reason: "no key"))
    #expect(signing.title == "Couldn’t Delete Commit")
    #expect(signing.message.hasSuffix(
        "History was not changed. Check that your signing key or agent is available, then try again."))
    let plain = CommitActionFailure.make(for: .merge, error: MergeError.alreadyUpToDate(branch: "x"))
    #expect(plain.title == "Couldn’t Merge Branch")
    #expect(!plain.message.contains("conflict. Resolve"))
    #expect(!plain.message.contains("signing key"))
    let fixup = CommitActionFailure.make(
        for: .fixupIntoParent, error: FixupError.indexNotClean(paths: []))
    #expect(fixup.title == "Couldn’t Fixup Commit")
}

// MARK: - Menu bar fallback

@Test func allDisabledCoversEveryActionWithOneReason() {
    let states = CommitActionRules.allDisabled(reason: "Select a commit first")
    #expect(states.count == 15)
    for entry in states {
        #expect(!entry.isEnabled)
        #expect(entry.disabledReason == "Select a commit first")
    }
}

// MARK: - The engine dispatch, against a real fixture

@Test func swapWithParentRoundTripReordersMainThroughTheRunner() async throws {
    var repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let c = try #require(repo.oids["c"])
    let b = try #require(repo.oids["b"])
    let a = try #require(repo.oids["a"])

    try await performCommitAction(.swapWithParent(commit: c, parent: b), at: repo.url.path)

    let entries = try await CommitLog.run(
        path: repo.url.path, rangeArguments: ["--first-parent", "--reverse", "main"])
    #expect(!entries.isEmpty)
    #expect(entries.map(\.subject) == ["a", "c", "b"])
    let newTip = try repo.revParse("main")
    #expect(newTip != c)
    #expect(newTip != b)
}

@Test func deleteRoundTripRemovesTheTipAndMovesTheRefThroughTheRunner() async throws {
    var repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let c = try #require(repo.oids["c"])
    let b = try #require(repo.oids["b"])

    try await performCommitAction(.delete(commit: c), at: repo.url.path)

    #expect(try repo.revParse("main") == b)
}
