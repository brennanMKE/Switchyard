// RefActionsTests.swift — switching and deleting refs: the data layer
// (guide §11 decision 38)

import Foundation
import Testing
@testable import YardGit
@testable import YardUI

/// `main` (checked out here), `feature`, and `held` checked out by a
/// sibling worktree at /probe/sibling.
private func summary(head: RefSnapshot.Head = .symbolic(target: "refs/heads/main")) -> RepositorySidebarSummary {
    RepositorySidebarSummary(
        refs: RefSnapshot(head: head, refs: [
            .init(name: "refs/heads/feature", oid: "b2"),
            .init(name: "refs/heads/held", oid: "c3"),
            .init(name: "refs/heads/main", oid: "a1"),
            .init(name: "refs/remotes/origin/HEAD", oid: "a1"),
            .init(name: "refs/remotes/origin/main", oid: "a1"),
            .init(name: "refs/remotes/origin/topic", oid: "d4"),
        ]),
        worktrees: [
            WorktreeEntry(path: "/probe/repo", head: "a1", branch: "main", isMainWorktree: true),
            WorktreeEntry(path: "/probe/sibling", head: "c3", branch: "held"),
        ],
        currentWorktreePath: "/probe/repo")
}

private func whereAmI(isMidMerge: Bool = false) -> WhereAmI {
    WhereAmI(
        branch: "main", upstream: nil, ahead: nil, behind: nil,
        isMidRebase: false, isMidMerge: isMidMerge, isMidCherryPick: false, isMidRevert: false,
        stashCount: 0, untrackedCount: 0, unstagedCount: 0, stagedCount: 0,
        hasConflicts: false, conflictCount: 0, headOID: "a1", rawHead: "a1")
}

@Test func theContextReadsTheCurrentBranchTheSiblingsAndTheLocalNames() {
    let c = RefActionContext.make(summary: summary(), whereAmI: whereAmI(), isBusy: false)
    #expect(c.currentBranch == "main")
    #expect(c.heldElsewhere == ["held": "/probe/sibling"], "this worktree's own branch is not 'elsewhere'")
    #expect(c.localBranches == ["feature", "held", "main"])
    #expect(c.operationInProgress == nil)
    let detached = RefActionContext.make(
        summary: summary(head: .detached(oid: "a1")), whereAmI: whereAmI(), isBusy: false)
    #expect(detached.currentBranch == nil)
}

@Test func switchIsOfferedForEveryBranchButTheCurrentAndAHeldOne() {
    let c = RefActionContext.make(summary: summary(), whereAmI: whereAmI(), isBusy: false)
    #expect(RefActionRules.switchReason(branch: "feature", c) == nil)
    #expect(RefActionRules.switchReason(branch: "main", c) == "Already on “main”")
    #expect(RefActionRules.switchReason(branch: "held", c) == "Checked out in /probe/sibling")
    let merging = RefActionContext.make(summary: summary(), whereAmI: whereAmI(isMidMerge: true), isBusy: false)
    #expect(RefActionRules.switchReason(branch: "feature", merging)
        == "A merge is in progress — finish or abort it first")
    let busy = RefActionContext.make(summary: summary(), whereAmI: whereAmI(), isBusy: true)
    #expect(RefActionRules.switchReason(branch: "feature", busy) == "Another operation is still running")
}

@Test func checkOutAsLocalBranchNeedsAFreeNameAndARealBranch() {
    let c = RefActionContext.make(summary: summary(), whereAmI: whereAmI(), isBusy: false)
    #expect(RefActionRules.trackReason(remoteBranch: "origin/topic", c) == nil)
    #expect(RefActionRules.trackReason(remoteBranch: "origin/main", c) == "A local branch “main” already exists")
    #expect(RefActionRules.trackReason(remoteBranch: "origin/HEAD", c) == "This names the remote’s default branch")
}

@Test func deleteBranchRefusesTheCurrentAndAHeldBranchOnly() {
    let c = RefActionContext.make(summary: summary(), whereAmI: whereAmI(isMidMerge: true), isBusy: false)
    #expect(RefActionRules.deleteBranchReason(branch: "feature", c) == nil,
            "deleting another branch is fine mid-merge; git allows it")
    #expect(RefActionRules.deleteBranchReason(branch: "main", c) == "You can’t delete the branch you’re on")
    #expect(RefActionRules.deleteBranchReason(branch: "held", c) == "Checked out in /probe/sibling")
    #expect(RefActionRules.deleteTagReason(c) == nil)
    let busy = RefActionContext.make(summary: summary(), whereAmI: whereAmI(), isBusy: true)
    #expect(RefActionRules.deleteTagReason(busy) == "Another operation is still running")
}

