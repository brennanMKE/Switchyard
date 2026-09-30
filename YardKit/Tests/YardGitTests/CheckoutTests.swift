// CheckoutTests.swift — switch, check out as local branch, detach; each one
// journal entry, and git switch's local-changes rule (guide §11 decision 38)

import Foundation
import Testing
@testable import YardGit

private let git = GitProcess()

private func read(_ path: String, in repo: FixtureRepository) -> String? {
    try? String(contentsOf: repo.url.appendingPathComponent(path), encoding: .utf8)
}

private func symbolicHead(_ repo: FixtureRepository) throws -> String? {
    let output = try git.capture(["symbolic-ref", "-q", "HEAD"], workingDirectory: repo.url.path)
    return output.exitCode == 0 ? output.lines.first : nil
}

private func entryCount(_ repo: FixtureRepository) throws -> Int {
    try JournalAnchor.list(in: WorktreeContext.resolve(path: repo.url.path)).count
}

private func undo(_ repo: FixtureRepository) throws {
    try JournalUndo.undo(in: WorktreeContext.resolve(path: repo.url.path))
}

/// `main`: `base` (a.txt "a", b.txt "b"). `feature`: one more commit that
/// changes a.txt and adds new.txt. b.txt is the same on both. HEAD on main.
private func twoBranches(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["a.txt": "a\n", "b.txt": "b\n"])])
    try repo.branch("feature")
    try repo.checkout("feature")
    try repo.build([.init("feat", files: ["a.txt": "a feature\n", "new.txt": "new\n"])])
    try repo.checkout("main")
    return repo
}

// MARK: - Switch

@Test(arguments: FixtureRepository.RefFormat.supported())
func switchMovesHeadAndUndoPutsItBack(format: FixtureRepository.RefFormat) throws {
    let repo = try twoBranches(format)
    defer { repo.destroy() }
    let entries = try entryCount(repo)

    let result = try Checkout.switchBranch(name: "feature", at: repo.url.path)

    #expect(result == .init(head: try repo.revParse("feature"), branch: "feature"))
    #expect(try symbolicHead(repo) == "refs/heads/feature")
    #expect(read("a.txt", in: repo) == "a feature\n")
    #expect(try entryCount(repo) == entries + 1, "one entry per switch")

    try undo(repo)
    #expect(try symbolicHead(repo) == "refs/heads/main")
    #expect(read("a.txt", in: repo) == "a\n")
    #expect(read("new.txt", in: repo) == nil)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func switchCarriesAChangeToAFileBothBranchesShare(format: FixtureRepository.RefFormat) throws {
    let repo = try twoBranches(format)
    defer { repo.destroy() }
    try repo.writeUntracked(["b.txt": "b edited\n"])

    try Checkout.switchBranch(name: "feature", at: repo.url.path)

    #expect(try symbolicHead(repo) == "refs/heads/feature")
    #expect(read("b.txt", in: repo) == "b edited\n", "git switch carries the change")

    try undo(repo)
    #expect(try symbolicHead(repo) == "refs/heads/main")
    #expect(read("b.txt", in: repo) == "b edited\n", "and Undo keeps it")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func switchRefusesAChangeItWouldOverwriteAndTouchesNothing(format: FixtureRepository.RefFormat) throws {
    let repo = try twoBranches(format)
    defer { repo.destroy() }
    try repo.writeUntracked(["a.txt": "a edited\n"])
    let entries = try entryCount(repo)

    #expect(throws: Checkout.Refusal.localChangesWouldBeOverwritten(target: "feature", paths: ["a.txt"])) {
        try Checkout.switchBranch(name: "feature", at: repo.url.path)
    }
    #expect(try symbolicHead(repo) == "refs/heads/main")
    #expect(read("a.txt", in: repo) == "a edited\n")
    #expect(try entryCount(repo) == entries, "a refusal writes no entry")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func switchRefusesAStagedChangeItWouldOverwrite(format: FixtureRepository.RefFormat) throws {
    let repo = try twoBranches(format)
    defer { repo.destroy() }
    try repo.writeUntracked(["a.txt": "a staged\n"])
    try git.run(["add", "a.txt"], workingDirectory: repo.url.path)

    #expect(throws: Checkout.Refusal.localChangesWouldBeOverwritten(target: "feature", paths: ["a.txt"])) {
        try Checkout.switchBranch(name: "feature", at: repo.url.path)
    }
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func switchRefusesAnUntrackedFileInTheWay(format: FixtureRepository.RefFormat) throws {
    let repo = try twoBranches(format)
    defer { repo.destroy() }
    try repo.writeUntracked(["new.txt": "mine\n"])

    #expect(throws: Checkout.Refusal.localChangesWouldBeOverwritten(target: "feature", paths: ["new.txt"])) {
        try Checkout.switchBranch(name: "feature", at: repo.url.path)
    }
    #expect(read("new.txt", in: repo) == "mine\n")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func switchIgnoresAFileWhoseStatChangedButNotItsContent(format: FixtureRepository.RefFormat) throws {
    let repo = try twoBranches(format)
    defer { repo.destroy() }
    // The same bytes, rewritten: the index's stat data no longer matches,
    // and without a refresh the dry run reads the file as modified.
    try repo.writeUntracked(["a.txt": "a\n"])
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: 5)],
        ofItemAtPath: repo.url.appendingPathComponent("a.txt").path)

    try Checkout.switchBranch(name: "feature", at: repo.url.path)
    #expect(try symbolicHead(repo) == "refs/heads/feature")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func switchRefusesTheCurrentAnUnknownAndAHeldBranch(format: FixtureRepository.RefFormat) throws {
    let repo = try twoBranches(format)
    defer { repo.destroy() }
    #expect(throws: Checkout.Refusal.alreadyOnBranch("main")) {
        try Checkout.switchBranch(name: "main", at: repo.url.path)
    }
    #expect(throws: Checkout.Refusal.unknownBranch("nope")) {
        try Checkout.switchBranch(name: "nope", at: repo.url.path)
    }
    let worktree = try repo.addWorktree(named: "held", branch: "held-wt")
    defer { try? FileManager.default.removeItem(at: worktree) }
    let entries = try entryCount(repo)
    #expect(throws: Checkout.Refusal.heldByWorktree(branch: "held-wt", worktree: worktree.path)) {
        try Checkout.switchBranch(name: "held-wt", at: repo.url.path)
    }
    #expect(try entryCount(repo) == entries)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func switchRefusesMidMerge(format: FixtureRepository.RefFormat) throws {
    let repo = try FixtureRepository.conflicted(refFormat: format)
    defer { repo.destroy() }
    try git.run(["branch", "elsewhere"], workingDirectory: repo.url.path)

    #expect(throws: Checkout.Refusal.operationInProgress("a merge is in progress")) {
        try Checkout.switchBranch(name: "elsewhere", at: repo.url.path)
    }
}

