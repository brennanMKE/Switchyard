// DiscardCommandTests.swift — the `discard` arm (guide §11 decision 37)

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

@Suite("discard engine arm")
struct DiscardCommandTests {

    @Test func discardMalformedArgumentsAreUsageFailuresBeforeAnyRepositoryAccess() throws {
        let empty = try nonRepositoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: empty) }
        for tail in [[], ["--yes"], ["a.txt", "--hunk", "h"], ["--hunk"]] {
            let reply = try runArm(["discard"] + tail, in: empty)
            #expect(reply.exitCode == .usage, "discard \(tail): \(reply.stdout)")
        }
    }

    /// Tracked goes back to its index version (keeping what is staged),
    /// untracked is deleted, and it is one journal entry.
    @Test func discardsTrackedAndUntrackedPathsKeepingStagedChanges() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("a staged\n", to: "a.txt", in: repo)
        try git(["add", "a.txt"], in: repo.url.path)
        try write("a staged then edited\n", to: "a.txt", in: repo)
        try write("scratch\n", to: "junk.txt", in: repo)
        let before = try journalCount(in: repo.url.path)

        let reply = try runArm(["discard", "a.txt", "junk.txt"], in: repo.url.path)

        #expect(reply.exitCode == .success)
        #expect(try payload(reply)["paths"] as? [String] == ["a.txt", "junk.txt"])
        let a = try String(contentsOf: repo.url.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(a == "a staged\n")
        #expect(!FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("junk.txt").path))
        #expect(try journalCount(in: repo.url.path) == before + 1)
    }

    @Test func discardsAHunkById() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("a\nmore\n", to: "a.txt", in: repo)
        let id = try #require(try listHunks(at: repo.url.path, area: .unstaged).first?.hunks.first?.id)

        let reply = try runArm(["discard", "--hunk", id], in: repo.url.path)

        #expect(reply.exitCode == .success)
        #expect(try payload(reply)["hunks"] as? [String] == [id])
        #expect(try git(["status", "--porcelain"], in: repo.url.path) == "")
    }

    @Test func aPathWithNoUnstagedChangeIsExitSixWithNoEntry() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let before = try journalCount(in: repo.url.path)
        let reply = try runArm(["discard", "a.txt"], in: repo.url.path)
        #expect(reply.exitCode == .repositoryError)
        #expect(try journalCount(in: repo.url.path) == before)
    }
}
