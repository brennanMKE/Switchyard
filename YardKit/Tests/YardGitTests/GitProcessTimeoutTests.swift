// GitProcessTimeoutTests.swift — the opt-in wall-clock timeout on GitProcess
// (#0163), and its classification at the two signing-adjacent call sites.
//
// NO SIGNING KEY IS CREATED OR USED ANYWHERE IN THIS FILE. Every "hung
// signing helper" is a shell script that sleeps -- `gpg.program` pointed at
// a fake, never at a real `gpg`. No keychain, ~/.gnupg, or ~/.ssh entry is
// touched.
//
// Every test here uses an explicit, short (1-2s) deadline against a fake
// child that sleeps 60s -- never the production `GitProcess.signingTimeout`
// (30s), which only `CommitCreate`/`Fixup` use internally and which no test
// here waits out (round 1 did, at 30s+ per test, and made the full suite
// take twelve minutes instead of the ~38s baseline). `CommitCreate.
// classifyTimeout` and `Fixup.classifyTimeout` are pure, subprocess-free
// functions for exactly this reason: the branch that picks `.signingFailed`
// vs. the original `.timedOut` is tested directly, with no deadline to wait
// out at all.
//
// Rule 7c applies with force here: no test in this file asserts elapsed
// time. Every deadline used is a fixed value the test itself chose, and
// every fake child's sleep (60s) is far longer than any deadline plus the
// 1s termination grace period, so the ordering between "deadline expired"
// and "child would have exited anyway" is never in question.

import Foundation
import Testing
@testable import YardGit

/// Writes an executable script to `path` -- the fake-gpg technique from
/// #0037/CommitCreateGPGTests.swift, generalized to stand in for `git`
/// itself so the timeout mechanism can be exercised directly, with no
/// repository and no real git subprocess involved.
private func writeExecutableScript(_ script: String, to path: String) throws {
    try Data(script.utf8).write(to: URL(fileURLWithPath: path))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: path)
}

/// A directory under the system temp dir, unique per test, removed by the
/// caller's `defer`.
private func makeScratchDirectory() throws -> String {
    let dir = NSTemporaryDirectory() + "yard-timeout-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// An ordinary child that sleeps far longer than any deadline used below and
/// installs no signal handling of its own -- the "terminate() alone is
/// enough" shape measured in #0163's preparatory section.
private let sleepingScript = """
#!/bin/sh
sleep 60
"""

/// A child that ignores SIGTERM -- the pinentry-like shape #0163 exists for.
/// `terminate()` alone does not end this; only the SIGKILL escalation does.
private let sigtermIgnoringScript = """
#!/bin/sh
trap '' TERM
sleep 60
"""

/// Writes `script` into the fixture worktree, marks it executable, and
/// points `gpg.program` at it -- the same shape as CommitCreateGPGTests.
/// swift's `installFakeGpg`, duplicated here so this file has no cross-file
/// private dependency.
private func installFakeGpg(_ script: String, in repo: FixtureRepository) throws {
    try repo.writeUntracked(["fake-gpg.sh": script])
    let path = repo.url.appendingPathComponent("fake-gpg.sh").path
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: path)
    try GitProcess().run(
        ["config", "gpg.program", path], workingDirectory: repo.url.path)
}

private func stageChange(in repo: FixtureRepository) throws {
    try repo.writeUntracked(["staged.txt": "staged content\n"])
    try GitProcess().run(["add", "staged.txt"], workingDirectory: repo.url.path)
}

/// True when `failure` is `.timedOut`, however its associated values differ.
private func isTimedOut(_ failure: GitProcess.Failure) -> Bool {
    if case .timedOut = failure { return true }
    return false
}

// MARK: - The bound itself, exercised directly against a fake `git`

@Test func processFinishingWithinDeadlineReturnsNormally() throws {
    // A generous deadline against a fast, ordinary command: the timeout
    // machinery must not get in the way of the common case.
    let output = try GitProcess().capture(["--version"], timeout: .seconds(30))
    #expect(output.exitCode == 0)
    #expect(!output.text.isEmpty)
}

