// RemoteCommandTests.swift — the `fetch`, `pull` and `push` arms (guide §11
// decisions 32 and 37). Every remote is a bare repository in a temporary
// directory; nothing touches the network.

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

/// `a → b → c` on `main`, pushed to a bare `origin` with upstream set.
private func trackedFixture() throws -> (repo: FixtureRepository, bare: URL) {
    let repo = try FixtureRepository.linear()
    return (repo, try repo.addUpstream())
}

@Suite("fetch/pull/push engine arms")
struct RemoteCommandTests {

    @Test func anyArgumentIsAUsageFailure() throws {
        let empty = try nonRepositoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: empty) }
        for command in ["fetch", "pull", "push"] {
            // fetch takes one <remote> (guide §11 decision 43), so its bad tail is two.
            let named = command == "fetch" ? ["origin", "upstream"] : ["origin"]
            for tail in [named, ["--force"], ["--all"]] {
                let reply = try runArm([command] + tail, in: empty)
                #expect(reply.exitCode == .usage, "\(command) \(tail): \(reply.stdout)")
            }
        }
    }

    @Test func fetchMovesTheRemoteTrackingRefAndListsTheRemotes() throws {
        let (repo, bare) = try trackedFixture()
        defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }
        let tip = try repo.revParse("origin/main")
        try git(["update-ref", "refs/remotes/origin/main", "HEAD~1"], in: repo.url.path)
        let before = try journalCount(in: repo.url.path)

        let reply = try runArm(["fetch"], in: repo.url.path)

        #expect(reply.exitCode == .success)
        #expect(try payload(reply)["remotes"] as? [String] == ["origin"])
        #expect(try repo.revParse("origin/main") == tip)
        #expect(try journalCount(in: repo.url.path) == before + 1)
    }

    @Test func pullFastForwardsAndReportsBothOids() throws {
        let (repo, bare) = try trackedFixture()
        defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }
        let tip = try repo.revParse("HEAD")
        let behind = try repo.revParse("HEAD~1")
        try git(["reset", "-q", "--hard", "HEAD~1"], in: repo.url.path)

        let reply = try runArm(["pull"], in: repo.url.path)

        #expect(reply.exitCode == .success)
        let result = try payload(reply)
        #expect(result["outcome"] as? String == "fastForwarded")
        #expect(result["from"] as? String == behind)
        #expect(result["to"] as? String == tip)
        #expect(try repo.revParse("HEAD") == tip)
    }

    @Test func pullWhenUpToDateOmitsTheOids() throws {
        let (repo, bare) = try trackedFixture()
        defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }
        let result = try payload(try runArm(["pull"], in: repo.url.path))
        #expect(result["outcome"] as? String == "upToDate")
        #expect(result["from"] == nil)
        #expect(result["to"] == nil)
    }

    @Test func pullWithoutAnUpstreamIsExitSix() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        #expect(try runArm(["pull"], in: repo.url.path).exitCode == .repositoryError)
    }

    @Test func pushSendsTheBranchToItsUpstream() throws {
        let (repo, bare) = try trackedFixture()
        defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }
        try write("d\n", to: "d.txt", in: repo)
        try git(["add", "d.txt"], in: repo.url.path)
        try git(["commit", "-q", "-m", "d"], in: repo.url.path)

        let reply = try runArm(["push"], in: repo.url.path)

        #expect(reply.exitCode == .success)
        let result = try payload(reply)
        #expect(result["remote"] as? String == "origin")
        #expect(result["remoteRef"] as? String == "refs/heads/main")
        #expect(result["setUpstream"] as? Bool == false)
        #expect(try git(["rev-parse", "main"], in: bare.path) == (try repo.revParse("HEAD")))
    }

    @Test func pushingABranchWithNoUpstreamSetsIt() throws {
        let (repo, bare) = try trackedFixture()
        defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }
        try git(["switch", "-q", "-c", "topic"], in: repo.url.path)

        let result = try payload(try runArm(["push"], in: repo.url.path))

        #expect(result["remoteRef"] as? String == "refs/heads/topic")
        #expect(result["setUpstream"] as? Bool == true)
        #expect(try git(["rev-parse", "--abbrev-ref", "topic@{upstream}"], in: repo.url.path) == "origin/topic")
    }
}
