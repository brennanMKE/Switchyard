// UndoRoundTripSuiteTests.swift — the undo round-trip suite (#0035)
//
// M2's exit criterion: "undo round-trips every mutating command, including
// with an unmerged index." Each case wrecks a distinct kind of state, restores,
// and compares. Every case proves its own wreck took effect first — a
// round-trip test whose wreck was a no-op passes without restoring anything.

import Foundation
import Testing
@testable import YardGit

struct UndoRoundTripSuiteTests {

    private let git = GitProcess()

    /// Everything a round trip must preserve, read back from the repository.
    private struct State: Equatable {
        var refs: RefSnapshot
        var stages: String        // `ls-files -s`: paths, modes, and conflict stages
        var tracked: [String: String]
        var untracked: [String]
    }

    private func read(_ repo: FixtureRepository, _ ctx: WorktreeContext) throws -> State {
        let stages = try git.run(["ls-files", "-s"], workingDirectory: repo.url.path).text
        let names = try git.run(["ls-files"], workingDirectory: repo.url.path).lines
            .filter { !$0.isEmpty }
        var tracked: [String: String] = [:]
        for name in names {
            let url = repo.url.appendingPathComponent(name)
            tracked[name] = (try? String(contentsOf: url, encoding: .utf8)) ?? "<absent>"
        }
        let untracked = try git.run(["ls-files", "--others", "--exclude-standard"],
                                    workingDirectory: repo.url.path).lines
            .filter { !$0.isEmpty }.sorted()
        return State(refs: try RefSnapshot.capture(in: ctx), stages: stages,
                     tracked: tracked, untracked: untracked)
    }

    /// Checkpoint, wreck, restore, compare. `wreck` must actually change
    /// something — asserted, not assumed.
    private func roundTrip(
        _ repo: FixtureRepository,
        wreck: (FixtureRepository, WorktreeContext) throws -> Void
    ) throws {
        let ctx = try WorktreeContext.resolve(path: repo.url.path)
        let before = try read(repo, ctx)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        try wreck(repo, ctx)
        let wrecked = try read(repo, ctx)
        #expect(wrecked != before, "the wreck must change something, or this proves nothing")

        let report = try JournalRestore.restore(entry.id, in: ctx)
        #expect(report.restored.contains(.refs))

        let after = try read(repo, ctx)
        #expect(after.stages == before.stages, "index stages must round-trip")
        #expect(after.tracked == before.tracked, "tracked file contents must round-trip")
        #expect(after.untracked == before.untracked, "untracked files must round-trip")
        #expect(after.refs == before.refs, "refs must round-trip")
    }

    // MARK: - The cases

