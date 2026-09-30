// FileHistoryCommandTests.swift — the `file-history` arm (guide §11 decisions 39, 43)

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

@Suite("file-history engine arm")
struct FileHistoryCommandTests {

    @Test func fileHistoryMalformedArgumentsAreUsageFailuresBeforeAnyRepositoryAccess() throws {
        let empty = try nonRepositoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: empty) }
        let cases: [[String]] = [
            ["file-history"],                                     // no path
            ["file-history", "a.txt", "b.txt"],                   // two paths (--follow takes one)
            ["file-history", "a.txt", "--revision"],              // value missing
            ["file-history", "a.txt", "--revision", "--all"],     // a value git would read as an option
            ["file-history", "a.txt", "--revision", "HEAD", "--revision", "HEAD"],
            ["file-history", "a.txt", "--follow"],                // not a flag of this surface
            ["file-history", "--"],                               // -- and no path
        ]
        for argv in cases {
            let reply = try runArm(argv, in: empty)
            #expect(reply.exitCode == .usage, "\(argv): \(reply.stdout)")
            #expect(try errorCode(reply) == "usage")
        }
    }

    /// Follows the file across a rename: the rename row names both paths,
    /// and the commit that created it under its old name is listed too.
    @Test func followsARename() throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }
        try repo.build([
            FixtureRepository.Commit("add", files: ["old.txt": "one\ntwo\nthree\n"]),
            FixtureRepository.Commit("other", files: ["x.txt": "x\n"]),
        ])
        try git(["mv", "old.txt", "new.txt"], in: repo.url.path)
        try git(["commit", "-q", "-m", "rename"], in: repo.url.path)

        let reply = try runArm(["file-history", "new.txt"], in: repo.url.path)

        #expect(reply.exitCode == .success)
        let result = try payload(reply)
        #expect(result["path"] as? String == "new.txt")
        #expect(result["revision"] as? String == "HEAD")
        let commits = try #require(result["commits"] as? [[String: Any]])
        #expect(commits.map { $0["subject"] as? String } == ["rename", "add"])
        #expect(commits[0]["status"] as? String == "R")
        #expect(commits[0]["previousPath"] as? String == "old.txt")
        #expect(commits[1]["status"] as? String == "A")
        #expect(commits[1]["path"] as? String == "old.txt")
        #expect(commits[1]["previousPath"] == nil)
        #expect(commits[1]["oid"] as? String == repo.oids["add"])
    }

    @Test func revisionStartsTheWalkThere() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("a changed\n", to: "a.txt", in: repo)
        try git(["commit", "-q", "-am", "change a"], in: repo.url.path)

        let head = try #require(try payload(try runArm(["file-history", "a.txt"], in: repo.url.path))["commits"] as? [[String: Any]])
        let earlier = try #require(try payload(try runArm(
            ["file-history", "a.txt", "--revision", "HEAD~1"], in: repo.url.path))["commits"] as? [[String: Any]])

        #expect(head.count == 2)
        #expect(earlier.count == 1)
        #expect(earlier.first?["subject"] as? String == "a")
    }

    /// Paths are repository-relative whatever the caller's directory.
    @Test func pathsAreRepositoryRelativeFromASubdirectory() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("s\n", to: "sub/s.txt", in: repo)
        try git(["add", "sub/s.txt"], in: repo.url.path)
        try git(["commit", "-q", "-m", "sub"], in: repo.url.path)

        let result = try payload(try runArm(["file-history", "b.txt"], in: repo.url.appendingPathComponent("sub").path))

        #expect((result["commits"] as? [[String: Any]])?.count == 1)
    }

    @Test func aPathNoCommitTouchedIsAnEmptyList() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let result = try payload(try runArm(["file-history", "never.txt"], in: repo.url.path))
        #expect((result["commits"] as? [Any])?.isEmpty == true)
    }

    /// The path is literal: a glob names a file called `*.txt`, which no
    /// commit touched — not every `.txt` file.
    @Test func aGlobIsAPathNotAPattern() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let result = try payload(try runArm(["file-history", "*.txt"], in: repo.url.path))
        #expect((result["commits"] as? [Any])?.isEmpty == true)
    }

    @Test func anUnknownRevisionIsExitSix() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let reply = try runArm(["file-history", "a.txt", "--revision", "nope"], in: repo.url.path)
        #expect(reply.exitCode == .repositoryError)
    }
}
