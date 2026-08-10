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

    /// The sequencer case from this issue's criteria is NOT yet round-trippable:
    /// #0174 built `SequencerSnapshot`, and nothing wires it into checkpoint.
    /// Asserted rather than omitted, so the gap is visible in the suite instead
    /// of living only in an issue nobody reads.
    @Test func midRebaseSequencerIsHonestlyReportedAsNotCaptured() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let ctx = try WorktreeContext.resolve(path: repo.url.path)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        let report = try JournalRestore.restore(entry.id, in: ctx)
        #expect(report.notRestored.map(\.piece) == [.sequencer])
        #expect(try #require(report.notRestored.first).reason == .notCaptured)
    }
}
