// SequencerSnapshotTests.swift — capture/restore an interrupted rebase (#0174)

import Foundation
import Testing
@testable import YardGit

struct SequencerSnapshotTests {

    private let git = GitProcess()

    /// Drives a real rebase to a conflict stop. Returns the repository with a
    /// rebase genuinely in progress.
    private func repositoryStoppedMidRebase(diff3: Bool = false) throws -> FixtureRepository {
        let repo = try FixtureRepository.linear()
        if diff3 {
            // AUTO_MERGE only exists under diff3/zdiff3 — a default-configured
            // fixture never produces one.
            try git.run(["config", "merge.conflictStyle", "diff3"],
                        workingDirectory: repo.url.path)
        }
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

    /// **Given 3 made executable.** Refs alone do not make a rebase resumable:
    /// the assertion is that `git rebase --continue` actually completes, not
    /// merely that some files came back.
    @Test func restoringTheSequencerMakesTheRebaseResumable() throws {
        let repo = try repositoryStoppedMidRebase()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let snapshot = try #require(try SequencerSnapshot.capture(in: context))
        #expect(snapshot.layout == .rebaseMerge)

        // Wreck it, and prove the wreck took effect: with the directory gone
        // there is no rebase to continue.
        let directory = try context.path(for: snapshot.layout.rawValue)
        try FileManager.default.removeItem(atPath: directory)
        #expect(!FileManager.default.fileExists(atPath: directory),
                "the wreck must take effect")
        let interrupted = try? git.run(["rebase", "--continue"],
                                       workingDirectory: repo.url.path,
                                       extraEnvironment: ["GIT_EDITOR": "true"])
        #expect(interrupted?.exitCode != 0, "a removed sequencer cannot continue")

        try snapshot.restore(in: context)
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

    /// Several sequencer files are ZERO BYTES and their existence IS the
    /// state. A capture that skips them changes the rebase's behaviour without
    /// changing any content.
    @Test func zeroByteFlagFilesSurviveTheRoundTrip() throws {
        let repo = try repositoryStoppedMidRebase()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let directory = try context.path(for: "rebase-merge")

        let empties = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { name in
                let attrs = try? FileManager.default.attributesOfItem(
                    atPath: directory + "/" + name)
                return (attrs?[.size] as? NSNumber)?.intValue == 0
            }
        #expect(!empties.isEmpty, "the fixture must contain zero-byte flag files")

        let snapshot = try #require(try SequencerSnapshot.capture(in: context))
        try FileManager.default.removeItem(atPath: directory)
        try snapshot.restore(in: context)

        let after = try FileManager.default.contentsOfDirectory(atPath: directory)
        for name in empties {
            #expect(after.contains(name), "zero-byte \(name) must survive the round trip")
        }
    }

    @Test func captureReturnsNilWhenNoRebaseIsInProgress() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        #expect(try SequencerSnapshot.capture(in: context) == nil)
    }

    /// `AUTO_MERGE` sits OUTSIDE the sequencer directory and points at a tree
    /// reachable from no ref. Capture still records it — it is real,
    /// cheap-to-record state — but nothing downstream needs it to stay
    /// reachable (#0201).
    @Test func autoMergeIsCapturedWhenPresent() throws {
        let repo = try repositoryStoppedMidRebase()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let autoMergePath = try context.path(for: "AUTO_MERGE")

        let snapshot = try #require(try SequencerSnapshot.capture(in: context))
        if FileManager.default.fileExists(atPath: autoMergePath) {
            let oid = try #require(snapshot.autoMerge)
            #expect(try git.run(["cat-file", "-t", oid],
                                workingDirectory: repo.url.path).text
                .trimmingCharacters(in: .whitespacesAndNewlines) == "tree")
        } else {
            #expect(snapshot.autoMerge == nil)
        }
    }

    /// Pins the measurement behind #0201: a real conflicted rebase under
    /// `merge.conflictStyle=diff3` resumes with `git rebase --continue` even
    /// after `AUTO_MERGE` is deleted outright, so nothing needs to keep its
    /// tree reachable. The config is set explicitly on the fixture — a
    /// default-configured repository never produces an `AUTO_MERGE` at all,
    /// which is why the gap stayed invisible.
    @Test func rebaseContinuesAfterAutoMergeIsDeleted() throws {
        let repo = try repositoryStoppedMidRebase(diff3: true)
        defer { repo.destroy() }

        // Assert AUTO_MERGE exists BEFORE deleting it, so this test cannot
        // pass vacuously against a fixture that never produced one.
        let before = try git.run(["rev-parse", "--verify", "AUTO_MERGE"],
                                 workingDirectory: repo.url.path)
        let oid = before.text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!oid.isEmpty, "the fixture must produce AUTO_MERGE under diff3")

        try git.run(["update-ref", "-d", "AUTO_MERGE"], workingDirectory: repo.url.path)
        #expect(throws: (any Error).self) {
            try git.run(["rev-parse", "--verify", "AUTO_MERGE"],
                        workingDirectory: repo.url.path)
        }

        try repo.writeUntracked(["shared.txt": "resolved\n"])
        try git.run(["add", "shared.txt"], workingDirectory: repo.url.path)
        let resumed = try git.run(["rebase", "--continue"],
                                  workingDirectory: repo.url.path,
                                  extraEnvironment: ["GIT_EDITOR": "true"])
        #expect(resumed.exitCode == 0)
    }
}