@Test func sleepingChildIsTerminatedAndReportedAsTimedOut() throws {
    let dir = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let fakeGit = dir + "/fake-git.sh"
    try writeExecutableScript(sleepingScript, to: fakeGit)

    let thrown = #expect(throws: GitProcess.Failure.self) {
        _ = try GitProcess(executablePath: fakeGit).capture([], timeout: .seconds(2))
    }
    let failure = try #require(thrown)

    // Not `.exited` -- a timeout is a distinct failure shape, not a git
    // exit code (and in particular never confused with the SIGKILL status
    // 9 that `ExitClass.signingFailed` also happens to use).
    #expect(isTimedOut(failure))
    #expect(failure.exitClass == .repositoryError)
}

@Test func childIgnoringSigtermIsStillKilled() throws {
    let dir = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let fakeGit = dir + "/fake-git.sh"
    try writeExecutableScript(sigtermIgnoringScript, to: fakeGit)

    // If `terminate()` alone were used in place of the grace-then-SIGKILL
    // escalation, this child would survive it (measured, #0163's
    // preparatory section) and this call would still be blocked when the
    // suite's own per-test timeout fires -- there is no `.timedOut` for the
    // mutation to fail on, because `capture` would never return at all.
    let thrown = #expect(throws: GitProcess.Failure.self) {
        _ = try GitProcess(executablePath: fakeGit).capture([], timeout: .seconds(2))
    }
    let failure = try #require(thrown)
    #expect(isTimedOut(failure))
}

/// A real `git commit --gpg-sign`, invoking a real (fake, sleeping) `gpg`,
/// bounded by an explicit short deadline passed directly to `GitProcess.
/// capture` -- not `CommitCreate.run`, so this measures the mechanism
/// against the real git-plus-gpg process tree without waiting out the 30s
/// production constant. `CommitCreate`'s own classification of this shape
/// is covered, deadline-free, by the pure-function tests below.
@Test func realGitCommitInvokingAHungGpgIsReportedAsTimedOut() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    try GitProcess().run(
        ["config", "gpg.format", "openpgp"], workingDirectory: repo.url.path)
    try installFakeGpg(sleepingScript, in: repo)
    try stageChange(in: repo)
    let base = try repo.revParse("HEAD")

    let thrown = #expect(throws: GitProcess.Failure.self) {
        _ = try GitProcess().capture(
            ["commit", "-m", "signed", "--gpg-sign"],
            workingDirectory: repo.url.path,
            extraEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"],
            timeout: .seconds(2)
        )
    }
    let failure = try #require(thrown)
    #expect(isTimedOut(failure))

    // No commit was written -- the kill happened before git could write
    // the object, exactly as a real signing refusal does.
    #expect(try repo.revParse("HEAD") == base)
}

// MARK: - Classification, pure and subprocess-free

/// Exercises the exact branch `CommitCreate.run`'s do/catch takes on a
/// timed-out `git commit`, with no subprocess and no deadline to wait out:
/// a synthesized `.timedOut` failure, fed straight to the classifier.
@Test func commitCreateClassifiesTimeoutAsSigningFailedOnlyWhenSigningInEffect() {
    let failure = GitProcess.Failure.timedOut(after: .seconds(1), arguments: ["commit"])

    let signingOn = CommitCreate.classifyTimeout(failure, signingInEffect: true)
    let asCommitFailure = signingOn as? CommitCreate.Failure
    #expect(asCommitFailure != nil)
    #expect(asCommitFailure?.exitClass == .signingFailed)

    let signingOff = CommitCreate.classifyTimeout(failure, signingInEffect: false)
    let asGitFailure = signingOff as? GitProcess.Failure
    #expect(asGitFailure != nil)
    #expect(asGitFailure.map(isTimedOut) == true)
    #expect(asGitFailure?.exitClass == .repositoryError)
}

/// The `Fixup` mirror of the test above, for the `git rebase --autosquash`
/// call site.
@Test func fixupClassifiesTimeoutAsSigningFailedOnlyWhenSigningInEffect() {
    let failure = GitProcess.Failure.timedOut(after: .seconds(1), arguments: ["rebase"])

    let signingOn = Fixup.classifyTimeout(failure, signingInEffect: true)
    let asFixupError = signingOn as? FixupError
    #expect(asFixupError != nil)
    #expect(asFixupError?.exitClass == .signingFailed)

    let signingOff = Fixup.classifyTimeout(failure, signingInEffect: false)
    let asGitFailure = signingOff as? GitProcess.Failure
    #expect(asGitFailure != nil)
    #expect(asGitFailure.map(isTimedOut) == true)
    #expect(asGitFailure?.exitClass == .repositoryError)
}