// MARK: - Check out as local branch

@Test(arguments: FixtureRepository.RefFormat.supported())
func trackRemoteCreatesATrackingBranchAndUndoLeavesTheBranch(format: FixtureRepository.RefFormat) throws {
    let repo = try twoBranches(format)
    defer { repo.destroy() }
    let bare = try repo.addUpstream(branch: "feature")
    defer { try? FileManager.default.removeItem(at: bare) }
    try git.run(["branch", "-q", "-D", "feature"], workingDirectory: repo.url.path)

    let result = try Checkout.trackRemote(remoteBranch: "origin/feature", at: repo.url.path)

    #expect(result.branch == "feature")
    #expect(try symbolicHead(repo) == "refs/heads/feature")
    #expect(try git.run(["rev-parse", "--symbolic-full-name", "@{upstream}"],
                        workingDirectory: repo.url.path).lines == ["refs/remotes/origin/feature"])
    #expect(read("a.txt", in: repo) == "a feature\n")

    try undo(repo)
    #expect(try symbolicHead(repo) == "refs/heads/main")
    #expect(read("a.txt", in: repo) == "a\n")
    // Decision 20: a restore deletes only refs its snapshot recorded, so
    // the branch the checkout created stays (as Undo New Branch leaves it).
    #expect(try git.capture(["rev-parse", "--verify", "--quiet", "refs/heads/feature"],
                            workingDirectory: repo.url.path).exitCode == 0)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func trackRemoteRefusesAnExistingLocalBranchAndAnUnknownRemote(format: FixtureRepository.RefFormat) throws {
    let repo = try twoBranches(format)
    defer { repo.destroy() }
    let bare = try repo.addUpstream(branch: "feature")
    defer { try? FileManager.default.removeItem(at: bare) }
    let entries = try entryCount(repo)

    #expect(throws: Checkout.Refusal.branchExists("feature")) {
        try Checkout.trackRemote(remoteBranch: "origin/feature", at: repo.url.path)
    }
    #expect(throws: Checkout.Refusal.unknownRemoteBranch("origin/nope")) {
        try Checkout.trackRemote(remoteBranch: "origin/nope", at: repo.url.path)
    }
    #expect(try entryCount(repo) == entries)
}

@Test func localNameDropsOnlyTheRemote() {
    #expect(Checkout.localName(forRemoteBranch: "origin/feature") == "feature")
    #expect(Checkout.localName(forRemoteBranch: "origin/team/x") == "team/x")
    #expect(Checkout.localName(forRemoteBranch: "bare") == "bare")
}

// MARK: - Detach

@Test(arguments: FixtureRepository.RefFormat.supported())
func detachLeavesTheBranchAndUndoReattaches(format: FixtureRepository.RefFormat) throws {
    let repo = try twoBranches(format)
    defer { repo.destroy() }
    let feat = try repo.revParse("feature")

    let result = try Checkout.detach(commit: feat, at: repo.url.path)

    #expect(result == .init(head: feat, branch: nil))
    #expect(try symbolicHead(repo) == nil)
    #expect(try repo.revParse("HEAD") == feat)
    #expect(read("new.txt", in: repo) == "new\n")
    #expect(throws: Checkout.Refusal.alreadyDetachedAt(feat)) {
        try Checkout.detach(commit: feat, at: repo.url.path)
    }

    try undo(repo)
    #expect(try symbolicHead(repo) == "refs/heads/main")
    #expect(read("new.txt", in: repo) == nil)
}
