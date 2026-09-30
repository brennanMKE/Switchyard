// UndoCommandTests.swift — the `undo` and `redo` arms (guide §11 decision 37)

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

@Suite("undo/redo engine arms")
struct UndoCommandTests {

    @Test func undoMalformedArgumentsAreUsageFailuresBeforeAnyRepositoryAccess() throws {
        let empty = try nonRepositoryDirectory()
        defer { try? FileManager.default.removeItem(atPath: empty) }
        for command in ["undo", "redo"] {
            for tail in [["--steps"], ["--steps", "0"], ["--steps", "-1"], ["--steps", "+2"],
                         ["--steps", "two"], ["3"], ["--steps", "1", "--steps", "1"], ["--all"]] {
                let reply = try runArm([command] + tail, in: empty)
                #expect(reply.exitCode == .usage, "\(command) \(tail): \(reply.stdout)")
            }
        }
    }

    /// stage then commit, then undo twice: HEAD and the index are back, and
    /// each step names the operation it undid; redo brings the commit back.
    @Test func undoWalksBackAndRedoWalksForward() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let head = try repo.revParse("HEAD")
        try write("d\n", to: "d.txt", in: repo)
        _ = try runArm(["stage", "d.txt"], in: repo.url.path)
        _ = try runArm(["commit", "--message", "d"], in: repo.url.path)
        let committed = try repo.revParse("HEAD")

        let undo = try runArm(["undo", "--steps", "2"], in: repo.url.path)

        #expect(undo.exitCode == .success)
        let steps = try #require(try payload(undo)["steps"] as? [[String: Any]])
        #expect(steps.map { $0["operation"] as? String } == ["commit", "stage"])
        #expect(steps.allSatisfy { ($0["restored"] as? [String])?.contains("head") == true })
        #expect(try repo.revParse("HEAD") == head)
        #expect(try git(["status", "--porcelain"], in: repo.url.path) == "?? d.txt")

        let redo = try runArm(["redo", "--steps", "2"], in: repo.url.path)
        #expect(redo.exitCode == .success)
        let redone = try #require(try payload(redo)["steps"] as? [[String: Any]])
        #expect(redone.count == 2)
        #expect(redone.allSatisfy { $0["operation"] == nil })
        #expect(try repo.revParse("HEAD") == committed)
    }

    @Test func undoBringsBackADiscardedFile() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("precious\n", to: "a.txt", in: repo)
        _ = try runArm(["discard", "a.txt"], in: repo.url.path)

        let reply = try runArm(["undo"], in: repo.url.path)

        #expect(reply.exitCode == .success)
        let a = try String(contentsOf: repo.url.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(a == "precious\n")
    }

    /// More steps than remain is refused whole: nothing moves.
    @Test func tooManyStepsIsExitSixAndChangesNothing() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("d\n", to: "d.txt", in: repo)
        _ = try runArm(["stage", "d.txt"], in: repo.url.path)
        let before = try journalCount(in: repo.url.path)

        let reply = try runArm(["undo", "--steps", "5"], in: repo.url.path)

        #expect(reply.exitCode == .repositoryError)
        #expect(try git(["status", "--porcelain"], in: repo.url.path) == "A  d.txt")
        #expect(try journalCount(in: repo.url.path) == before)
    }

    @Test func redoWithNothingUndoneIsExitSix() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        #expect(try runArm(["redo"], in: repo.url.path).exitCode == .repositoryError)
    }

    /// The traversal entry records the invoking command line.
    @Test func theTraversalEntryRecordsTheCommandLine() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("d\n", to: "d.txt", in: repo)
        _ = try runArm(["stage", "d.txt"], in: repo.url.path)
        _ = try runArm(["undo"], in: repo.url.path)

        let context = try WorktreeContext.resolve(path: repo.url.path)
        let commands = try JournalList.list(in: context).items.compactMap { $0.metadata?.command }
        #expect(commands.contains("\(ServiceNames.cliName) undo"))
    }

    /// Undo refuses to cross the push the CLI just made (decision 32).
    @Test func undoAfterAPushIsRefused() throws {
        let repo = try FixtureRepository.linear()
        let bare = try repo.addUpstream()
        defer { repo.destroy(); try? FileManager.default.removeItem(at: bare) }
        try write("d\n", to: "d.txt", in: repo)
        _ = try runArm(["stage", "d.txt"], in: repo.url.path)
        _ = try runArm(["commit", "--message", "d"], in: repo.url.path)
        #expect(try runArm(["push"], in: repo.url.path).exitCode == .success)

        let reply = try runArm(["undo"], in: repo.url.path)
        #expect(reply.exitCode == .repositoryError)
        #expect(try git(["rev-parse", "origin/main"], in: repo.url.path) == (try repo.revParse("HEAD")))
    }
}
