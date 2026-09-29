// StageCommandTests.swift — the `stage` and `unstage` arms (guide §11
// decision 37)

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

@Suite("stage/unstage engine arms")
struct StageCommandTests {

    @Test func malformedArgumentsAreUsageFailuresBeforeAnyRepositoryAccess() throws {
        let empty = try nonRepositoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: empty) }
        for command in ["stage", "unstage"] {
            for tail in [[], ["--bogus"], ["a.txt", "--hunk", "h"], ["--hunk"], ["-x"]] {
                let reply = try runArm([command] + tail, in: empty)
                #expect(reply.exitCode == .usage, "\(command) \(tail): \(reply.stdout)")
                #expect(try errorCode(reply) == "usage")
            }
        }
    }

    @Test func outsideARepositoryIsExitSix() throws {
        let empty = try nonRepositoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: empty) }
        let reply = try runArm(["stage", "a.txt"], in: empty)
        #expect(reply.exitCode == .repositoryError)
    }

    /// Run from a subdirectory, a path still names the file at the top:
    /// paths are repository-relative, as `status` prints them.
    @Test func stagesRepositoryRelativePathsFromASubdirectory() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("a changed\n", to: "a.txt", in: repo)
        try write("new\n", to: "sub/new.txt", in: repo)
        let before = try journalCount(in: repo.url.path)

        let reply = try runArm(["stage", "a.txt", "sub/new.txt"],
                               in: repo.url.appendingPathComponent("sub").path)

        #expect(reply.exitCode == .success)
        #expect(try payload(reply)["paths"] as? [String] == ["a.txt", "sub/new.txt"])
        #expect(try payload(reply)["hunks"] == nil)
        #expect(try git(["diff", "--cached", "--name-only"], in: repo.url.path) == "a.txt\nsub/new.txt")
        #expect(try journalCount(in: repo.url.path) == before + 1)
    }

    @Test func aPathStartingWithADashFollowsTheSeparator() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("x\n", to: "--hunk", in: repo)
        let reply = try runArm(["stage", "--", "--hunk"], in: repo.url.path)
        #expect(reply.exitCode == .success)
        #expect(try git(["diff", "--cached", "--name-only"], in: repo.url.path) == "--hunk")
    }

    @Test func stagesAndUnstagesAHunkById() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("a\nmore\n", to: "a.txt", in: repo)
        let id = try #require(try listHunks(at: repo.url.path, area: .unstaged).first?.hunks.first?.id)

        let staged = try runArm(["stage", "--hunk", id], in: repo.url.path)
        #expect(staged.exitCode == .success)
        #expect(try payload(staged)["hunks"] as? [String] == [id])
        #expect(try git(["diff", "--cached", "--name-only"], in: repo.url.path) == "a.txt")

        let stagedID = try #require(try listHunks(at: repo.url.path, area: .staged).first?.hunks.first?.id)
        let unstaged = try runArm(["unstage", "--hunk", stagedID], in: repo.url.path)
        #expect(unstaged.exitCode == .success)
        #expect(try git(["diff", "--cached", "--name-only"], in: repo.url.path) == "")
    }

    @Test func anUnknownHunkIdIsExitSixAndStagesNothing() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("a\nmore\n", to: "a.txt", in: repo)
        let reply = try runArm(["stage", "--hunk", "000000000000"], in: repo.url.path)
        #expect(reply.exitCode == .repositoryError)
        #expect(try git(["diff", "--cached", "--name-only"], in: repo.url.path) == "")
    }

    /// A staged rename is one status record named by its new path;
    /// unstaging only that would leave the old path staged as a deletion.
    @Test func unstagingARenameByItsNewPathUnstagesBothSides() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try git(["mv", "a.txt", "renamed.txt"], in: repo.url.path)

        let reply = try runArm(["unstage", "renamed.txt"], in: repo.url.path)

        #expect(reply.exitCode == .success)
        #expect(try payload(reply)["paths"] as? [String] == ["renamed.txt"])
        #expect(try git(["diff", "--cached", "--name-only"], in: repo.url.path) == "")
    }
}
