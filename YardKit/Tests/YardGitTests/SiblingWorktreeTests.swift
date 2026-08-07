// SiblingWorktreeTests.swift — tests for siblingWorktree (#0109)

import Testing
@testable import YardGit

// MARK: - Tests

@Test(arguments: FixtureRepository.RefFormat.supported())
func siblingHoldsBranch(_ format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("a")])

    let wt = try repo.addWorktree(named: "agent", branch: "feature")
    let result = try siblingWorktree(holding: "feature", at: repo.url.path)

    let r = try #require(result, "siblingWorktree should find the linked worktree")
    #expect(r.path == wt.path, "path should be the linked worktree")
    #expect(r.path != repo.url.path, "path must differ from the caller's own path")
    #expect(r.branch == "feature", "branch should be 'feature'")
    #expect(r.isCurrent == false, "isCurrent should be false for a sibling")
    #expect(r.isMainWorktree == false, "isMainWorktree should be false for a linked worktree")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func mainWorktreeReportedFromLinked(_ format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("a")])

    let wt = try repo.addWorktree(named: "agent", branch: "feature")
    let result = try siblingWorktree(holding: "main", at: wt.path)

    let r = try #require(result, "siblingWorktree should find the main worktree from a linked one")
    #expect(r.path == repo.url.path, "path should be the main worktree")
    #expect(r.path != wt.path, "path must differ from the linked worktree path")
    #expect(r.isMainWorktree == true, "should be reported as the main worktree")
    #expect(r.isCurrent == false, "isCurrent should be false when queried from a linked worktree")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func ownWorktreeReportsIsCurrent(_ format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("a")])

    let result = try siblingWorktree(holding: "main", at: repo.url.path)

    let r = try #require(result, "siblingWorktree should find the main worktree from itself")
    #expect(r.path == repo.url.path, "path should be the caller's own path")
    #expect(r.isCurrent == true, "isCurrent should be true when querying from the same worktree")
    #expect(r.isMainWorktree == true, "should be reported as the main worktree")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func unheldBranchReportsNothing(_ format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("a")])

    try repo.branch("idle")

    let result = try siblingWorktree(holding: "idle", at: repo.url.path)
    #expect(result == nil, "unheld branch should produce no result")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func detachedWorktreeHoldsNoBranch(_ format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    
    // Create a commit first so we can detach from it
    try repo.build([.init("a")])
    
    let wt = try repo.addWorktree(named: "det", branch: "doomed")

    try GitProcess().run(["checkout", "-q", "--detach"], workingDirectory: wt.path)

    let result = try siblingWorktree(holding: "doomed", at: repo.url.path)
    #expect(result == nil, "a detached worktree should not hold a branch")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func fullRefNameMatchesShortName(_ format: FixtureRepository.RefFormat) throws {
    let repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    let wt = try repo.addWorktree(named: "agent", branch: "feature")

    let full = try siblingWorktree(holding: "refs/heads/feature", at: wt.path)
    let short = try siblingWorktree(holding: "feature", at: wt.path)

    let s = try #require(short, "short name should resolve")
    let f = try #require(full, "full ref name should also resolve")
    #expect(f == s, "full and short names should return equal results")
}