    /// The case M2's criterion names explicitly, and the one every design
    /// choice underneath was forced by.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func unmergedIndexRoundTrips(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.conflicted(refFormat: format)
        defer { repo.destroy() }
        #expect(!(try git.run(["ls-files", "-u"], workingDirectory: repo.url.path).text.isEmpty),
                "the fixture must be unmerged")
        try roundTrip(repo) { repo, _ in
            try self.git.run(["read-tree", "--empty"], workingDirectory: repo.url.path)
            try repo.writeUntracked(["f.txt": "clobbered\n"])
        }
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func detachedHeadRoundTrips(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        try repo.checkoutDetached(try #require(repo.oids["b"]))
        try roundTrip(repo) { repo, _ in
            try self.git.run(["checkout", "-q", "main"], workingDirectory: repo.url.path)
        }
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func untrackedFilesRoundTrip(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        try repo.writeUntracked(["notes.txt": "keep me\n", "scratch.log": "and me\n"])
        try roundTrip(repo) { repo, _ in
            try FileManager.default.removeItem(
                at: repo.url.appendingPathComponent("notes.txt"))
            try FileManager.default.removeItem(
                at: repo.url.appendingPathComponent("scratch.log"))
        }
    }

    /// Staged and unstaged changes to the same file — the mix that a
    /// tree-only capture silently flattens.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func stagedAndUnstagedMixRoundTrips(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        try repo.writeUntracked(["mix.txt": "staged\n"])
        try git.run(["add", "mix.txt"], workingDirectory: repo.url.path)
        try repo.writeUntracked(["mix.txt": "staged then modified\n"])

        try roundTrip(repo) { repo, _ in
            try self.git.run(["reset", "-q"], workingDirectory: repo.url.path)
            try repo.writeUntracked(["mix.txt": "clobbered\n"])
        }
    }

    /// Drives a real rebase to a conflict stop. Returns the repository with a
    /// rebase genuinely in progress. Copied from #0174's
    /// `SequencerSnapshotTests.swift:13-38`.
    private func repositoryStoppedMidRebase() throws -> FixtureRepository {
        let repo = try FixtureRepository.linear()
        // `linear` builds a, b, c each touching a DIFFERENT file, so a naive
        // fork conflicts with nothing and the rebase completes cleanly. Both
        // sides must edit the same path after the fork point.
        try repo.writeUntracked(["shared.txt": "base\n"])
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-q", "-m", "shared base"],
                    workingDirectory: repo.url.path)
        let fork = try repo.revParse("HEAD")

        try repo.writeUntracked(["shared.txt": "mainline\n"])
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-q", "-m", "mainline change"],
                    workingDirectory: repo.url.path)

        try git.run(["checkout", "-q", "-b", "side", fork],
                    workingDirectory: repo.url.path)
        try repo.writeUntracked(["shared.txt": "sidechange\n"])
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-q", "-m", "side change"],
                    workingDirectory: repo.url.path)

        // Expected to fail with the conflict — that is the point.
        _ = try? git.run(["rebase", "main"], workingDirectory: repo.url.path)
        return repo
    }

    /// The real round trip #0188 wires up: stop mid-rebase, checkpoint, wreck
    /// the sequencer directory, prove the wreck took effect, restore, resolve
    /// the conflict, and assert `git rebase --continue` exits 0.
    @Test func midRebaseSequencerRoundTripsThroughCheckpointAndRestore() throws {
        let repo = try repositoryStoppedMidRebase()
        defer { repo.destroy() }
        let ctx = try WorktreeContext.resolve(path: repo.url.path)

        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        let metadata = try JournalEntryMetadata(
            serialized: JournalAnchor.metadata(for: entry.id, in: ctx))
        #expect(metadata.captured.sequencer == .merge)

        let directory = try ctx.path(for: "rebase-merge")
        try FileManager.default.removeItem(atPath: directory)
        #expect(!FileManager.default.fileExists(atPath: directory),
                "the wreck must take effect")
        let interrupted = try? git.run(["rebase", "--continue"],
                                       workingDirectory: repo.url.path,
                                       extraEnvironment: ["GIT_EDITOR": "true"])
        #expect(interrupted?.exitCode != 0, "a removed sequencer cannot continue")

        _ = try JournalRestore.restore(entry.id, in: ctx)

        try repo.writeUntracked(["shared.txt": "resolved\n"])
        try git.run(["add", "shared.txt"], workingDirectory: repo.url.path)
        let resumed = try git.run(["rebase", "--continue"],
                                  workingDirectory: repo.url.path,
                                  extraEnvironment: ["GIT_EDITOR": "true"])
        #expect(resumed.exitCode == 0)
        #expect(try git.run(["status", "--porcelain=v2", "--branch"],
                            workingDirectory: repo.url.path)
            .text.contains("branch.head side"))
    }

    /// The honesty half: a round trip can pass while the report still lies
    /// about the sequencer being unrestored, so this asserts the report
    /// separately from the round trip itself.
    @Test func midRebaseCheckpointReportsTheSequencerAsRestored() throws {
        let repo = try repositoryStoppedMidRebase()
        defer { repo.destroy() }
        let ctx = try WorktreeContext.resolve(path: repo.url.path)

        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        let directory = try ctx.path(for: "rebase-merge")
        try FileManager.default.removeItem(atPath: directory)

        let report = try JournalRestore.restore(entry.id, in: ctx)
        #expect(!report.notRestored.map(\.piece).contains(.sequencer))
    }
}
