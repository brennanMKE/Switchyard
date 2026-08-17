// GitProcessTimeoutTests.swift — the opt-in wall-clock timeout on GitProcess
// (#0163), and its classification at the two signing-adjacent call sites.
//
// NO SIGNING KEY IS CREATED OR USED ANYWHERE IN THIS FILE. Every "hung
// signing helper" is a shell script that sleeps -- `gpg.program` pointed at
// a fake, never at a real `gpg`. No keychain, ~/.gnupg, or ~/.ssh entry is
// touched.
//
// Rule 7c applies with force here: no test in this file asserts elapsed
// time. Every deadline used is a fixed value the production code was told
// to use, and every fake child's sleep (60s) is far longer than any
// deadline plus the 1s termination grace period, so the ordering between
// "deadline expired" and "child would have exited anyway" is never in
// question.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

private func set(_ key: String, _ value: String, in repo: FixtureRepository) throws {
    try GitProcess().run(["config", key, value], workingDirectory: repo.url.path)
}

private func stageChange(in repo: FixtureRepository) throws {
    try repo.writeUntracked(["staged.txt": "staged content\n"])
    try GitProcess().run(["add", "staged.txt"], workingDirectory: repo.url.path)
}

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
/// points `gpg.program` at it -- identical to CommitCreateGPGTests.swift's
/// `installFakeGpg`, duplicated here so this file has no cross-file private
/// dependency.
private func installFakeGpg(_ script: String, in repo: FixtureRepository) throws {
    try repo.writeUntracked(["fake-gpg.sh": script])
    let path = repo.url.appendingPathComponent("fake-gpg.sh").path
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: path)
    try set("gpg.program", path, in: repo)
}

/// Resolves the repo's effective hooks directory the way the engine does
/// (`WorktreeContext.path(for:)`, never string concatenation onto `.git/`).
private func hooksDirectory(_ repo: FixtureRepository) throws -> String {
    try WorktreeContext.resolve(path: repo.url.path).path(for: "hooks")
}

private func writeHook(_ name: String, in directory: String, content: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
    try Data(content.utf8).write(to: url)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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

// MARK: - Classification at the signing-adjacent call sites

@Test func hungSigningHelperClassifiesAsSigningFailed() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(sleepingScript, in: repo)
    try stageChange(in: repo)
    let base = try repo.revParse("HEAD")

    let thrown = #expect(throws: CommitCreate.Failure.self) {
        _ = try CommitCreate.run(
            message: "signed", signing: .sign, in: repo.url.path, extraEnvironment: hermetic)
    }
    let failure = try #require(thrown)
    #expect(failure.exitClass == .signingFailed)

    // No commit was written -- the timeout killed `git commit` before it
    // could write the object, exactly as a real signing refusal does.
    #expect(try repo.revParse("HEAD") == base)
}

@Test func hungHookWithSigningOffClassifiesAsRepositoryError() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    // No gpg involved at all: `.noSign` passes `--no-gpg-sign`, so nothing
    // could ever invoke a signing helper here. The hang is a pre-commit
    // hook, which `git commit` still waits on regardless of signing -- the
    // timeout is signing-adjacent by call site, not by cause, and a timeout
    // with signing not in effect must not be misclassified as `.signing
    // Failed` just because it happened on this code path.
    try writeHook("pre-commit", in: try hooksDirectory(repo), content: sleepingScript)
    try stageChange(in: repo)
    let base = try repo.revParse("HEAD")

    let thrown = #expect(throws: GitProcess.Failure.self) {
        _ = try CommitCreate.run(
            message: "should time out", signing: .noSign, in: repo.url.path,
            extraEnvironment: hermetic)
    }
    let failure = try #require(thrown)
    #expect(isTimedOut(failure))
    #expect(failure.exitClass == .repositoryError)
    #expect(try repo.revParse("HEAD") == base)
}
