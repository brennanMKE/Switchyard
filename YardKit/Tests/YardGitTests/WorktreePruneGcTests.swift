// WorktreePruneGcTests.swift

import Foundation
import Testing
@testable import YardGit

struct WorktreePruneGcTests {

    private let git = GitProcess()

    /// Returns the real base temp directory on macOS (resolves `/private/var`
    /// → `/var` via `NSTemporaryDirectory()`). Use for path normalization.
    private func tempBase() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path + "/"
    }

    /// Normalizes a path so `/private/var/...` and `/var/...` compare equal.
    private func normalize(_ path: String) -> String {
        // Strip the "/private" prefix if present, to align with canonical base.
        guard path.hasPrefix("/private/var/") else { return path }
        let remainder = String(path.dropFirst(8)) // drop "/private"
        return remainder
    }

    // MARK: - Helpers

    /// Builds the four-worktree fixture that every prunable/abandoned-session
    /// test needs:

    /// | worktree       | lock reason                                  | directory state   |
    /// |----------------|----------------------------------------------|-------------------|
    /// | `agentpresent` | `switchyard-agent:session=live`              | present           |
    /// | `agentdeleted` | `switchyard-agent:session=gone`              | deleted           |
    /// | `userdeleted`  | `reviewing this branch later`                | deleted           |
    /// | `unlocked`     | (none)                                       | deleted           |

    private func buildFourWorktrees(repo: inout FixtureRepository) throws -> (
        agentpresentPath: URL,
        agentdeletedPath: URL,
        userdeletedPath: URL,
        unlockedPath: URL
    ) {
        let uuid = UUID().uuidString.prefix(8)

        let agentpresentPath = try repo.addWorktree(named: "agentpresent", branch: "agentpresent-\(uuid)")
        let agentdeletedPath = try repo.addWorktree(named: "agentdeleted", branch: "agentdeleted-\(uuid)")
        let userdeletedPath = try repo.addWorktree(named: "userdeleted", branch: "userdeleted-\(uuid)")
        let unlockedPath = try repo.addWorktree(named: "unlocked", branch: "unlocked-\(uuid)")

        // Lock three of them with different reasons.
        try repo.lockWorktree(agentpresentPath, reason: "switchyard-agent:session=live")
        try repo.lockWorktree(agentdeletedPath, reason: "switchyard-agent:session=gone")
        try repo.lockWorktree(userdeletedPath, reason: "reviewing this branch later")

        // Delete three of the four worktrees' directories.
        // `agentpresentPath` remains on disk (it must stay, so it is not abandoned).
        try FileManager.default.removeItem(at: agentdeletedPath)
        try FileManager.default.removeItem(at: userdeletedPath)
        // `unlocked` has no lock, so deleting its directory is what makes it prunable.
        try FileManager.default.removeItem(at: unlockedPath)

        return (agentpresentPath, agentdeletedPath, userdeletedPath, unlockedPath)
    }

    // MARK: - gc default: report-only, no prune

    @Test func gcDefaultDoesNotRunPrune() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        _ = try buildFourWorktrees(repo: &repo)

        let result = try WorktreePrune.gc(repositoryPath: repo.url.path)

        // The default gc must report the abandoned session and the prunable entries.
        try #require(!result.reports.isEmpty, "gc default must produce reports for the four-worktree fixture")
        #expect(result.reports.contains { $0.type == .abandonedSession }, "agent-deleted worktree must be reported as abandoned session")
        #expect(result.reports.contains { $0.type == .prunable }, "unlocked-deleted worktree must be reported as prunable")

        // The pruned array must be empty because prune was not called.
        #expect(result.pruned.isEmpty, "gc default must not invoke prune; pruned is []")
    }

    // MARK: - gc with prune flag

    @Test func gcWithPruneFlagCallsBothSteps() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let (agentpresentPath, _, _, unlockedPath) = try buildFourWorktrees(repo: &repo)

        let result = try WorktreePrune.gc(repositoryPath: repo.url.path, prune: true)

        // The reports should still contain the abandoned session and prunable entries.
        try #require(!result.reports.isEmpty, "gc with prune must produce reports")

        // After a real prune run (the only reaped entry is the unlocked prunable one),
        // a second worktree list call must show that the unlocked entry is gone.
        let entriesAfterPrune = try worktreeList(path: repo.url.path)
        // `!isEmpty` cannot fail -- the main worktree is always listed. Assert on
        // the specific entry this test is about.
        #expect(!entriesAfterPrune.contains { normalize($0.path ?? "") == normalize(unlockedPath.path) },
                "the reaped prunable worktree must be gone from the list")
        #expect(entriesAfterPrune.contains { normalize($0.path ?? "") == normalize(agentpresentPath.path) },
                "the locked, present worktree must survive a prune")
    }

    // MARK: - gc with mocked git reports empty when there is nothing to report

    @Test func gcWithCleanRepoReturnsEmptyReports() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let result = try WorktreePrune.gc(repositoryPath: repo.url.path)
        #expect(result.reports.isEmpty, "no worktrees beyond main should produce no reports")
        #expect(result.pruned.isEmpty, "default gc must not invoke prune")
    }

    // MARK: - gc prunes when flag is true (with one prunable worktree)

    @Test func gcPruneFlagActuallyRunsPruneAgainstRepository() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let (_, _, _, unlockedPath) = try buildFourWorktrees(repo: &repo)

        let result = try WorktreePrune.gc(repositoryPath: repo.url.path, prune: true)

        // At least one prunable entry must have been reported before we
        // verified that prune was called.
        try #require(!result.reports.isEmpty, "gc with prune should produce at least one report")
        let prunable = result.reports.filter { $0.type == .prunable }
        #expect(!prunable.isEmpty, "there must be prunable entries after deleting a worktree dir")

        // After the prune call, the only reaped entry is the unlocked-prunable one.
        let entriesAfter = try worktreeList(path: repo.url.path)
        #expect(!entriesAfter.contains { normalize($0.path ?? "") == normalize(unlockedPath.path) },
                "the reaped prunable worktree must be gone from the list")
    }

    // MARK: - gc does NOT prune on default call (report-only retention)

    @Test func gcDefaultDoesNotRunPruneLeavesEntryListed() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let (_, _, _, unlockedPath) = try buildFourWorktrees(repo: &repo)

        // First gc — report only, no prune.
        let first = try WorktreePrune.gc(repositoryPath: repo.url.path)

        // Assert we got reports for the prunable and abandoned entries.
        try #require(!first.reports.isEmpty, "gc with a four-worktree fixture must produce reports")
        let prunableFirst = first.reports.filter { $0.type == .prunable }
        #expect(!prunableFirst.isEmpty, "gc should report prunable entries without pruning")

        // Second list — the worktree must still be listed. If gc had
        // accidentally called prune, this second `worktreeList` would show it.
        let entries2 = try worktreeList(path: repo.url.path)
        // The point of a report-only gc: the prunable entry is STILL THERE.
        // `!isEmpty` would pass even if gc had reaped it, since the main
        // worktree is always listed.
        #expect(entries2.contains { normalize($0.path ?? "") == normalize(unlockedPath.path) },
                "a default gc must not reap the prunable worktree")
    }

    // MARK: - mutation 1 — .text instead of .standardError must kill the prune test

    @Test func mutation1_textInsteadOfStandardErrorKillsPruneOutput() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        _ = try buildFourWorktrees(repo: &repo)

        // Drive gc(prune:true); the pruned output must contain prune's stderr
        // lines. If we mistakenly read from Output.text instead, this array is
        // empty because git's "removing" diagnostics go to stderr.
        let result = try WorktreePrune.gc(repositoryPath: repo.url.path, prune: true)

        let reports = result.reports
        #expect(!reports.isEmpty, "a four-worktree fixture always produces reports regardless of mutation")

        // Strict check: this assertion specifically guards against mutation 1.
        let pruned = result.pruned
        #expect(!pruned.isEmpty, "mutation1: if runPrune reads Output.text instead of .standardError, this array is empty")
    }

    // MARK: - #0265 — GCResult.pruned's elements, not just its emptiness

    /// M1 milestone review, fourth pass, 2026-08-18: every prior assertion on
    /// `pruned` checked only emptiness, which two independent mutations of
    /// `WorktreePrune.runPrune` survive — dropping the trailing-empty-line
    /// trim (leaves a spurious `""` element) and blanking every line's
    /// content (keeps the array non-empty but content-free). This test
    /// asserts on the elements themselves: no element is the empty string,
    /// and some element names the reaped worktree. Either assertion alone
    /// lets one of the two mutations through.
    @Test func pruneElementsAreNonEmptyAndNameTheReapedWorktree() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let (_, _, _, unlockedPath) = try buildFourWorktrees(repo: &repo)

        let result = try WorktreePrune.gc(repositoryPath: repo.url.path, prune: true)
        let pruned = result.pruned

        try #require(!pruned.isEmpty, "a real prune of the unlocked-deleted worktree must produce output")

        // Mutation guard 1: dropping the trim at WorktreePrune.swift:157-159
        // (`return lines`) leaves a trailing "" element from splitting on
        // "\n" — git's stderr diagnostics are newline-terminated.
        #expect(!pruned.contains(""), "no element of pruned may be the empty string")

        // Mutation guard 2: erasing every line's content (`.map { _ in "" }`)
        // keeps the array's shape but destroys the content this test checks.
        let unlockedName = unlockedPath.lastPathComponent
        #expect(
            pruned.contains { $0.contains("Removing ") && $0.contains(unlockedName) },
            "pruned must contain git's verbatim \"Removing <worktree>: <reason>\" line naming the reaped worktree \(unlockedName)"
        )
    }

    // MARK: - mutation 2 — make --prune the default (always prune)

    @Test func mutation2_defaultPruneRemovesThePrunableEntry() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let (_, _, _, unlockedPath) = try buildFourWorktrees(repo: &repo)

        // With a default gc (prune should be false), the prunable entries must
        // still appear in a subsequent worktreeList call because prune is NOT run.

        let defaultResult = try WorktreePrune.gc(repositoryPath: repo.url.path)
        #expect(defaultResult.pruned.isEmpty, "gc default must not run prune")

        // The prunable entry (unlocked) should still be listed in porcelain
        // because we did not actually invoke git prune.
        let entriesAfterDefault = try worktreeList(path: repo.url.path)
        #expect(entriesAfterDefault.contains { $0.path != nil && normalize($0.path!) == normalize(unlockedPath.path) }, "default gc must leave prunable entry listed")
    }

    // MARK: - mutation 3 — ignore existence check (every locked -> abandoned)

    @Test func mutation3_ignoringExistenceMarksPresentLockedAsAbandoned() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let (agentpresentPath, agentdeletedPath, _, _) = try buildFourWorktrees(repo: &repo)

        // Exactly one abandoned session should be reported: the agent-deleted worktree.
        let reports = try WorktreePrune.gc(repositoryPath: repo.url.path).reports

        let abandoned = reports.filter { $0.type == .abandonedSession }
        #expect(abandoned.count == 1, "exactly one worktree should be abandoned — the agent-deleted entry")

        // The abandoned session must point at the agentdeleted path.
        let abandonedEntry = try #require(abandoned.first, "there must be exactly one abandoned session")
        #expect(normalize(abandonedEntry.path) == normalize(agentdeletedPath.path), "the abandoned entry must be the agent-deleted worktree")
        #expect(abandonedEntry.removable == false, "abandoned sessions are never removable")

        // The agent-present worktree (directory still exists) must NOT appear in reports.
        #expect(!reports.contains { normalize($0.path) == normalize(agentpresentPath.path) }, "agent-present worktree with present directory must not be in reports — this is mutation 3")
    }

    // MARK: - mutation 4 — drop the switchyard-agent prefix check

    @Test func mutation4_dropPrefixMakesUserLockedAbandoned() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let (_, agentdeletedPath, userdeletedPath, _) = try buildFourWorktrees(repo: &repo)

        let reports = try WorktreePrune.gc(repositoryPath: repo.url.path).reports

        // The three deleted worktrees should all be detected: one prunable, two abandoned sessions.
        let prunableReports = reports.filter { $0.type == .prunable }
        #expect(prunableReports.count >= 1, "at least one worktree must be prunable (the unlocked one)")

        // Exactly one abandoned entry: the agent-deleted worktree. The user-locked
        // worktree (reason unrelated to switchyard-agent) must not become abandoned.
        let abandoned = reports.filter { $0.type == .abandonedSession }
        #expect(abandoned.count == 1, "mutation4: exactly one abandoned session (agent-deleted) — the user-locked worktree has a non-agent reason so must NOT flip to abandoned")

        // The user-locked worktree must NOT be reported as abandoned — its reason
        // is unrelated to the agent prefix. If mutation 4 drops the prefix check,
        // this would flip to abandonedSession:
        #expect(!reports.contains { normalize($0.path) == normalize(userdeletedPath.path) && $0.type == .abandonedSession }, "mutation4: user-locked worktree must not be reported as abandoned")

        // The abandoned session that survives should point at the agentdeleted worktree.
        let abandonedEntry = try #require(abandoned.first, "the abandoned entry must exist")
        #expect(normalize(abandonedEntry.path) == normalize(agentdeletedPath.path), "the abandoned entry must be the agent-deleted worktree")
        #expect(abandonedEntry.lockReason != nil, "abandoned session must have a recorded lock reason")
        #expect(abandonedEntry.removable == false, "abandoned sessions are never removable")
    }

    // MARK: - gc wiring: prune flag controls second element of the tuple

    @Test func gcWiringRespectsThePruneFlag() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        _ = try buildFourWorktrees(repo: &repo)

        // Default (no prune flag) — the second element of the tuple is [].
        let defaultResult = try WorktreePrune.gc(repositoryPath: repo.url.path)
        #expect(defaultResult.pruned.isEmpty, "gc default must not run prune; the pruned array is []")

        // Explicitly `prune: true` — a prune must actually run.
        let prunedResult = try WorktreePrune.gc(repositoryPath: repo.url.path, prune: true)
        #expect(!prunedResult.pruned.isEmpty, "gc with prune flag must invoke prune; pruned is non-empty")
    }

    // MARK: - Report description formatting

    @Test func reportDescriptionFormatsPrunableEntries() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let (presentPath, deletedPath, _, unlockedPath) = try buildFourWorktrees(repo: &repo)

        let reports = try WorktreePrune.gc(repositoryPath: repo.url.path).reports
        #expect(!reports.isEmpty, "there must be reports")

        for report in reports {
            print("[DEBUG] Report: path=\(normalize(report.path)), type=\(report.type), reason=\(String(describing: report.reason))")
            let desc = report.description
            #expect(!desc.isEmpty, "every report must have a non-empty description")
        }

        // The prunable entry's reason should be git's verbatim wording.
        let prunable = try #require(
            reports.first(where: { normalize($0.path) == normalize(unlockedPath.path) && $0.type == .prunable }),
            "the unlocked, deleted worktree must be reported as prunable")
        #expect(prunable.reason != nil, "prunable entries carry git's own reason verbatim")

        // The abandoned session is at the deleted path.
        let agentDeleted = try #require(reports.first(where: { normalize($0.path) == normalize(deletedPath.path) }))
        #expect(agentDeleted.type == .abandonedSession, "the agent-deleted worktree must be reported as abandoned session")

        // The presentPath path should NOT be in reports at all (its directory exists and it's agent-locked).
        #expect(!reports.contains { normalize($0.path) == normalize(presentPath.path) }, "present agent-locked worktree with existing directory must not be in reports")
    }
}