@Test func deletingAsksFirstAndAnUnmergedBranchAsksAgainWithForce() {
    let first = RefDeleteConfirmation.branch("feature")
    #expect(first.title == "Delete branch “feature”?")
    #expect(first.action == .deleteBranch(name: "feature", force: false))
    #expect(first.message.hasSuffix("Edit ▸ Undo Delete Branch brings it back."))
    let second = RefDeleteConfirmation.unmergedBranch("feature")
    #expect(second.confirmTitle == "Delete Unmerged Branch")
    #expect(second.action == .deleteBranch(name: "feature", force: true))
    let tag = RefDeleteConfirmation.tag("v1.0")
    #expect(tag.title == "Delete tag “v1.0”?")
    #expect(tag.action == .deleteTag(name: "v1.0"))
}

@Test func anOverwriteRefusalBecomesTheStashAndSwitchAlert() throws {
    let refusal = Checkout.Refusal.localChangesWouldBeOverwritten(target: "feature", paths: ["a.txt"])
    let blocked = try #require(CheckoutBlocked(action: .switchBranch(name: "feature"), error: refusal))
    #expect(blocked.title == "Your changes would be overwritten by checking out “feature”")
    #expect(blocked.message.hasPrefix("a.txt would be overwritten."))
    #expect(blocked.retry == .stashChanges(then: .switchBranch(name: "feature")))
    let many = Checkout.Refusal.localChangesWouldBeOverwritten(
        target: "feature", paths: ["a", "b", "c", "d", "e"])
    #expect(try #require(CheckoutBlocked(action: .switchBranch(name: "feature"), error: many))
        .message.hasPrefix("a, b, c and 2 more would be overwritten."))
    #expect(CheckoutBlocked(action: .switchBranch(name: "feature"),
                            error: Checkout.Refusal.alreadyOnBranch("feature")) == nil,
            "any other refusal is an ordinary failure")
    #expect(CheckoutBlocked(action: .deleteTag(name: "v1"), error: refusal) == nil)
}

@Test func eachRefActionHasItsProgressLabelAndAlertTitle() {
    #expect(RefAction.switchBranch(name: "feature").progressLabel == "Switching to “feature”…")
    #expect(RefAction.detach(commit: "0123456789").checkoutTarget == "0123456")
    #expect(RefAction.stashChanges(then: .trackRemote(remoteBranch: "origin/x")).checkoutTarget == "origin/x")
    let refusal = RefManageError.unknownTag("v9")
    let failure = RefAction.deleteTag(name: "v9").failure(for: refusal)
    #expect(failure.title == "Couldn’t Delete Tag")
    #expect(failure.message == refusal.description)
    let git = GitProcess.Failure.exited(code: 128, stderr: "fatal: nope\n", arguments: ["switch", "x"])
    #expect(RefAction.switchBranch(name: "x").failure(for: git).message == "fatal: nope")
}

@Test func theUndoTitlesNameTheCheckouts() {
    #expect(JournalMenuTitles.undo(operation: Checkout.switchOperation) == "Undo Switch Branch")
    #expect(JournalMenuTitles.undo(operation: Checkout.trackOperation) == "Undo Check Out Branch")
    #expect(JournalMenuTitles.redo(operation: Checkout.detachOperation) == "Redo Check Out Commit")
    #expect(JournalMenuTitles.undo(operation: "tag-delete") == "Undo Delete Tag")
}

/// One round trip through the runner: a dirty switch refuses, and Stash
/// Changes and Switch stashes, then switches — two journal entries.
@Test func stashAndSwitchStashesThenSwitches() async throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\n"])])
    try repo.branch("feature")
    try repo.checkout("feature")
    try repo.build([.init("feat", files: ["a.txt": "a feature\n"])])
    try repo.checkout("main")
    try repo.writeUntracked(["a.txt": "mine\n"])
    let path = repo.url.path

    let action = RefAction.switchBranch(name: "feature")
    var blocked: CheckoutBlocked?
    do {
        try await performRefAction(action, at: path)
    } catch {
        blocked = CheckoutBlocked(action: action, error: error)
    }
    let retry = try #require(blocked, "the dirty switch refused with the overwrite refusal").retry
    let context = try await WorktreeContext.resolve(path: path)
    let entries = try JournalAnchor.list(in: context).count
    try await performRefAction(retry, at: path)

    let head = try await GitProcess().run(["symbolic-ref", "HEAD"], workingDirectory: path).lines
    #expect(head == ["refs/heads/feature"])
    let stashes = try await Stash.list(at: path)
    #expect(stashes.first?.message == "On main: Before checking out feature")
    #expect(try JournalAnchor.list(in: context).count == entries + 2)
}
