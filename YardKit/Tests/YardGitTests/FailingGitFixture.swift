// FailingGitFixture.swift

import Foundation
import Testing
@testable import YardGit

/// Pins the count-closure defaults: every count field lands at zero when git
/// runs but exits non-zero. This is the anchor for the "`return 0` mutated to
/// 99" mutation — changing any default flips the first test red.
///
/// Before #0140 this file wired `/usr/bin/false` in as git. The
/// not-a-repository gate resolves `WorktreeContext` first, and a git that
/// cannot answer `rev-parse` is indistinguishable from no repository — so a
/// git that fails *everything* now throws at the gate (the second test pins
/// exactly that). To keep the count defaults reachable, the first test uses a
/// shim that answers `rev-parse` with the real git and exits 1 for every
/// other command, run against a real repository.

/// Writes an executable shim script that passes `rev-parse` invocations
/// through to `/usr/bin/git` and exits 1 for everything else. Returns the
/// shim's path; the caller owns (and removes) the containing directory.
///
/// Internal, not private: `WorktreeWhereTests` reuses this rather than
/// writing a second shim for the same "rev-parse succeeds, everything else
/// fails" shape (#0287).
func writeRevParseOnlyShim(in dir: String) throws -> String {
    let shimPath = dir + "/git-shim.sh"
    let script = """
#!/bin/sh
case "$*" in
  *rev-parse*) exec /usr/bin/git "$@" ;;
  *) exit 1 ;;
esac
"""
    try script.write(toFile: shimPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: shimPath)
    return shimPath
}

@Test func countsAreZeroWhenGitRunsNonZero() throws {
    // The production code that reads stash/untracked/staged/unstaged counts
    // does not care whether the command failed to launch; it only cares about
    // the exit code and uses `0` for both failure modes. We check all four so
    // a mutation that replaces any single `return 0` with another value (99,
    // for instance) must fail this test rather than continuing green.

    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    let shimDir = NSTemporaryDirectory() + "yard-fail-git-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
        atPath: shimDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: shimDir) }

    let git = GitProcess(executablePath: try writeRevParseOnlyShim(in: shimDir))
    let info = try whereAmI(path: repo.url.path, git: git)

    #expect(info.stashCount == 0, "stash count must be zero when git runs non-zero")
    #expect(info.untrackedCount == 0, "untracked count must be zero when git runs non-zero")
    #expect(info.stagedCount == 0, "staged count must be zero when git runs non-zero")
    #expect(info.unstagedCount == 0, "unstaged count must be zero when git runs non-zero")
}

@Test func fullyFailingGitThrowsAtTheGate() throws {
    // `/usr/bin/false` launches and exits 1 for everything, including the
    // `rev-parse` calls `WorktreeContext.resolve` makes — so even inside a
    // real repository the gate cannot tell it from "not a repository" and
    // throws rather than returning a success value built from failures.
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    let git = GitProcess(executablePath: "/usr/bin/false")
    #expect(throws: WorktreeContext.Error.self) {
        _ = try whereAmI(path: repo.url.path, git: git)
    }
}
