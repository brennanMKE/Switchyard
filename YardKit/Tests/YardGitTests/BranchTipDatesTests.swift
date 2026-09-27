// BranchTipDatesTests.swift — the branch map's recency and root read (#0428)
//
// NO SIGNING KEY IS CREATED OR USED ANYWHERE IN THIS FILE. Every fixture is
// a throwaway repository under NSTemporaryDirectory built by
// FixtureRepository, which pins commit.gpgsign=false.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

@Test func tipDatesParseSkipsRemoteHEADAndThrowsOnMalformedLines() throws {
    let text = [
        "refs/heads/main\t1700000100",
        "refs/remotes/origin/HEAD\t1700000100",
        "refs/remotes/origin/main\t1700000000",
    ].joined(separator: "\n")
    #expect(try BranchTipDates.parse(text) == [
        "refs/heads/main": 1_700_000_100, "refs/remotes/origin/main": 1_700_000_000,
    ])
    #expect(throws: BranchTipDates.Error.self) { _ = try BranchTipDates.parse("refs/heads/main") }
    #expect(throws: BranchTipDates.Error.self) { _ = try BranchTipDates.parse("refs/heads/main\tyesterday") }
}

@Test func tipDatesReadEachCommitterDateAndTheOriginHEADDefault() async throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("c1")])
    try repo.addUpstream(branch: "main")
    let git = GitProcess()
    // A branch whose tip is dated 2023-11-14, an old branch by any filter.
    try await git.run(["switch", "-q", "-c", "old"], workingDirectory: repo.url.path)
    try await git.run(
        ["commit", "-q", "--allow-empty", "-m", "old"], workingDirectory: repo.url.path,
        extraEnvironment: hermetic.merging(
            ["GIT_COMMITTER_DATE": "1700000000 +0000", "GIT_AUTHOR_DATE": "1700000000 +0000"]) { $1 })
    // Push alone creates no origin/HEAD (BranchStatusTests measured it):
    // point it at origin/old so the default is visibly not the literal main.
    try await git.run(["push", "-q", "origin", "old"], workingDirectory: repo.url.path, extraEnvironment: hermetic)
    try await git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/old"],
                      workingDirectory: repo.url.path, extraEnvironment: hermetic)

    let report = try await BranchTipDates.read(at: repo.url.path, git: git)

    #expect(report.defaultBranch == "old", "origin/HEAD's target, not a hardcoded main")
    #expect(report.dates["refs/heads/old"] == 1_700_000_000)
    #expect(report.dates["refs/remotes/origin/old"] == 1_700_000_000)
    #expect(Set(report.dates.keys) == [
        "refs/heads/main", "refs/heads/old", "refs/remotes/origin/main", "refs/remotes/origin/old",
    ], "origin/HEAD is skipped")
    let main = try #require(report.dates["refs/heads/main"])
    #expect(main > 1_700_000_000, "main's tip was committed now, not in 2023")
}
