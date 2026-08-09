// CommitCreateGPGTests.swift — the GPG/openpgp behavior of CommitCreate (#0037)
//
// NO SIGNING KEY IS CREATED OR USED ANYWHERE IN THIS FILE. `gpg` is not even
// required to be installed: every test pins `gpg.program` — either to a path
// that must not exist, or to a fake shell script that imitates gpg's measured
// wire behavior (stdin in, status lines on the status fd, armor on stdout).
// A script is not a key; no keychain, ~/.gnupg, or ~/.ssh entry is touched.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

/// A path that must not exist — the deterministic stand-in for "gpg absent",
/// measured identical to a gpg-less machine except for one word of stderr.
private let missingGpgPath = "/nonexistent-gpg-for-test"

private func set(_ key: String, _ value: String, in repo: FixtureRepository) throws {
    try GitProcess().run(["config", key, value], workingDirectory: repo.url.path)
}

private func stageChange(in repo: FixtureRepository) throws {
    try repo.writeUntracked(["staged.txt": "staged content\n"])
    try GitProcess().run(["add", "staged.txt"], workingDirectory: repo.url.path)
}

/// Total extraction — `Failure` has one case, so no `guard case` that could
/// silently match-and-return (the #0090 vacuity class).
private func reason(of failure: CommitCreate.Failure) -> String {
    switch failure {
    case let .signingFailed(reason): reason
    }
}

/// Writes `script` into the fixture worktree, marks it executable, and points
/// `gpg.program` at it. The script stands in for gpg; git execs whatever this
/// config names (measured: with the arguments `--status-fd=2 -bsau <key>`).
private func installFakeGpg(_ script: String, in repo: FixtureRepository) throws {
    try repo.writeUntracked(["fake-gpg.sh": script])
    let path = repo.url.appendingPathComponent("fake-gpg.sh").path
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: path)
    try set("gpg.program", path, in: repo)
}

/// Fails the way a real gpg with no usable secret key does (measured shape:
/// git wraps this in `error: gpg failed to sign the data:`).
private let failingGpgScript = """
#!/bin/sh
cat > /dev/null
echo "gpg: signing failed: No secret key" >&2
exit 2
"""

/// Reports success the way git requires: `[GNUPG:] SIG_CREATED ` on the
/// status fd (git passes `--status-fd=2`) and ASCII armor on stdout. Git
/// accepts this and embeds the armor as the commit's `gpgsig` header —
/// measured during planning; the signature bytes are garbage, no key exists.
private let succeedingGpgScript = """
#!/bin/sh
cat > /dev/null
printf '[GNUPG:] SIG_CREATED D\\n' >&2
printf -- '-----BEGIN PGP SIGNATURE-----\\n\\nfakefakefakefake\\n-----END PGP SIGNATURE-----\\n'
exit 0
"""

/// Records git's argument vector, then fails like `failingGpgScript`.
private func argsRecordingGpgScript(loggingTo logPath: String) -> String {
    """
    #!/bin/sh
    printf '%s' "$*" > "\(logPath)"
    cat > /dev/null
    echo "gpg: signing failed: No secret key" >&2
    exit 2
    """
}

// MARK: - The M2 gpg-absent criterion

@Test(arguments: FixtureRepository.RefFormat.supported())
func missingGpgFailsWithSigningFailedAndWritesNoCommit(
    format: FixtureRepository.RefFormat
) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("a")])
    try set("gpg.format", "openpgp", in: repo)
    try set("gpg.program", missingGpgPath, in: repo)
    try stageChange(in: repo)
    let base = try repo.revParse("HEAD")

    let thrown = #expect(throws: CommitCreate.Failure.self) {
        _ = try CommitCreate.run(
            message: "signed", signing: .sign, in: repo.url.path, extraEnvironment: hermetic)
    }
    let failure = try #require(thrown)
    #expect(reason(of: failure).contains("cannot exec '\(missingGpgPath)'"))
    #expect(reason(of: failure).contains("gpg failed to sign the data"))

    // The criterion's second half: no commit was written, and the staged
    // change is still staged — nothing landed unsigned.
    #expect(try repo.revParse("HEAD") == base)
    let status = try GitProcess().run(
        ["status", "--porcelain"], workingDirectory: repo.url.path)
    #expect(status.lines.contains("A  staged.txt"))
}

@Test func unsetGpgFormatDefaultsToOpenpgpAndRoutesThroughGpgProgram() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    // gpg.format deliberately unset — git's default is openpgp, so the
    // commit must route through gpg.program, not ssh-keygen.
    try set("gpg.program", missingGpgPath, in: repo)
    try stageChange(in: repo)

    let thrown = #expect(throws: CommitCreate.Failure.self) {
        _ = try CommitCreate.run(
            message: "signed", signing: .sign, in: repo.url.path, extraEnvironment: hermetic)
    }
    let failure = try #require(thrown)
    #expect(reason(of: failure).contains("cannot exec '\(missingGpgPath)'"))
}

