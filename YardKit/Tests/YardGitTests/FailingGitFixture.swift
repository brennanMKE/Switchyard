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

/// Writes an executable shim that forwards every invocation to
/// `/usr/bin/git`, capturing its real stdout, then for the exact argv shape
/// `diff --name-only -z` (with or without a trailing `--diff-filter=U`) —
/// the only two commands in the package that use it, both in `WhereAmI.swift`
/// — prints that real, genuine stdout back out and forces exit 1 anyway.
/// Every other command passes through with git's own exit code untouched, so
/// `whereAmI`'s other probes still see a working repository.
///
/// This is the "#0298" construction: the review that filed #0298 could not
/// make real `/usr/bin/git` alone exit non-zero from either command while
/// still writing anything to stdout — measured directly (an unreadable
/// working-tree file, a corrupted blob for a modified path, a corrupted
/// conflict stage entry all produced fatal errors with **empty** stdout,
/// because `git diff --name-only` computes its whole output queue before
/// writing any of it). A shim is the one way to produce the combination: it
/// does not fabricate the stdout content (it is `/usr/bin/git`'s own real
/// output, verified byte-for-byte), it only overrides the exit code
/// afterward, standing in for anything that could make a git-compatible
/// process report failure after already having produced good output — a
/// killed process reaped after a partial write, a wrapping script, a
/// corporate git substitute. Returns the shim's path; the caller owns (and
/// removes) the containing directory.
func writeDiffFailsAfterRealOutputShim(in dir: String) throws -> String {
    let shimPath = dir + "/git-diff-fails-shim.sh"
    // `GitProcess.capture` always prepends `-C <workingDirectory>` ahead of
    // the caller's own arguments (see `GitProcess.swift`'s `argv` assembly),
    // so `diff`/`--name-only`/`-z` never land in `$1`/`$2`/`$3` -- they sit
    // after `-C` and the path. Matching the joined `"$*"` string for the
    // literal substring `diff --name-only -z` sidesteps that positional
    // shift and still matches only these two probes' argv shape (neither
    // `diff-index` nor any other command in the package produces that exact
    // three-token run — confirmed by grep before writing this).
    let script = """
#!/bin/sh
tmp="$(mktemp -p "$(dirname "$0")")"
/usr/bin/git "$@" > "$tmp"
status=$?
case "$*" in
  *"diff --name-only -z"*)
    cat "$tmp"
    rm -f "$tmp"
    exit 1
    ;;
esac
cat "$tmp"
rm -f "$tmp"
exit $status
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
