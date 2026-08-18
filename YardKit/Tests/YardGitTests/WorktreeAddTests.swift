// WorktreeAddTests.swift — engine behind `switchyard wt new` (#0021)

import Foundation
import Testing
@testable import YardGit

// MARK: - Helpers

/// A unique sibling path for the new worktree, next to the fixture, in the
/// same realpath'd temp root the fixture itself uses.
private func siblingPath(for repo: FixtureRepository, _ suffix: String) -> String {
    repo.url.deletingLastPathComponent()
        .appendingPathComponent("\(repo.url.lastPathComponent)-\(suffix)").path
}

/// The entry for a path in a fresh `worktreeList`, canonicalized both sides.
private func listedEntry(in repo: FixtureRepository, at path: String) throws -> WorktreeEntry? {
    try worktreeList(path: repo.url.path).first {
        WorktreeContext.canonicalize($0.path ?? "") == WorktreeContext.canonicalize(path)
    }
}

// MARK: - Fixture-backed

@Test(arguments: FixtureRepository.RefFormat.supported())
func newBranchWorktreeIsCreatedAndListed(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    let path = siblingPath(for: repo, "wt")

    let result = try worktreeAdd(
        at: repo.url.path, path: path, target: .newBranch(name: "issue-1"))
    #expect(result.success)
    #expect(result.error == nil)
    #expect(result.branch == "issue-1")
    #expect(result.head == repo.oids["base"])
    #expect(result.lockReason == nil)
    #expect(FileManager.default.fileExists(atPath: path + "/base.txt"))

    let entry = try #require(try listedEntry(in: repo, at: path))
    #expect(entry.branch == "issue-1")
    #expect(!entry.locked)
    #expect(entry.lockReason == nil)
    #expect(!entry.detached)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func existingBranchTargetReportsItsShortNameAndHead(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    try repo.branch("feature")
    let path = siblingPath(for: repo, "existing-short")

    let result = try worktreeAdd(
        at: repo.url.path, path: path, target: .branch("feature"))
    #expect(result.success)
    #expect(result.branch == "feature")
    #expect(result.head == repo.oids["base"])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func existingBranchTargetGivenAFullRefStillReportsTheShortName(
    format: FixtureRepository.RefFormat
) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    try repo.branch("feature")
    let path = siblingPath(for: repo, "existing-fullref")

    let result = try worktreeAdd(
        at: repo.url.path, path: path, target: .branch("refs/heads/feature"))
    #expect(result.success)
    #expect(result.branch == "feature")
    #expect(result.head == repo.oids["base"])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func agentIDLocksAtCreationWithThePrefixedReason(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    let agentPath = siblingPath(for: repo, "agent")
    let plainPath = siblingPath(for: repo, "plain")

    let plain = try worktreeAdd(
        at: repo.url.path, path: plainPath, target: .newBranch(name: "plain"))
    let locked = try worktreeAdd(
        at: repo.url.path, path: agentPath, target: .newBranch(name: "agented"),
        agentID: "abc123")
    #expect(plain.success && locked.success)
    #expect(locked.lockReason == "switchyard-agent:session=abc123")

    let agentEntry = try #require(try listedEntry(in: repo, at: agentPath))
    #expect(agentEntry.locked)
    #expect(agentEntry.lockReason == "switchyard-agent:session=abc123")
    #expect(WorktreePrune.isAgentLock(reason: agentEntry.lockReason))

    // The sibling created without an agent id must NOT be locked — a lock
    // applied unconditionally would pass a locked-only assertion.
    let plainEntry = try #require(try listedEntry(in: repo, at: plainPath))
    #expect(!plainEntry.locked)
    #expect(plainEntry.lockReason == nil)
    let mainEntry = try #require(try worktreeList(path: repo.url.path).first)
    #expect(!mainEntry.locked)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func branchHeldBySiblingIsRefusedNamingTheHolder(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    let holderPath = siblingPath(for: repo, "holder")
    let secondPath = siblingPath(for: repo, "second")

    let holder = try worktreeAdd(
        at: repo.url.path, path: holderPath, target: .newBranch(name: "held"))
    #expect(holder.success)

    let refused = try worktreeAdd(
        at: repo.url.path, path: secondPath, target: .branch("held"))
    #expect(!refused.success)
    let error = try #require(refused.error)
    guard case let .branchInUse(branch, holderReported, holderIsMain) = error else {
        Issue.record("expected branchInUse, got \(error)")
        return
    }
    #expect(branch == "held")
    #expect(holderReported == WorktreeContext.canonicalize(holderPath))
    #expect(!holderIsMain)
    #expect(error.code == "branchInUse")
    // Nothing was created, and the worktree count did not move.
    #expect(!FileManager.default.fileExists(atPath: secondPath))
    let entries = try worktreeList(path: repo.url.path)
    #expect(entries.count == 2)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func branchHeldByTheMainWorktreeReportsIsMain(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    // The fixture's main worktree has `main` checked out.
    let refused = try worktreeAdd(
        at: repo.url.path, path: siblingPath(for: repo, "clash"), target: .branch("main"))
    let error = try #require(refused.error)
    guard case let .branchInUse(branch, holderReported, holderIsMain) = error else {
        Issue.record("expected branchInUse, got \(error)")
        return
    }
    #expect(branch == "main")
    #expect(holderReported == WorktreeContext.canonicalize(repo.url.path))
    #expect(holderIsMain)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func detachedWorktreeHasNoBranch(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base"), .init("tip")])
    let path = siblingPath(for: repo, "detached")
    let base = try #require(repo.oids["base"])

    let result = try worktreeAdd(
        at: repo.url.path, path: path, target: .detached(at: base))
    #expect(result.success)
    #expect(result.branch == nil)
    #expect(result.head == base)

    let entry = try #require(try listedEntry(in: repo, at: path))
    #expect(entry.detached)
    #expect(entry.branch == nil)
    #expect(entry.head == base)
}

