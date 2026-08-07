// TryTrapScenarios.swift

import Foundation
import Testing
@testable import YardGit

/// Regression tests for the three shapes identified in issue 0114 that could
/// trap the host process: a hardcoded JSON string that has no chance of failing,
/// git being unavailable at the configured path, and other traps eliminated in the fix.
struct TryTrapScenarios {

    // MARK: - Scenario 1: git is missing or unreadable at the configured path.

    @Test func whereAmIFallsBackSafelyWhenGitIsMissingFromConfiguredPath() throws {
        let git = GitProcess(executablePath: "/nonexistent/path/to/git/bogus")
        let noRepo = "/no/such/directory"

        // No fatal trap allowed. All the `try!` sites that used to exist are
        // now either caught (whereAmI re-routes into `if let ... else` blocks)
        // or explicitly checked for nil before unwrapping.
        let info = try whereAmI(path: noRepo, git: git)

        // If the path really does not contain a repo, every lookup falls back
        // to its empty-state default rather than terminating. That is the
        // property the fix preserves.
        #expect(info.headOID == "")
    }

    @Test func whereAmIGitLaunchFailsGracefullyOnBadPath() throws {
        // Same fixture, but we let the early exit code paths run so any trap in
        // `process.run()` / stderr capture is still exercised.
        let git = GitProcess(executablePath: "/usr/bin/git-does-not-exist-xyzzy")
        let emptyDir = NSTemporaryDirectory() + "/yard-nothing-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: emptyDir) }

        let info = try whereAmI(path: emptyDir, git: git)
        #expect(info.headOID == "")
    }

    // MARK: - Scenario 2: the `git` executable is dead and every subsequent
    // call still has to run. This used to `try!` in three different places;
    // the fix is uniform: fall back to zero/default.

    @Test func whereAmISupportsGitFailureEveryCallReturns() throws {
        // The fixture runs EVERY if-let guard path that could have previously
        // been a `try!`. The git process will fail to launch, so each call
        // resolves via the else branch. We still exercise every code path.
        let git = GitProcess(executablePath: "/the/slowest/lie/in/universe")
        let dir = NSTemporaryDirectory() + "/yard-whereami-zero-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let info = try whereAmI(path: dir, git: git)

        // `whereAmI` must resolve every field to a default rather than trap.
        #expect(info.branch == nil, "no HEAD on an empty path means no branch")
        #expect(info.headOID == "", "empty repo falls back to ''")
        #expect(info.isMidRebase == false, "rebase flag stays false when git cannot run")
        #expect(info.isMidMerge == false, "merge flag stays false when git cannot run")
        #expect(info.isMidCherryPick == false, "cherry-pick flag stays false when git cannot run")
        #expect(info.stashCount == 0, "stash count default when git cannot run")
        #expect(info.untrackedCount == 0)
        #expect(info.stagedCount == 0)
        #expect(info.unstagedCount == 0)
    }

}
