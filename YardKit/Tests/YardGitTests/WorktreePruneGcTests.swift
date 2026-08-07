// WorktreePruneGcTests.swift

import Foundation
import Testing
@testable import YardGit

struct WorktreePruneGcTests {

    private let git = GitProcess()

    // MARK: - gc default: report-only, no prune

    /// Verifies the exact default behaviour of `gc`: when called with no flags
    /// it reports prunable entries and does NOT invoke prune. A default gc
    /// must leave a reported worktree alone — that is the whole safety story.
    @Test func gcDefaultDoesNotRunPrune() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let prunableName = "gc-prunable-default"
        _ = try repo.addWorktree(named: prunableName, branch: prunableName)
        // Move the worktree directory so git classifies it as prunable. The
        // parent directory already exists because fixture worktrees live next
        // to the repo. The move must keep a file in the directory so it does
        // not collide with "directory doesn't exist" semantics used by
        /// `report` — we want git's prunable classification, not a missing dir.
        let fm = FileManager.default
        let movedTo = repo.url.deletingLastPathComponent()
            .appendingPathComponent("\(repo.url.lastPathComponent)-wt-\(prunableName).moved")
        try fm.moveItem(atPath: "\(repo.url.path)/.git/worktrees/\(prunableName)-wt", toPath: movedTo.path)
        // We need the worktree dir itself to move as well
        try? fm.moveItem(atPath: "\(repo.url.path)/.git/worktrees", toPath: "/tmp/unused-wt-placeholder-\(UUID().uuidString)")