// `detachedWorktreeHasNoBranch` above passes a raw SHA, and git detaches on
// a raw SHA with or without `--detach` (measured) — the fixture cannot
// produce the distinguishing state. This one passes a branch name instead,
// which is the only committish shape `--detach` actually matters for, and
// checks the two engine functions agree via `worktreeList` rather than
// trusting `worktreeAdd`'s own report of itself. It also proves the branch
// was not claimed — the user-visible harm — which `branch == nil` alone
// cannot distinguish, since the engine reports `nil` for `.detached`
// whether or not the branch was actually claimed underneath.
@Test(arguments: FixtureRepository.RefFormat.supported())
func detachedWorktreeGivenABranchNameIsGenuinelyDetachedAndDoesNotClaimTheBranch(
    format: FixtureRepository.RefFormat
) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    try repo.branch("docs")
    let path = siblingPath(for: repo, "detached-branch")

    let result = try worktreeAdd(
        at: repo.url.path, path: path, target: .detached(at: "docs"))
    #expect(result.success)
    #expect(result.branch == nil)
    #expect(result.head == repo.oids["base"])

    // `wt list` must agree with `wt new`: genuinely detached, not attached
    // to `docs`. This is what the raw-SHA fixture cannot exercise — git
    // detaches on a SHA regardless of `--detach`, so only a branch-name
    // committish depends on the flag actually being passed.
    let entry = try #require(try listedEntry(in: repo, at: path))
    #expect(entry.detached)
    #expect(entry.branch == nil)

    // The branch must not have been silently claimed: a second worktreeAdd
    // onto `docs` still succeeds.
    let secondPath = siblingPath(for: repo, "docs-checkout")
    let second = try worktreeAdd(
        at: repo.url.path, path: secondPath, target: .branch("docs"))
    #expect(second.success)
    #expect(second.branch == "docs")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func newBranchStartsAtTheNamedStartPoint(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base"), .init("tip")])
    let path = siblingPath(for: repo, "frombase")
    let base = try #require(repo.oids["base"])
    let tip = try #require(repo.oids["tip"])
    #expect(base != tip)

    let result = try worktreeAdd(
        at: repo.url.path, path: path,
        target: .newBranch(name: "old-work", from: base))
    #expect(result.success)
    // The branch starts at `base`, not at the current HEAD (`tip`).
    #expect(result.head == base)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func populateFalseLeavesOnlyDotGit(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    let path = siblingPath(for: repo, "empty")

    let result = try worktreeAdd(
        at: repo.url.path, path: path, target: .newBranch(name: "sparse-to-be"),
        populate: false)
    #expect(result.success)
    let contents = try FileManager.default.contentsOfDirectory(atPath: path)
    #expect(contents == [".git"])
    // Listed like any other worktree, HEAD already resolvable.
    let entry = try #require(try listedEntry(in: repo, at: path))
    #expect(entry.branch == "sparse-to-be")
    #expect(result.head == repo.oids["base"])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func existingNonEmptyPathIsAStructuredRefusal(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    let path = siblingPath(for: repo, "occupied")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path + "/x", contents: Data())
    defer { try? FileManager.default.removeItem(atPath: path) }

    let result = try worktreeAdd(
        at: repo.url.path, path: path, target: .newBranch(name: "blocked"))
    let error = try #require(result.error)
    guard case .pathExists = error else {
        Issue.record("expected pathExists, got \(error)")
        return
    }
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func duplicateBranchNameIsAStructuredRefusal(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    try repo.branch("taken")

    let result = try worktreeAdd(
        at: repo.url.path, path: siblingPath(for: repo, "dup"),
        target: .newBranch(name: "taken"))
    #expect(result.error == .branchExists("taken"))
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func unknownCommittishIsAStructuredRefusal(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])

    let result = try worktreeAdd(
        at: repo.url.path, path: siblingPath(for: repo, "noref"),
        target: .detached(at: "deadbeef"))
    #expect(result.error == .invalidReference("deadbeef"))
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func worktreePathIsReportedCanonicalized(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])

    // `FixtureRepository.url` is already realpath'd at construction, so a
    // sibling path built from it (as `siblingPath` does) is already
    // canonical and would pass even if `worktreeAdd` stopped canonicalizing
    // its input entirely. To actually exercise that behavior, the requested
    // path has to be built from the RAW, unresolved temp directory —
    // `NSTemporaryDirectory()` returns `/var/folders/…`, and `/var` is a
    // symlink to `/private/var` on macOS.
    let rawParent = NSTemporaryDirectory()
    let rawPath = URL(fileURLWithPath: rawParent)
        .appendingPathComponent("yard-wt-canon-\(UUID().uuidString)").path

    // Resolve the expectation independently of `WorktreeContext.canonicalize`
    // (calling it here would pass even under the mutation that removes it):
    // `realpath(3)`, via `FixtureRepository.realPath`, on the parent
    // directory (which exists), with the new leaf component reattached by
    // hand, since the leaf itself does not exist until `worktreeAdd` creates
    // it.
    let resolvedParent = FixtureRepository.realPath(rawParent)
    let expected = URL(fileURLWithPath: resolvedParent)
        .appendingPathComponent(URL(fileURLWithPath: rawPath).lastPathComponent).path

    // The fixture only proves anything if the raw and canonicalized forms
    // actually differ on this machine.
    #expect(rawPath != expected)

    let result = try worktreeAdd(
        at: repo.url.path, path: rawPath, target: .newBranch(name: "canon-check"))
    #expect(result.success)
    #expect(result.worktreePath == expected)
}