// MARK: - gpg runs and fails

@Test func failingGpgPreservesItsOwnDiagnosticsInTheReason() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(failingGpgScript, in: repo)
    try stageChange(in: repo)

    let thrown = #expect(throws: CommitCreate.Failure.self) {
        _ = try CommitCreate.run(
            message: "signed", signing: .sign, in: repo.url.path, extraEnvironment: hermetic)
    }
    let failure = try #require(thrown)
    // Git wraps the tool's own stderr; both layers must survive into `reason`
    // so an agent reading the error can see WHY gpg failed.
    #expect(reason(of: failure).contains("gpg failed to sign the data"))
    #expect(reason(of: failure).contains("gpg: signing failed: No secret key"))
}

@Test func unsetSigningKeyIsNotAnEarlyFatalForOpenpgp() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    try set("gpg.format", "openpgp", in: repo)
    let log = repo.url.appendingPathComponent("gpg-args.txt").path
    try installFakeGpg(argsRecordingGpgScript(loggingTo: log), in: repo)
    // user.signingKey deliberately unset. Unlike ssh (early fatal: "either
    // user.signingkey or gpg.ssh.defaultKeyCommand needs to be configured"),
    // openpgp falls back to the committer identity and still invokes gpg.
    try stageChange(in: repo)

    let thrown = #expect(throws: CommitCreate.Failure.self) {
        _ = try CommitCreate.run(
            message: "signed", signing: .sign, in: repo.url.path, extraEnvironment: hermetic)
    }
    let failure = try #require(thrown)
    #expect(!reason(of: failure).contains("gpg.ssh.defaultKeyCommand"))

    // gpg WAS invoked, in detached-sign mode — the asymmetry is git's, and
    // this pins it so the ssh-only marker never grows a gpg twin by mistake.
    let args = try String(contentsOfFile: log, encoding: .utf8)
    #expect(args.contains("-bsau"))
}

@Test func userSigningKeyIsPassedThroughToGpg() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    try set("gpg.format", "openpgp", in: repo)
    try set("user.signingKey", "ABCD1234FAKEKEYID", in: repo)
    let log = repo.url.appendingPathComponent("gpg-args.txt").path
    try installFakeGpg(argsRecordingGpgScript(loggingTo: log), in: repo)
    try stageChange(in: repo)

    #expect(throws: CommitCreate.Failure.self) {
        _ = try CommitCreate.run(
            message: "signed", signing: .sign, in: repo.url.path, extraEnvironment: hermetic)
    }

    // "Honors user.signingKey", made observable without any key existing:
    // the configured id reaches gpg's argument vector (`-bsau <key>`).
    let args = try String(contentsOfFile: log, encoding: .utf8)
    #expect(args.contains("ABCD1234FAKEKEYID"))
}

// MARK: - gpg reports success

@Test func gpgReportedSuccessProducesAnOpenpgpSignedCommit() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(succeedingGpgScript, in: repo)
    try stageChange(in: repo)
    let base = try repo.revParse("HEAD")

    let result = try CommitCreate.run(
        message: "signed", signing: .sign, in: repo.url.path, extraEnvironment: hermetic)

    #expect(result.oid == (try repo.revParse("HEAD")))
    #expect(result.oid != base)

    // The commit genuinely carries an openpgp signature header. Only
    // `format` is asserted — it comes from `git cat-file`, independent of
    // the fake gpg; `state` would depend on re-running it as a verifier.
    let verification = try SignatureVerification.run(
        revision: result.oid, in: repo.url.path, extraEnvironment: hermetic)
    #expect(verification.format == .openpgp)
}

// MARK: - The measured stderr shapes, pinned into the classifier

/// Measured 2026-08-07, git 2.50.1 (Apple Git-155), gpg absent from PATH
/// (`which gpg` exits 1 on this machine).
private let measuredGpgAbsentFromPathStderr = """
error: cannot run gpg: No such file or directory
error: gpg failed to sign the data:
(no gpg output)
fatal: failed to write commit object
"""

/// Measured 2026-08-07 with `gpg.program=/nonexistent-gpg-for-test` — the
/// deterministic equivalent; only the first line differs.
private let measuredNonexistentGpgProgramStderr = """
fatal: cannot exec '/nonexistent-gpg-for-test': No such file or directory
error: gpg failed to sign the data:
(no gpg output)
fatal: failed to write commit object
"""

@Test func classifierMatchesEachMeasuredGpgStderrShape() throws {
    let absent = try #require(CommitCreate.classify(
        stderr: measuredGpgAbsentFromPathStderr, signingInEffect: true))
    #expect(reason(of: absent).contains("cannot run gpg"))

    let nonexistent = try #require(CommitCreate.classify(
        stderr: measuredNonexistentGpgProgramStderr, signingInEffect: true))
    #expect(reason(of: nonexistent).contains("cannot exec"))
}
