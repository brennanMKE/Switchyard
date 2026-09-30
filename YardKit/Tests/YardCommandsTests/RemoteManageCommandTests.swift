// RemoteManageCommandTests.swift — the `remote` arm (guide §11 decisions 41, 43).
// Every remote is a bare repository in a temporary directory; nothing touches
// the network.

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

@Suite("remote engine arm")
struct RemoteManageCommandTests {

    @Test func remoteMalformedArgumentsAreUsageFailuresBeforeAnyRepositoryAccess() throws {
        let empty = try nonRepositoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: empty) }
        let cases: [[String]] = [
            ["remote"],                                    // never git's implicit list
            ["remote", "show", "origin"],                  // unknown subcommand
            ["remote", "list", "extra"],
            ["remote", "add", "x"],                        // url missing
            ["remote", "add", "x", "https://example.invalid/u.git", "extra"],
            ["remote", "add", "-f", "x", "https://example.invalid/u.git"],            // git's flag, not this surface's
            ["remote", "set-url", "x"],
            ["remote", "rename", "x"],
            ["remote", "remove"],
            ["remote", "prune", "a", "b"],
            ["remote", "remove", "--", "x"],               // no flags, not even --
        ]
        for argv in cases {
            let reply = try runArm(argv, in: empty)
            #expect(reply.exitCode == .usage, "\(argv): \(reply.stdout)")
            #expect(try errorCode(reply) == "usage")
        }
    }

    @Test func listReportsEachRemoteWithItsURLs() throws {
        let (repo, bare) = try trackedFixture()
        defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }
        try git(["remote", "add", "mirror", "https://example.invalid/fetch.git"], in: repo.url.path)
        try git(["remote", "set-url", "--push", "mirror", "https://example.invalid/push.git"], in: repo.url.path)

        let remotes = try #require(try payload(try runArm(["remote", "list"], in: repo.url.path))["remotes"] as? [[String: Any]])

        #expect(remotes.map { $0["name"] as? String } == ["mirror", "origin"])
        #expect(remotes[0]["fetchURL"] as? String == "https://example.invalid/fetch.git")
        #expect(remotes[0]["pushURLs"] as? [String] == ["https://example.invalid/push.git"])
        #expect(remotes[1]["fetchURL"] as? String == bare.path)
    }

    /// Add and set-url are configuration: not journaled, reported undoable:false.
    @Test func addAndSetURLWriteNoJournalEntry() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let before = try journalCount(in: repo.url.path)

        let added = try payload(try runArm(["remote", "add", "upstream", "https://example.invalid/one.git"], in: repo.url.path))
        let moved = try payload(try runArm(["remote", "set-url", "upstream", "https://example.invalid/two.git"], in: repo.url.path))

        #expect((added["remote"] as? [String: Any])?["fetchURL"] as? String == "https://example.invalid/one.git")
        #expect(added["undoable"] as? Bool == false)
        #expect((moved["remote"] as? [String: Any])?["fetchURL"] as? String == "https://example.invalid/two.git")
        #expect(try git(["config", "remote.upstream.url"], in: repo.url.path) == "https://example.invalid/two.git")
        #expect(try journalCount(in: repo.url.path) == before)
    }

    @Test func refusalsAreExitSix() throws {
        let (repo, bare) = try trackedFixture()
        defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }
        for argv in [
            ["remote", "add", "origin", "https://example.invalid/x.git"],        // name in use
            ["remote", "add", "origin/x", "https://example.invalid/x.git"],      // nests with origin
            ["remote", "add", "a..b", "https://example.invalid/x.git"],          // git would refuse the name
            ["remote", "set-url", "nope", "https://example.invalid/x.git"],      // unknown remote
            ["remote", "rename", "nope", "other"],
            ["remote", "remove", "nope"],
            ["remote", "prune", "nope"],
        ] {
            let reply = try runArm(argv, in: repo.url.path)
            #expect(reply.exitCode == .repositoryError, "\(argv): \(reply.stdout)")
        }
    }

    @Test func renameMovesTheBranchesAndTheUpstream() throws {
        let (repo, bare) = try trackedFixture()
        defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }
        let before = try journalCount(in: repo.url.path)

        let result = try payload(try runArm(["remote", "rename", "origin", "hub"], in: repo.url.path))

        #expect(result["name"] as? String == "hub")
        #expect(result["previousName"] as? String == "origin")
        #expect(result["trackingBranches"] as? [String] == ["hub/main"])
        #expect(result["upstreamOf"] as? [String] == ["main"])
        #expect(result["undoable"] as? Bool == false)
        #expect(try git(["config", "branch.main.remote"], in: repo.url.path) == "hub")
        #expect(try journalCount(in: repo.url.path) == before + 1)
    }

    /// Decision 41's refusal, visible over the CLI: after `remote remove`,
    /// `undo` exits 6 naming the operation, and nothing comes back.
    @Test func removeReportsWhatWentAndUndoRefusesToCrossIt() throws {
        let (repo, bare) = try trackedFixture()
        defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }

        let result = try payload(try runArm(["remote", "remove", "origin"], in: repo.url.path))

        #expect(result["removed"] as? String == "origin")
        #expect(result["trackingBranches"] as? [String] == ["origin/main"])
        #expect(result["upstreamOf"] as? [String] == ["main"])
        #expect(result["undoable"] as? Bool == false)

        let undo = try runArm(["undo"], in: repo.url.path)

        #expect(undo.exitCode == .repositoryError)
        #expect(undo.stdout.contains("remote-remove"))
        #expect(try git(["for-each-ref", "refs/remotes/"], in: repo.url.path) == "")
    }

    /// Prune deletes what the remote no longer has, and undo brings it back.
    @Test func pruneReportsThePrunedBranchesAndUndoRestoresThem() throws {
        let (repo, bare) = try trackedFixture()
        defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }
        try git(["push", "-q", "origin", "HEAD:refs/heads/gone"], in: repo.url.path)
        try git(["fetch", "-q", "origin"], in: repo.url.path)
        try git(["update-ref", "-d", "refs/heads/gone"], in: bare.path)
        let gone = try repo.revParse("origin/gone")

        let result = try payload(try runArm(["remote", "prune", "origin"], in: repo.url.path))

        #expect(result["pruned"] as? [String] == ["origin/gone"])
        #expect(result["undoable"] as? Bool == true)
        let left = try git(["for-each-ref", "--format=%(refname)", "refs/remotes/origin/"], in: repo.url.path)
        #expect(!left.contains("refs/remotes/origin/gone"))
        #expect(left.contains("refs/remotes/origin/main"))

        #expect(try runArm(["undo"], in: repo.url.path).exitCode == .success)
        #expect(try repo.revParse("origin/gone") == gone)
    }
}
