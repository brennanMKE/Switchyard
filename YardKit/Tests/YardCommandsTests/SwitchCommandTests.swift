// SwitchCommandTests.swift — the `switch` arm (guide §11 decisions 38, 43)

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

@Suite("switch engine arm")
struct SwitchCommandTests {

    @Test func switchMalformedArgumentsAreUsageFailuresBeforeAnyRepositoryAccess() throws {
        let empty = try nonRepositoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: empty) }
        let cases: [[String]] = [
            ["switch"],                                   // no target
            ["switch", "a", "b"],                         // two targets
            ["switch", "--track"],                        // --track with no target
            ["switch", "--detach", "HEAD", "--track"],    // both modes
            ["switch", "--detach", "--detach", "HEAD"],   // a mode twice
            ["switch", "--create", "x"],                  // not a flag of this surface
            ["switch", "-"],                              // git's "previous branch" is not supported
        ]
        for argv in cases {
            let reply = try runArm(argv, in: empty)
            #expect(reply.exitCode == .usage, "\(argv): \(reply.stdout)")
            #expect(try errorCode(reply) == "usage")
        }
    }

    @Test func switchesToALocalBranchAsOneJournalEntry() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try repo.branch("topic", at: "a")
        let before = try journalCount(in: repo.url.path)

        let reply = try runArm(["switch", "topic"], in: repo.url.path)

        #expect(reply.exitCode == .success)
        let result = try payload(reply)
        #expect(result["branch"] as? String == "topic")
        #expect(result["head"] as? String == repo.oids["a"])
        #expect(result["operation"] as? String == "switch")
        #expect(try git(["symbolic-ref", "--short", "HEAD"], in: repo.url.path) == "topic")
        #expect(try journalCount(in: repo.url.path) == before + 1)
    }

    @Test func detachReportsNoBranch() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let target = try repo.revParse("HEAD~1")

        let result = try payload(try runArm(["switch", "--detach", "HEAD~1"], in: repo.url.path))

        #expect(result["head"] as? String == target)
        #expect(result["branch"] == nil)
        #expect(result["operation"] as? String == "switch-detach")
        #expect(try git(["rev-parse", "HEAD"], in: repo.url.path) == target)
        #expect(try GitProcess().capture(["symbolic-ref", "-q", "HEAD"], workingDirectory: repo.url.path).exitCode != 0)
    }

    @Test func trackCreatesTheLocalBranchWithItsUpstream() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let bare = try repo.addUpstream()
        defer { try? FileManager.default.removeItem(at: bare) }
        try git(["push", "-q", "origin", "HEAD~1:refs/heads/feature"], in: repo.url.path)
        try git(["fetch", "-q", "origin"], in: repo.url.path)

        let result = try payload(try runArm(["switch", "--track", "origin/feature"], in: repo.url.path))

        #expect(result["branch"] as? String == "feature")
        #expect(result["operation"] as? String == "switch-track")
        #expect(try git(["rev-parse", "--abbrev-ref", "feature@{upstream}"], in: repo.url.path) == "origin/feature")
    }

    /// A change the switch would overwrite refuses the whole switch: exit 6,
    /// the path named, HEAD and the change untouched, nothing journaled.
    @Test func localChangesTheSwitchWouldOverwriteAreExitSixAndTouchNothing() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try repo.branch("old", at: "a")
        try write("edited\n", to: "b.txt", in: repo)
        let before = try journalCount(in: repo.url.path)

        let reply = try runArm(["switch", "old"], in: repo.url.path)

        #expect(reply.exitCode == .repositoryError)
        #expect(try errorCode(reply) == "repository_error")
        #expect(reply.stdout.contains("b.txt"))
        #expect(try git(["symbolic-ref", "--short", "HEAD"], in: repo.url.path) == "main")
        #expect(try git(["status", "--porcelain"], in: repo.url.path) == " M b.txt")
        #expect(try journalCount(in: repo.url.path) == before)
    }

    @Test func anUnknownBranchIsExitSix() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        #expect(try runArm(["switch", "nope"], in: repo.url.path).exitCode == .repositoryError)
    }

    /// The journal entry is the one `undo` reverses: HEAD goes back to main.
    @Test func undoPutsHeadBack() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try repo.branch("topic", at: "a")
        _ = try runArm(["switch", "topic"], in: repo.url.path)

        let undo = try runArm(["undo"], in: repo.url.path)

        #expect(undo.exitCode == .success)
        let steps = try #require(try payload(undo)["steps"] as? [[String: Any]])
        #expect(steps.first?["operation"] as? String == "switch")
        #expect(try git(["symbolic-ref", "--short", "HEAD"], in: repo.url.path) == "main")
    }
}
