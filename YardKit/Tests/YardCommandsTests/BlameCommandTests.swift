// BlameCommandTests.swift — the `blame` arm (guide §11 decisions 39, 43)

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

@Suite("blame engine arm")
struct BlameCommandTests {

    @Test func blameMalformedArgumentsAreUsageFailuresBeforeAnyRepositoryAccess() throws {
        let empty = try nonRepositoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: empty) }
        let cases: [[String]] = [
            ["blame"],
            ["blame", "a.txt", "b.txt"],
            ["blame", "a.txt", "--lines"],
            ["blame", "a.txt", "--lines", "0,2"],          // 1-based
            ["blame", "a.txt", "--lines", "3,2"],          // start > end
            ["blame", "a.txt", "--lines", "+1,2"],         // Int("+1") parses; the surface does not
            ["blame", "a.txt", "--lines", "1"],            // one number
            ["blame", "a.txt", "--lines", "1,2", "--lines", "1,2"],
            ["blame", "a.txt", "--revision", "-w"],        // an option smuggled as a value
            ["blame", "a.txt", "-L", "1,2"],               // git's flag, not this surface's
        ]
        for argv in cases {
            let reply = try runArm(argv, in: empty)
            #expect(reply.exitCode == .usage, "\(argv): \(reply.stdout)")
            #expect(try errorCode(reply) == "usage")
        }
    }

    @Test func parseLineRangeAcceptsOnlyTwoOrderedPositiveIntegers() {
        #expect(parseLineRange("1,1") == 1...1)
        #expect(parseLineRange("2,40") == 2...40)
        for bad in ["", ",", "1,", ",2", "0,1", "2,1", "+1,2", "1,+2", " 1,2", "1,2,3", "a,b"] {
            #expect(parseLineRange(bad) == nil, "'\(bad)'")
        }
    }

    /// The working tree's file: a committed line names its commit, an edited
    /// one is uncommitted (the all-zero oid), and no revision is reported.
    @Test func blamesTheWorkingTreeWithUncommittedLines() throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }
        try repo.build([
            FixtureRepository.Commit("first", files: ["f.txt": "one\ntwo\n"]),
            FixtureRepository.Commit("second", files: ["f.txt": "one\n2\n"]),
        ])
        try write("uno\n2\n", to: "f.txt", in: repo)

        let result = try payload(try runArm(["blame", "f.txt"], in: repo.url.path))

        #expect(result["path"] as? String == "f.txt")
        #expect(result["revision"] == nil)
        let lines = try #require(result["lines"] as? [[String: Any]])
        #expect(lines.map { $0["content"] as? String } == ["uno", "2"])
        #expect(lines[0]["oid"] as? String == BlameLine.uncommittedOID)
        #expect(lines[1]["oid"] as? String == repo.oids["second"])
        #expect(lines[1]["finalLine"] as? Int == 2)
    }

    @Test func revisionAndLinesNarrowTheBlame() throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }
        try repo.build([
            FixtureRepository.Commit("first", files: ["f.txt": "one\ntwo\nthree\n"]),
            FixtureRepository.Commit("second", files: ["f.txt": "one\n2\nthree\n"]),
        ])

        let result = try payload(try runArm(
            ["blame", "f.txt", "--revision", "HEAD~1", "--lines", "2,3"], in: repo.url.path))

        #expect(result["revision"] as? String == "HEAD~1")
        let lines = try #require(result["lines"] as? [[String: Any]])
        #expect(lines.map { $0["content"] as? String } == ["two", "three"])
        #expect(lines.allSatisfy { $0["oid"] as? String == repo.oids["first"] })
    }

    @Test func aMissingFileIsExitSix() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let reply = try runArm(["blame", "never.txt"], in: repo.url.path)
        #expect(reply.exitCode == .repositoryError)
        #expect(try errorCode(reply) == "repository_error")
    }

    @Test func aRangePastTheEndIsExitSix() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        #expect(try runArm(["blame", "a.txt", "--lines", "5,9"], in: repo.url.path).exitCode == .repositoryError)
    }
}
