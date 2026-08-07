// FailingGitFixture.swift

import Foundation
import Testing
@testable import YardGit

/// A fixture that wires `/usr/bin/false` in as git. Unlike the non-existent
/// path used in `TryTrapScenarios`, this proves that *every* count field lands at
/// the default (zero) even when git is running but exiting non-zero. We also use
/// this as the anchor for the "return 0 mutated to 99" test — changing that
/// default would flip this assertion red.

private let failingPath = "/usr/bin/false"

@Test func countsAreZeroWhenGitRunsNonZero() throws {
    // The production code that reads stash/untracked/staged counts does not
    // care whether the process failed to launch; it only cares about the exit
    // code and uses `0` for both failure modes. We check all four of them so a
    // mutation that replaces any single `return 0` with another value (99, for
    // instance) must fail this test rather than continuing green.

    let dir = NSTemporaryDirectory() + "/yard-fail-git-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let git = GitProcess(executablePath: failingPath)
    let info = try whereAmI(path: dir, git: git)

    #expect(info.stashCount == 0, "stash count must be zero when git runs non-zero")
    #expect(info.untrackedCount == 0, "untracked count must be zero when git runs non-zero")
    #expect(info.stagedCount == 0, "staged count must be zero when git runs non-zero")
    #expect(info.unstagedCount == 0, "unstaged count must be zero when git runs non-zero")

}