/// #0321 (M1 milestone review, finding 4): `worktreeAdd` canonicalizes the
/// requested path **before** `git worktree add` runs, while the leaf and its
/// parent are both still missing. Every other fixture in this file creates a
/// worktree under an already-existing parent, so a mutation that reverses a
/// multi-component missing tail (`WorktreeContext.swift:166`) goes uncaught
/// everywhere else: `git worktree add` still creates the real directory at
/// the correctly-ordered path, but the engine would report a `worktreePath`
/// that names a different, non-existent location. This is the end-to-end
/// half — it is what makes the defect user-visible (`wt new` reporting
/// `ok: true` with a path nothing was created at) rather than a helper
/// detail.
@Test(arguments: FixtureRepository.RefFormat.supported())
func worktreeAddIntoATwoDeepMissingParentReportsWhereItActuallyCreatedTheWorktree(
    format: FixtureRepository.RefFormat
) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])

    // Two new path components, neither existing before `worktreeAdd` runs:
    // a missing middle directory and the worktree leaf under it.
    let middle = repo.url.deletingLastPathComponent()
        .appendingPathComponent("yard-wt-deep-\(UUID().uuidString.prefix(6))")
    let path = middle.appendingPathComponent("leaf")
    #expect(!FileManager.default.fileExists(atPath: middle.path))
    defer { try? FileManager.default.removeItem(at: middle) }

    let result = try worktreeAdd(
        at: repo.url.path, path: path.path, target: .newBranch(name: "deep-new"))
    #expect(result.success)
    #expect(result.error == nil)

    // The oracle: re-canonicalize the same requested path now that
    // `worktreeAdd` has created it. At this point every component exists,
    // so this call takes `canonicalize`'s `realpath(3)` fast path, not the
    // missing-tail walk under test, and is unaffected by the mutation.
    let expected = WorktreeContext.canonicalize(path.path)

    // The user-visible defect: under the mutation, `result.worktreePath`
    // names a reversed, never-created location.
    #expect(result.worktreePath == expected)
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: result.worktreePath, isDirectory: &isDirectory)
    #expect(exists, "the reported worktreePath must be where the worktree was actually created")
    #expect(isDirectory.boolValue)
}

