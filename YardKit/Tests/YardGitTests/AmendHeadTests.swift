// AmendHeadTests.swift — what Amend would rewrite, and the amend itself (#0463, #0464)
//
// NO NETWORK: the only remote is a bare repository in a temporary directory.
// NO SIGNING KEY is created or used: FixtureRepository sets
// commit.gpgsign=false and the hermetic environment blanks global and
// system config.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

// MARK: - #0463: AmendHead.target

@Test(arguments: FixtureRepository.RefFormat.supported())
func amendTargetReadsHeadAndItsFullMessage(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    try GitProcess().run(
        ["commit", "-q", "--allow-empty", "-m", "Subject line", "-m", "Body paragraph."],
        workingDirectory: repo.url.path)

    let target = try AmendHead.target(at: repo.url.path, extraEnvironment: hermetic)

    #expect(target.oid == (try repo.revParse("HEAD")))
    #expect(target.message == "Subject line\n\nBody paragraph.")
    #expect(target.refusal == nil)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func amendTargetRefusesAnUnbornBranch(format: FixtureRepository.RefFormat) throws {
    let repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }

    let target = try AmendHead.target(at: repo.url.path, extraEnvironment: hermetic)

    #expect(target.oid == nil)
    #expect(target.message == "")
    #expect(target.refusal == .noCommits)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func amendTargetRefusesACommitItsUpstreamContains(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    let bare = try repo.addUpstream()
    defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }
    // A second remote branch at the same commit, sorting before the
    // upstream: the upstream is the one named.
    try GitProcess().run(["push", "-q", "origin", "main:aaa"], workingDirectory: repo.url.path)
    try GitProcess().run(["fetch", "-q", "origin"], workingDirectory: repo.url.path)

    let pushed = try AmendHead.target(at: repo.url.path, extraEnvironment: hermetic)
    #expect(pushed.refusal == .pushed(remoteRef: "origin/main"))

    try repo.build([.init("local", files: ["a.txt": "two\n"])])
    let local = try AmendHead.target(at: repo.url.path, extraEnvironment: hermetic)
    #expect(local.refusal == nil, "a commit only on the local branch can be amended")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func amendTargetRefusesACommitAnyRemoteBranchContains(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    let bare = try repo.addUpstream()
    defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }
    // `git fetch` also writes origin/HEAD, a symbolic ref, which sorts first
    // and must be skipped.
    try GitProcess().run(["fetch", "-q", "origin"], workingDirectory: repo.url.path)
    // A new branch at origin/main's commit, with no upstream of its own.
    try GitProcess().run(["switch", "-q", "-c", "topic"], workingDirectory: repo.url.path)

    let target = try AmendHead.target(at: repo.url.path, extraEnvironment: hermetic)

    #expect(target.refusal == .pushed(remoteRef: "origin/main"))
}

// MARK: - #0464: AmendHead.run
