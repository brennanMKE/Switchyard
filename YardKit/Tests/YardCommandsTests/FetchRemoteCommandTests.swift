// FetchRemoteCommandTests.swift — `fetch <remote>` (guide §11 decisions 41, 43).
// Every remote is a bare repository in a temporary directory; nothing touches
// the network.

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

@Suite("fetch <remote> engine arm")
struct FetchRemoteCommandTests {

    @Test func aFlagShapedRemoteIsAUsageFailureBeforeAnyRepositoryAccess() throws {
        let empty = try nonRepositoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: empty) }
        for argv in [["fetch", "--prune"], ["fetch", "-v"], ["fetch", "origin", "main"]] {
            let reply = try runArm(argv, in: empty)
            #expect(reply.exitCode == .usage, "\(argv): \(reply.stdout)")
        }
    }

    /// Only the named remote moves, and one journal entry is written.
    @Test func fetchesOnlyTheNamedRemote() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let origin = try repo.addUpstream()
        let backup = try repo.addUpstream(remoteName: "backup")
        defer {
            try? FileManager.default.removeItem(at: origin)
            try? FileManager.default.removeItem(at: backup)
        }
        let tip = try repo.revParse("HEAD")
        try git(["update-ref", "refs/remotes/origin/main", "HEAD~1"], in: repo.url.path)
        try git(["update-ref", "refs/remotes/backup/main", "HEAD~1"], in: repo.url.path)
        let before = try journalCount(in: repo.url.path)

        let reply = try runArm(["fetch", "backup"], in: repo.url.path)

        #expect(reply.exitCode == .success)
        #expect(try payload(reply)["remotes"] as? [String] == ["backup"])
        #expect(try repo.revParse("backup/main") == tip)
        #expect(try repo.revParse("origin/main") == (try repo.revParse("HEAD~1")))
        #expect(try journalCount(in: repo.url.path) == before + 1)
    }

    @Test func anUnknownRemoteIsExitSixAndJournalsNothing() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let before = try journalCount(in: repo.url.path)
        let reply = try runArm(["fetch", "nope"], in: repo.url.path)
        #expect(reply.exitCode == .repositoryError)
        #expect(try journalCount(in: repo.url.path) == before)
    }
}
