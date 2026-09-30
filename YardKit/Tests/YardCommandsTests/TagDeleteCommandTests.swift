// TagDeleteCommandTests.swift — `tag --delete <name>` (guide §11 decisions 38, 43)

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

@Suite("tag --delete engine arm")
struct TagDeleteCommandTests {

    @Test func malformedDeletesAreUsageFailuresBeforeAnyRepositoryAccess() throws {
        let empty = try nonRepositoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: empty) }
        let cases: [[String]] = [
            ["tag", "--delete"],                          // no name
            ["tag", "--delete", "v1", "v2"],              // two names
            ["tag", "--delete", "--delete", "v1"],        // duplicated
            ["tag", "--delete", "v1", "--annotate"],      // a create flag
            ["tag", "--delete", "v1", "--message", "m"],  // a create flag with its value
            ["tag", "v1", "--delete", "--no-sign"],       // position does not matter
        ]
        for argv in cases {
            let reply = try runArm(argv, in: empty)
            #expect(reply.exitCode == .usage, "\(argv): \(reply.stdout)")
            #expect(try errorCode(reply) == "usage")
        }
    }

    @Test func deletesALightweightTagAsOneJournalEntry() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try git(["tag", "v1", "HEAD~1"], in: repo.url.path)
        let target = try repo.revParse("HEAD~1")
        let before = try journalCount(in: repo.url.path)

        let reply = try runArm(["tag", "--delete", "v1"], in: repo.url.path)

        #expect(reply.exitCode == .success)
        let result = try payload(reply)
        #expect(result["ref"] as? String == "refs/tags/v1")
        #expect(result["oid"] as? String == target)
        #expect(result["annotated"] as? Bool == false)
        #expect(try git(["tag", "--list"], in: repo.url.path) == "")
        #expect(try journalCount(in: repo.url.path) == before + 1)
    }

    /// An annotated tag reports its tag object, and `undo` brings it back.
    @Test func anAnnotatedTagIsRestoredByUndo() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try git(["tag", "-a", "-m", "release", "v2"], in: repo.url.path)
        let object = try repo.revParse("refs/tags/v2")

        let result = try payload(try runArm(["tag", "--delete", "v2"], in: repo.url.path))
        #expect(result["annotated"] as? Bool == true)
        #expect(result["oid"] as? String == object)

        let undo = try runArm(["undo"], in: repo.url.path)
        #expect(undo.exitCode == .success)
        #expect(try repo.revParse("refs/tags/v2") == object)
    }

    /// Decision 37's exit classes apply to the new path: no such tag is 6,
    /// not the create path's flattened 4.
    @Test func anUnknownTagIsExitSix() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let reply = try runArm(["tag", "--delete", "nope"], in: repo.url.path)
        #expect(reply.exitCode == .repositoryError)
        #expect(try errorCode(reply) == "repository_error")
    }

    /// `tag delete v1` is not a deletion: it creates a tag named `delete`,
    /// as it always has — the reason the flag is git's `--delete`.
    @Test func theWordDeleteStillCreatesATagOfThatName() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try git(["tag", "v1"], in: repo.url.path)

        let reply = try runArm(["tag", "delete", "v1"], in: repo.url.path)

        #expect(reply.exitCode == .success)
        #expect(try git(["tag", "--list"], in: repo.url.path) == "delete\nv1")
    }
}
