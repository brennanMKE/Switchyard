// StashCommandTests.swift — the `stash` arm (guide §11 decisions 36, 37)

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

@Suite("stash engine arm")
struct StashCommandTests {

    @Test func stashMalformedArgumentsAreUsageFailuresBeforeAnyRepositoryAccess() throws {
        let empty = try nonRepositoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: empty) }
        let cases: [[String]] = [
            ["stash"],                                      // no subcommand: never git's implicit push
            ["stash", "save"],                              // unknown subcommand
            ["stash", "list", "extra"],                     // list takes nothing
            ["stash", "push", "--message"],                 // value missing
            ["stash", "push", "--message", "a", "--message", "b"],
            ["stash", "push", "--include-untracked", "--include-untracked"],
            ["stash", "push", "--index"],                   // apply's flag
            ["stash", "apply"],                             // no <stash>
            ["stash", "apply", "0", "1"],                   // two <stash>
            ["stash", "pop", "0", "--include-untracked"],   // push's flag
            ["stash", "drop", "0", "--index"],               // drop takes no flags
        ]
        for argv in cases {
            let reply = try runArm(argv, in: empty)
            #expect(reply.exitCode == .usage, "\(argv): \(reply.stdout)")
        }
    }

    @Test func listIsEmptyWithNoStashes() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let result = try payload(try runArm(["stash", "list"], in: repo.url.path))
        #expect((result["stashes"] as? [Any])?.isEmpty == true)
    }

    @Test func pushReportsTheNewStashAndListShowsIt() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("a changed\n", to: "a.txt", in: repo)
        try write("u\n", to: "u.txt", in: repo)

        let pushed = try payload(try runArm(
            ["stash", "push", "--message", "wip", "--include-untracked"], in: repo.url.path))

        #expect(pushed["name"] as? String == "stash@{0}")
        #expect(pushed["includesUntracked"] as? Bool == true)
        #expect(pushed["message"] as? String == "On main: wip")
        #expect(pushed["oid"] as? String == (try repo.revParse("refs/stash")))
        #expect(try git(["status", "--porcelain"], in: repo.url.path) == "")

        let listed = try #require(try payload(try runArm(["stash", "list"], in: repo.url.path))["stashes"] as? [[String: Any]])
        #expect(listed.count == 1)
        #expect(listed.first?["oid"] as? String == pushed["oid"] as? String)
    }

    /// Without --include-untracked only tracked changes go, git's default.
    @Test func pushLeavesUntrackedFilesByDefault() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("a changed\n", to: "a.txt", in: repo)
        try write("u\n", to: "u.txt", in: repo)
        let pushed = try payload(try runArm(["stash", "push"], in: repo.url.path))
        #expect(pushed["includesUntracked"] as? Bool == false)
        #expect(try git(["status", "--porcelain"], in: repo.url.path) == "?? u.txt")
    }

    @Test func nothingToStashIsExitSix() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        #expect(try runArm(["stash", "push"], in: repo.url.path).exitCode == .repositoryError)
    }

    /// `stash@{n}`, `n` and the oid all name the same stash.
    @Test func resolveStashAcceptsTheThreeForms() throws {
        let items = [
            Stash.Item(index: 0, oid: "aaa", baseOID: "b", includesUntracked: false, date: 0, message: "x"),
            Stash.Item(index: 1, oid: "ccc", baseOID: "b", includesUntracked: false, date: 0, message: "y"),
        ]
        #expect(try resolveStash("stash@{1}", in: items) == "ccc")
        #expect(try resolveStash("1", in: items) == "ccc")
        #expect(try resolveStash("aaa", in: items) == "aaa")
        #expect(throws: Stash.Refusal.self) { try resolveStash("2", in: items) }
        #expect(throws: Stash.Refusal.self) { try resolveStash("+1", in: items) }
        #expect(throws: Stash.Refusal.self) { try resolveStash("ddd", in: items) }
    }

    @Test func popAppliesAndDropsTheStash() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("a changed\n", to: "a.txt", in: repo)
        _ = try runArm(["stash", "push"], in: repo.url.path)
        let oid = try repo.revParse("refs/stash")

        let reply = try runArm(["stash", "pop", "stash@{0}"], in: repo.url.path)

        #expect(reply.exitCode == .success)
        let result = try payload(reply)
        #expect(result["oid"] as? String == oid)
        #expect(result["outcome"] as? String == "applied")
        #expect(result["conflictedPaths"] == nil)
        #expect(try git(["status", "--porcelain"], in: repo.url.path) == " M a.txt")
        #expect(try git(["stash", "list"], in: repo.url.path) == "")
    }

    @Test func applyWithIndexRestoresStagedChangesAndKeepsTheStash() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("a staged\n", to: "a.txt", in: repo)
        try git(["add", "a.txt"], in: repo.url.path)
        _ = try runArm(["stash", "push"], in: repo.url.path)

        let reply = try runArm(["stash", "apply", "0", "--index"], in: repo.url.path)

        #expect(reply.exitCode == .success)
        #expect(try git(["status", "--porcelain"], in: repo.url.path) == "M  a.txt")
        #expect(try git(["stash", "list", "--format=%H"], in: repo.url.path).count == 40)
    }

    /// A conflicting apply is an outcome: ok:true at exit 8, stash kept.
    @Test func aConflictingPopIsExitEightWithTheStashKept() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("stashed\n", to: "a.txt", in: repo)
        _ = try runArm(["stash", "push"], in: repo.url.path)
        try write("committed\n", to: "a.txt", in: repo)
        try git(["commit", "-q", "-am", "diverge"], in: repo.url.path)

        let reply = try runArm(["stash", "pop", "0"], in: repo.url.path)

        #expect(reply.exitCode == .blockedOnConflicts)
        let result = try payload(reply)
        #expect(result["outcome"] as? String == "conflicted")
        #expect(result["conflictedPaths"] as? [String] == ["a.txt"])
        #expect(try git(["stash", "list", "--format=%H"], in: repo.url.path).count == 40)
    }

    @Test func dropRemovesTheNamedStashOnly() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("one\n", to: "a.txt", in: repo)
        _ = try runArm(["stash", "push"], in: repo.url.path)
        let older = try repo.revParse("refs/stash")
        try write("two\n", to: "a.txt", in: repo)
        _ = try runArm(["stash", "push"], in: repo.url.path)
        let newer = try repo.revParse("refs/stash")
        let before = try journalCount(in: repo.url.path)

        let reply = try runArm(["stash", "drop", older], in: repo.url.path)

        #expect(reply.exitCode == .success)
        #expect(try payload(reply)["dropped"] as? String == older)
        #expect(try git(["stash", "list", "--format=%H"], in: repo.url.path) == newer)
        #expect(try journalCount(in: repo.url.path) == before + 1)
    }

    @Test func aStashTheListDoesNotHoldIsExitSix() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        #expect(try runArm(["stash", "drop", "0"], in: repo.url.path).exitCode == .repositoryError)
    }
}
