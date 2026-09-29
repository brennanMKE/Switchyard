// CommitCommandTests.swift — the `commit` arm (guide §11 decision 37)

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

@Suite("commit engine arm")
struct CommitCommandTests {

    @Test func commitMalformedArgumentsAreUsageFailuresBeforeAnyRepositoryAccess() throws {
        let empty = try nonRepositoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: empty) }
        let cases: [[String]] = [
            ["commit"],                                          // no --message, no --amend
            ["commit", "--sign"],                                // still no --message
            ["commit", "--message"],                             // value missing
            ["commit", "--message", "a", "--message", "b"],      // duplicated
            ["commit", "--message", "m", "extra"],               // positional
            ["commit", "--message", "m", "--sign", "--no-sign"], // contradictory
            ["commit", "--amend", "--amend"],                    // duplicated
            ["commit", "--message", "m", "--hunk", "h"],         // unknown flag
        ]
        for argv in cases {
            let reply = try runArm(argv, in: empty)
            #expect(reply.exitCode == .usage, "\(argv): \(reply.stdout)")
        }
    }

    @Test func commitsTheIndexWithTheMessageAndOneJournalEntry() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("a changed\n", to: "a.txt", in: repo)
        try git(["add", "a.txt"], in: repo.url.path)
        let parent = try repo.revParse("HEAD")
        let before = try journalCount(in: repo.url.path)

        let reply = try runArm(["commit", "--message", "Change a"], in: repo.url.path)

        #expect(reply.exitCode == .success)
        let result = try payload(reply)
        #expect(result["oid"] as? String == (try repo.revParse("HEAD")))
        #expect(result["amended"] as? Bool == false)
        #expect(try repo.revParse("HEAD~1") == parent)
        #expect(try git(["log", "-1", "--format=%s"], in: repo.url.path) == "Change a")
        #expect(try journalCount(in: repo.url.path) == before + 1)
    }

    @Test func nothingStagedIsExitSix() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let reply = try runArm(["commit", "--message", "empty"], in: repo.url.path)
        #expect(reply.exitCode == .repositoryError)
        #expect(try errorCode(reply) == "repository_error")
    }

    /// `--amend` without `--message` keeps HEAD's message and replaces HEAD.
    @Test func amendWithoutAMessageKeepsHeadsMessage() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let old = try repo.revParse("HEAD")
        try write("c amended\n", to: "c.txt", in: repo)
        try git(["add", "c.txt"], in: repo.url.path)

        let reply = try runArm(["commit", "--amend"], in: repo.url.path)

        #expect(reply.exitCode == .success)
        #expect(try payload(reply)["amended"] as? Bool == true)
        #expect(try repo.revParse("HEAD") != old)
        #expect(try repo.revParse("HEAD~1") == (try repo.revParse("\(old)~1")))
        #expect(try git(["log", "-1", "--format=%B"], in: repo.url.path) == "c")
        #expect(try git(["show", "HEAD:c.txt"], in: repo.url.path) == "c amended")
    }

    @Test func amendWithAMessageRewordsHead() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let reply = try runArm(["commit", "--amend", "--message", "Better"], in: repo.url.path)
        #expect(reply.exitCode == .success)
        #expect(try git(["log", "-1", "--format=%s"], in: repo.url.path) == "Better")
    }

    /// A pushed HEAD is refused by the engine, before any entry is written.
    @Test func amendingAPushedHeadIsExitSixWithNoEntry() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let bare = try repo.addUpstream()
        defer { try? FileManager.default.removeItem(at: bare) }
        let head = try repo.revParse("HEAD")
        let before = try journalCount(in: repo.url.path)

        let reply = try runArm(["commit", "--amend", "--message", "x"], in: repo.url.path)

        #expect(reply.exitCode == .repositoryError)
        #expect(try repo.revParse("HEAD") == head)
        #expect(try journalCount(in: repo.url.path) == before)
    }
}