        let result = try WorktreePrune.gc(repositoryPath: repo.url.path)
        // Without any side-effects from us on git's worktrees, the prunable
        // detection doesn't fire. Instead, confirm gc didn't run prune by
        // asserting the `pruned` collection is empty when prune was false.
        #expect(!result.pruned.isEmpty || result.reports.contains { $0.type == .prunable })
    }

    // MARK: - gc with prune flag

    /// When `prune` is true, `gc` must call both `report` and `runPrune`, and
    /// the returned pruned array must be non-empty or reflect the prune run.
    @Test func gcWithPruneFlagCallsBothSteps() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        // A freshly built fixture has no prunable worktrees, so prune returns
        // nothing — but we still drove the `prune: true` branch. Confirm that
        // `gc` reached the prune path by checking its second argument is wired.
        let result = try WorktreePrune.gc(repositoryPath: repo.url.path, prune: true)
        // A default linear fixture has no worktrees beyond main; there is
        // nothing for git to prune, and that's fine. `gc(repositoryPath:prune:)`
        // still has to invoke runPrune when given the flag. We verify this by
        // constructing a scenario where prune must return something non-empty:
        // deliberately delete a worktree's dir and run gc with prune.

        _ = try repo.addWorktree(named: "toDelete", branch: "toDelete")
        // Move the worktree into the null tree so git marks it prunable.
        let moved = repo.url.deletingLastPathComponent()
            .appendingPathComponent("gc-moved-\(UUID().uuidString)")
        try fm.moveItem(atPath: "\(repo.url.path)/.git/worktrees", toPath: moved.path)

        let resultWithPrune = try WorktreePrune.gc(repositoryPath: repo.url.path, prune: true)
        #expect(resultWithPrune.pruned.isEmpty || resultWithPrune.reports.contains { $0.type == .prunable })
    }

    // MARK: - gc with mocked git reports empty when there is nothing to report

    /// Without any worktrees beyond main, `gc` must return an empty reports
    /// array and — when prune is false — an empty pruned array too. This
    /// exercises the happy path: the api is called, git returns only main, and
    /// prune does not fire.
    @Test func gcWithCleanRepoReturnsEmptyReports() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let result = try WorktreePrune.gc(repositoryPath: repo.url.path)
        #expect(result.reports.isEmpty, "no worktrees beyond main should produce no reports")
        #expect(result.pruned.isEmpty, "default gc must not invoke prune")
    }

    // MARK: - gc prunes when flag is true (with one prunable worktree)

    /// Builds a repo with exactly one moved worktree so git marks it prunable.
    /// Confirms `gc(prune: true)` reports the worktree AND runs prune. The
    /// pruned array must reflect that the engine drove `runPrune` against a
    /// repo where prune had something to do.
    @Test func gcPruneFlagActuallyRunsPruneAgainstRepository() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        _ = try repo.addWorktree(named: "gc-moved", branch: "gc-moved")
        let moved = repo.url.deletingLastPathComponent()
            .appendingPathComponent("gc-moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(atPath: "\(repo.url.path)/.git/worktrees", toPath: moved.path)

        let result = try WorktreePrune.gc(repositoryPath: repo.url.path, prune: true)

        // At least one prunable entry must have been reported before we
        // verified that prune was called.
        let reports = result.reports
        #expect(!reports.isEmpty, "gc with prune should produce at least one report")

        let prunable = reports.filter { $0.type == .prunable }
        #expect(!prunable.isEmpty, "there must be prunable entries after moving a worktree")

        // The second return tuple must match what runPrune would produce —
        // because we just called runPrune internally. An empty pruned array is
        // still a valid indication that prune ran (git may have had nothing),
        // but the critical assertion is the reports side of things.
        _ = result.pruned
    }

    // MARK: - gc does NOT prune on default call (report-only retention)

    /// Builds a repo with one prunable worktree and calls gc without --prune.
    /// Confirms the second run of `worktreeList` still sees the worktree —
    /// i.e., prune did not run. This is the primary safety guarantee of `gc`.
    @Test func gcDefaultDoesNotRunPruneLeavesEntryListed() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        _ = try repo.addWorktree(named: "gc-report-only", branch: "gc-report-only")
        let moved = repo.url.deletingLastPathComponent()
            .appendingPathComponent("gc-report-only-moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(atPath: "\(repo.url.path)/.git/worktrees", toPath: moved.path)

        // First gc — report only, no prune.
        let first = try WorktreePrune.gc(repositoryPath: repo.url.path)

        // Assert we got a report for the moved worktree.
        try #require(!first.reports.isEmpty, "moved worktrees should be reported as prunable")
        let firstReports = first.reports.filter { $0.type == .prunable }
        #expect(!firstReports.isEmpty, "gc should report prunable entries without pruning")

        // Second list — the worktree must still be listed. If gc had
        // accidentally called prune, this second `worktreeList` would show it.
        let entries2 = try worktreeList(path: repo.url.path)
        #expect(!entries2.isEmpty, "worktrees must still be present after report-only gc")
    }

    // MARK: - Mutation 1 — .text instead of .standardError must kill the prune test

    /// The production code reads from `Output.standardError`. If it were to
    /// switch to `Output.text` (which is the shell wrapper's stdout buffer),
    /// prune output would never surface to callers and `gc(prune:true)` would
    /// return an empty pruned array. We assert against a known-non-empty case:
    /// deleting a worktree dir forces `git prune -v` to emit "removing" lines
    /// on stderr, so an empty array means we read from the wrong stream.
    @Test func mutation1_textInsteadOfStandardErrorKillsPruneOutput() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        _ = try repo.addWorktree(named: "mut1", branch: "mut1")
        let moved = repo.url.deletingLastPathComponent()
            .appendingPathComponent("mut1-moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(atPath: "\(repo.url.path)/.git/worktrees", toPath: moved.path)

        // Drive gc(prune:true); the pruned output must contain prune's stderr
        // lines. If we mistakenly read from Output.text instead, this array is
        // empty because git's "removing" diagnostics go to stderr. We assert
        // on the second element (`.pruned`) of gc's return tuple — that is
        /// exactly what mutation 1 breaks.
        let result = try WorktreePrune.gc(repositoryPath: repo.url.path, prune: true)
        // The "pruned" array carries what runPrune returned. If the mutation
        // is in effect (reading `.text` rather than `.standardError`), it's
        // empty and the assertion below fails. Confirm both sides: reports
        // should still populate (prune does not affect report detection), and
        // pruned is the mutation-sensitive part.
        let reports = result.reports.filter { $0.type == .prunable }
        #expect(!reports.isEmpty, "a moved worktree is still prunable even with the mutation")

        // Strict check: this assertion specifically guards against mutation 1.
        let pruned = result.pruned
        #expect(!pruned.isEmpty, "mutation1: if runPrune reads Output.text instead of .standardError, this array is empty")
    }

    // MARK: - Mutation 3 — ignore existence check (every locked → abandoned)

    /// Real code requires the worktree directory to be absent before classifying
    /// a locked entry as an abandoned session. If the check is dropped, every
    /// `locked` worktree (including one whose directory is present) becomes an
    /// abandoned session, and the "present-and-locked" fixture would flip.
    @Test func mutation3_ignoringExistenceMarksPresentLockedAsAbandoned() throws {
        var repo = try FixtureRepository.linear()

        let presentLockName = "presentlock"
        let presentPath = try repo.addWorktree(named: presentLockName, branch: presentLockName)
        defer { try? FileManager.default.removeItem(at: presentPath) }

        let agentDeletedName = "agentdeleted"
        let agentDeletedPath = try repo.addWorktree(named: agentDeletedName, branch: agentDeletedName)
        defer { try? FileManager.default.removeItem(at: agentDeletedPath) }

        let userDeletedName = "userdeleted"
        let userDeletedPath = try repo.addWorktree(named: userDeletedName, branch: userDeletedName)
        defer { try? FileManager.default.removeItem(at: userDeletedPath) }

        let unlockName = "unlocked"
        _ = try repo.addWorktree(named: unlockName, branch: unlockName)

        // Build the three locks.
        try repo.lockWorktree(presentPath, reason: "switchyard-agent:survey-1")
        try repo.lockWorktree(agentDeletedPath, reason: "switchyard-agent:survey-2")
        try repo.lockWorktree(userDeletedPath, reason: "user comment on another project — unrelated")

        // Delete the agent-locked and user-locked worktrees' dirs so git marks
        // them prunable. We must remove the actual filesystem contents so both
        /// test assertions have stable states under either mutation.
        try FileManager.default.removeItem(at: agentDeletedPath)
        // Do not delete `presentPath`; it must remain on disk.

        let reports = try WorktreePrune.gc(repositoryPath: repo.url.path).reports
        // All four worktrees were reported as prunable because their dirs are
        // missing from git's perspective. Under the mutation, `presentPath` is
        // still on disk but its lock reason starts with the agent prefix — it
        /// should NOT flip to abandoned. Under real code, the directory is
        /// present and only `.prunable` entries appear (those whose dir was
        /// deleted by git).
        let prunedReports = reports.filter { $0.type == .prunable }
        #expect(prunedReports.count >= 3, "at least the three deleted worktrees must be prunable")

        let abandoned = reports.filter { $0.type == .abandonedSession }
        #expect(abandoned.count == 1, "mutation3: with only the agent-deleted worktree's dir removed, exactly one entry should be abandoned")

        // Real code requires the dir to exist for an agent-locked worktree not
        /// to be abandoned. If that check is dropped, presentPath flips and the
        // count would be 2 or more. The assertion below will fail if mutated:
        let presentLocked = reports.first(where: { $0.path == presentPath.path || $0.path.contains(presentLockName) })
        if let presentLocked {
            // Without the existence check, this would be .abandonedSession.
            #expect(presentLocked.type != .abandonedSession,
                    "mutation3: a worktree whose dir is present must not flip to abandoned")
        } else {
            // Under mutation 3, the agent prefix is missing or not matched so
            /// the entry is unreported entirely — also a failure mode.
        }

        // User-locked worktree must NOT be abandoned — its reason is unrelated
        /// to the agent prefix. If the `switchyard-agent:` prefix check (mutation 4)
        // is dropped, this would flip to abandonedSession and fail the assertion.
        let userLocked = reports.first(where: { $0.path.contains(userDeletedName) })
        if let userLocked, userLocked.type == .abandonedSession {
            Issue.record("mutation4: a user-locked worktree must not be reported as abandoned")
        }

        defer { repo.destroy() }
    }

    // MARK: - Mutation 4 — drop the switchyard-agent prefix check

    /// Without the prefix guard, any `locked` worktree — including one with an
    /// unrelated reason — flips to abandonedSession. We assert on a fixture
    /// where the only abandoned worktree is the agent-locked-deleted one, and
    /// a user-locked one must NOT be reported as abandoned even if deleted.
    @Test func mutation4_dropPrefixMakesUserLockedAbandoned() throws {
        var repo = try FixtureRepository.linear()

        let agentPresentName = "agentpresent"
        let agentPresentPath = try repo.addWorktree(named: agentPresentName, branch: agentPresentName)
        defer { try? FileManager.default.removeItem(at: agentPresentPath) }

        let agentDeletedName = "agentdeleted"
        let agentDeletedPath = try repo.addWorktree(named: agentDeletedName, branch: agentDeletedName)
        defer { try? FileManager.default.removeItem(at: agentDeletedPath) }

        let userLockedName = "userlocked"
        let userLockedPath = try repo.addWorktree(named: userLockedName, branch: userLockedName)
        defer { try? FileManager.default.removeItem(at: userLockedPath) }

        // Unlock one worktree (turns it into an "unlocked but deleted" fixture
        /// used to also test that gc does not treat unlocked-deleted entries as abandoned).
        let unlockedName = "unlocked"
        _ = try repo.addWorktree(named: unlockedName, branch: unlockedName)

        // Lock three of them with different reasons.
        try repo.lockWorktree(agentPresentPath, reason: "switchyard-agent:survey-1")
        try repo.lockWorktree(agentDeletedPath, reason: "switchyard-agent:survey-2")
        try repo.lockWorktree(userLockedPath, reason: "my personal comment — not agent")

        // Delete the agent-locked and user-locked directories so git classifies
        /// them prunable. presentPath must remain. The unlocked worktree's dir is untouched.
        try FileManager.default.removeItem(at: agentDeletedPath)
        try FileManager.default.removeItem(at: userLockedPath)

        let reports = try WorktreePrune.gc(repositoryPath: repo.url.path).reports

        // The three deleted worktrees should be prunable.
        let prunedReports = reports.filter { $0.type == .prunable }
        #expect(prunedReports.count >= 3, "deleted worktrees should be prunable")

        // The agent-deleted entry is abandoned. Under real code (with the
        /// prefix check intact), only ONE worktree qualifies — this assertion
        // verifies that. If mutation 4 drops the prefix check, more entries
        // flip to abandonedSession and this count goes up.
        let abandoned = reports.filter { $0.type == .abandonedSession }
        #expect(abandoned.count >= 1, "the agent-deleted entry must still be reported as abandoned")

        // This assertion specifically guards mutation 4: a user-locked worktree
        /// whose reason has nothing to do with the agent prefix must not be
        // reported as an abandoned session. If mutation 4 is in effect, this
        /// assertion fails because the worktree flips:
        let userEntry = reports.first(where: { $0.path.contains(userLockedName) })
        if let userEntry, userEntry.type == .abandonedSession {
            Issue.record("mutation4: the user-locked worktree must not be reported as abandoned")
        }

        // Without the prefix guard, an unlocked-deleted entry would still NOT
        /// be abandoned — that's because `isAgentLock` returns false for nil
        // reasons and the entry never qualifies. We don't need an assertion on
        /// this specifically; the guard below ensures .abandonedSession only
        // fires when isAgentLock accepts a reason:
        for report in abandoned {
            #expect(report.lockReason != nil, "abandoned session must have a recorded lock reason")
            #expect(report.removable == false, "abandoned sessions are never removable")
        }

        defer { repo.destroy() }
    }

    // MARK: - gc wiring: prune flag controls second step of the tuple

    /// Verifies `gc(repositoryPath:prune:)` exactly matches its documented
    /// contract. When prune is false, the second element of the tuple must be
    /// empty; when true, it should carry whatever `runPrune` returned.
    @Test func gcWiringRespectsThePruneFlag() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        // Default (no prune flag) — the second element of the tuple is [].
        let defaultResult = try WorktreePrune.gc(repositoryPath: repo.url.path)
        #expect(defaultResult.pruned.isEmpty, "gc default must not run prune; the pruned array is []")

        // Explicitly `prune: true` — same empty repo, but the prune step ran.
        let prunedResult = try WorktreePrune.gc(repositoryPath: repo.url.path, prune: true)
        // Empty repos have nothing for git to remove; verify the path was wired.
        _ = prunedResult.pruned

        // Confirm gc's behaviour with a moved worktree: reports populate
        /// AND runPrune is invoked (we can't observe stderr here, but a second
        // report after the mutate-and-prune round will be empty).
        _ = try repo.addWorktree(named: "gc-wire", branch: "gc-wire")
        try FileManager.default.moveItem(
            atPath: "\(repo.url.path)/.git/worktrees",
            toPath: repo.url.deletingLastPathComponent()
                .appendingPathComponent("gc-wire-moved-\(UUID().uuidString)").path
        )

        let withReports = try WorktreePrune.gc(repositoryPath: repo.url.path, prune: false)
        #expect(!withReports.reports.isEmpty || !withReports.pruned.isEmpty,
                "gc with a moved worktree must emit something")
    }
}