// MARK: - Pure (argument vector and classifier)

@Test func argumentsNeverContainForce() {
    let targets: [WorktreeAddTarget] = [
        .newBranch(name: "b"), .newBranch(name: "b", from: "abc"),
        .branch("b"), .detached(at: "abc"),
    ]
    for target in targets {
        for agentID in [nil, "a1"] {
            for populate in [true, false] {
                let args = worktreeAddArguments(
                    path: "/somewhere/x", target: target, agentID: agentID, populate: populate)
                #expect(!args.contains("--force"))
                #expect(args.prefix(2) == ["worktree", "add"])
            }
        }
    }
}

@Test func agentArgumentsLockAtomicallyWithThePrefixedReason() throws {
    let args = worktreeAddArguments(
        path: "/somewhere/x", target: .newBranch(name: "b"), agentID: "s-42", populate: true)
    let lockIndex = try #require(args.firstIndex(of: "--lock"))
    #expect(args[lockIndex + 1] == "--reason")
    #expect(args[lockIndex + 2] == "switchyard-agent:session=s-42")
    #expect(args[lockIndex + 2].hasPrefix(WorktreePrune.agentLockReasonPrefix))

    // No agent id, no lock arguments at all.
    let plain = worktreeAddArguments(
        path: "/somewhere/x", target: .newBranch(name: "b"), agentID: nil, populate: true)
    #expect(!plain.contains("--lock"))
    #expect(!plain.contains("--reason"))
}

@Test func populateFalseMapsToNoCheckout() {
    let bare = worktreeAddArguments(
        path: "/somewhere/x", target: .branch("b"), agentID: nil, populate: false)
    #expect(bare.contains("--no-checkout"))
    let full = worktreeAddArguments(
        path: "/somewhere/x", target: .branch("b"), agentID: nil, populate: true)
    #expect(!full.contains("--no-checkout"))
}

@Test func classifierMapsEachMeasuredStderrShape() {
    // Every literal below is real git 2.50.1 stderr, measured 2026-08-07.
    #expect(classifyWorktreeAddFailure(
        exitCode: 128,
        stderr: "Preparing worktree (checking out 'feature')\nfatal: 'feature' is already used by worktree at '/somewhere/probe/repo-feature'\n")
        == .branchInUse(branch: "feature", holderPath: nil, holderIsMainWorktree: false))
    #expect(classifyWorktreeAddFailure(
        exitCode: 255,
        stderr: "Preparing worktree (new branch 'feature')\nfatal: a branch named 'feature' already exists\n")
        == .branchExists("feature"))
    #expect(classifyWorktreeAddFailure(
        exitCode: 255,
        stderr: "fatal: 'bad..name' is not a valid branch name\nhint: See `man git check-ref-format`\nhint: Disable this message with \"git config set advice.refSyntax false\"\n")
        == .invalidBranchName("bad..name"))
    #expect(classifyWorktreeAddFailure(
        exitCode: 128, stderr: "fatal: '../repo-exists' already exists\n")
        == .pathExists("../repo-exists"))
    #expect(classifyWorktreeAddFailure(
        exitCode: 128, stderr: "fatal: invalid reference: deadbeef\n")
        == .invalidReference("deadbeef"))
    #expect(classifyWorktreeAddFailure(exitCode: 1, stderr: "something else\n")
        == .unknownFailure(code: 1, stderr: "something else\n"))
}
