// FullCaptureUndoTests.swift — the round trip M2's criterion names (#0171)

import Foundation
import Testing
@testable import YardGit

struct FullCaptureUndoTests {

    private let git = GitProcess()

    /// **M2's exit criterion, made literal for the hardest case.**
    ///
    /// *"Undo round-trips every mutating command, including with an unmerged
    /// index."* An unmerged index is the case that forced every design choice
    /// underneath this: `write-tree` refuses it (#0151), `git stash create`
    /// cannot capture it (#0152), and `add -u` against the real index would
    /// silently resolve it.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aConflictedIndexAndDirtyWorktreeRoundTrip(
        format: FixtureRepository.RefFormat
    ) throws {
        let repo = try FixtureRepository.conflicted(refFormat: format)
        defer { repo.destroy() }
        let ctx = try WorktreeContext.resolve(path: repo.url.path)

        // The fixture must genuinely be unmerged, or this proves nothing.
        let before = try git.run(["ls-files", "-u"], workingDirectory: repo.url.path).text
        #expect(!before.isEmpty, "the fixture must have an unmerged index")
        try repo.writeUntracked(["scratch.txt": "untracked before\n"])

        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        let metadata = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: entry.id, in: ctx))
        // The conflicted index must have taken the RAW path.
        #expect(metadata.captured.index == .raw)
        #expect(metadata.captured.worktree == .stash)

        // Wreck all three: the index, the tracked worktree, and the untracked
        // file — and prove each wreck took effect.
        try git.run(["read-tree", "--empty"], workingDirectory: repo.url.path)
        try repo.writeUntracked(["f.txt": "clobbered\n"])
        try FileManager.default.removeItem(
            at: repo.url.appendingPathComponent("scratch.txt"))
        #expect(try git.run(["ls-files", "-u"], workingDirectory: repo.url.path).text.isEmpty,
                "the index wreck must take effect")
        #expect(!FileManager.default.fileExists(
            atPath: repo.url.appendingPathComponent("scratch.txt").path))

        let report = try JournalRestore.restore(entry.id, in: ctx)

        #expect(report.restored.contains(.index))
        #expect(report.restored.contains(.worktree))
        #expect(report.notRestored.map(\.piece) == [.sequencer])

        // The unmerged index is back, stage for stage.
        #expect(try git.run(["ls-files", "-u"], workingDirectory: repo.url.path).text == before)
        // The tracked file and the untracked file are both back.
        #expect(try String(contentsOf: repo.url.appendingPathComponent("f.txt"),
                           encoding: .utf8) != "clobbered\n")
        #expect(FileManager.default.fileExists(
            atPath: repo.url.appendingPathComponent("scratch.txt").path),
                "untracked files must come back")
    }

    /// The worktree snapshot's commit is reachable from no ref, so the anchor
    /// must carry it as a parent — otherwise ordinary maintenance reclaims it
    /// and the entry restores to a missing object.
    @Test func theWorktreeCommitIsKeptAliveByTheAnchor() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let ctx = try WorktreeContext.resolve(path: repo.url.path)
        try repo.writeUntracked(["dirty.txt": "content\n"])

        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        // Locate the commit INDEPENDENTLY of the keep-alive wiring. Reading it
        // back through `worktreeCommit(of:)` would ask the thing under test
        // where to look: with the parent missing, that helper returns a ref tip
        // instead, which is reachable, and the assertion passes for free —
        // measured, by mutating the append away and watching nothing fail.
        // #0187 pinned capture determinism, so re-capturing the same state
        // yields the same oid.
        let recaptured = try #require(try WorktreeSnapshot.capture(in: ctx, git: git))
        let worktreeCommit = recaptured.commit

        let parents = try git.run(["rev-list", "--parents", "-n", "1", entry.commit],
                                  workingDirectory: repo.url.path).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map(String.init)
        #expect(parents.contains(worktreeCommit),
                "the anchor must carry the worktree commit as a parent")

        // Reachability, asserted directly — switchyard never runs `git gc`.
        let unreachable = try git.run(["fsck", "--unreachable", "--no-progress"],
                                      workingDirectory: repo.url.path).text
        #expect(!unreachable.contains(worktreeCommit),
                "the worktree commit must be reachable through the anchor")
    }

    /// A commit reachable from nothing, distinguishable by its message —
    /// stands in for a real worktree snapshot or a further keep-alive tip
    /// without needing a real capture.
    private func syntheticCommit(marker: String, in repo: FixtureRepository) throws -> String {
        let tree = try #require(try git.run(
            ["write-tree"], workingDirectory: repo.url.path).lines.first)
        return try #require(try git.run(
            ["commit-tree", tree, "-m", "synthetic \(marker)"],
            workingDirectory: repo.url.path,
            extraEnvironment: ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@invalid",
                               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@invalid"])
            .lines.first)
    }

    /// #0202 regression, built directly against `JournalAnchor.write` rather
    /// than by editing `JournalCheckpoint.writeEntry`: the worktree commit
    /// sits in `keepAlive` at index 0, with a second keep-alive oid appended
    /// after it — the exact #0188-shaped ordering (append one more keep-alive
    /// commit past the worktree commit) that the old `parents.last` read
    /// would have missed. `worktreeCommit(of:)` must still find it, because
    /// it now reads the commit's own tree entry rather than the tail of this
    /// list.
    @Test func worktreeCommitIsFoundEvenWhenNotTheLastKeepAliveParent() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let ctx = try WorktreeContext.resolve(path: repo.url.path)

        let worktreeVictim = try syntheticCommit(marker: "worktree", in: repo)
        let trailingVictim = try syntheticCommit(marker: "trailing-keep-alive", in: repo)
        #expect(worktreeVictim != trailingVictim,
                "the two synthetic commits must be distinguishable")

        let id = try #require(JournalEntryID("010000000000000000000000" + "02"))
        let metadata = JournalEntryMetadata(
            id: id, operation: "checkpoint", timestamp: Date(timeIntervalSince1970: 0),
            worktree: .init(name: nil, path: repo.url.path),
            captured: .refsOnly)
        let entry = try JournalAnchor.write(
            JournalAnchor.Contents(
                metadataJSON: try metadata.serialized(),
                worktreeCommit: worktreeVictim,
                keepAlive: [worktreeVictim, trailingVictim]),
            id: id, in: ctx)

        let found = try JournalRestore.worktreeCommit(of: entry, at: repo.url.path, git: git)
        #expect(found == worktreeVictim,
                "worktreeCommit(of:) must resolve the commit named in its own tree entry, not \(trailingVictim)")
    }
}
