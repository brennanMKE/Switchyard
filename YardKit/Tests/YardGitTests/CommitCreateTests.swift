// CommitCreateTests.swift — signed and unsigned commit creation (#0036)
//
// NO SIGNING KEY IS CREATED OR USED ANYWHERE IN THIS FILE. Every signing
// fixture points user.signingKey at a path that must not exist; the whole
// point is git's measured refusal. The success path is exercised unsigned.

import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

/// A path that must not exist. Never a real key; see the header comment.
private let missingKeyPath = "/nonexistent-signing-key-for-test"

private func set(_ key: String, _ value: String, in repo: FixtureRepository) throws {
    try GitProcess().run(["config", key, value], workingDirectory: repo.url.path)
}

/// Stages one new file so `git commit` has something to commit.
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

@Test(arguments: FixtureRepository.RefFormat.supported())
func plainCommitCreatesACommitAndReturnsItsOid(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("a")])
    let base = try repo.revParse("HEAD")
    try stageChange(in: repo)

    let result = try CommitCreate.run(
        message: "plain commit", in: repo.url.path, extraEnvironment: hermetic)

    #expect(result.oid == (try repo.revParse("HEAD")))
    #expect(result.oid != base)
    #expect(!result.oid.isEmpty)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func unsignableCommitFailsWithSigningFailedAndWritesNoCommit(
    format: FixtureRepository.RefFormat
) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("a")])
    try set("gpg.format", "ssh", in: repo)
    try set("user.signingKey", missingKeyPath, in: repo)
    try stageChange(in: repo)
    let base = try repo.revParse("HEAD")

    // The fixture presets commit.gpgsign=false, so this also proves the
    // measured precedence: `--gpg-sign` beats a configured false.
    let thrown = #expect(throws: CommitCreate.Failure.self) {
        _ = try CommitCreate.run(
            message: "signed", signing: .sign, in: repo.url.path, extraEnvironment: hermetic)
    }
    let failure = try #require(thrown)
    #expect(reason(of: failure).contains("Couldn't load public key"))

    // The criterion's second half: no commit was written, and the staged
    // change is still staged — the failure did not half-happen.
    #expect(try repo.revParse("HEAD") == base)
    let status = try GitProcess().run(
        ["status", "--porcelain"], workingDirectory: repo.url.path)
    #expect(status.lines.contains("A  staged.txt"))
}

@Test func noSignOverridesConfiguredSigningAndCommitsUnsigned() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "ssh", in: repo)
    try set("user.signingKey", missingKeyPath, in: repo)
    try stageChange(in: repo)

    // The key is unloadable, so this succeeds ONLY if --no-gpg-sign actually
    // suppressed signing — the measured "flag beats config=true" precedence.
    let result = try CommitCreate.run(
        message: "unsigned", signing: .noSign, in: repo.url.path, extraEnvironment: hermetic)

    let verification = try SignatureVerification.run(
        revision: result.oid, in: repo.url.path, extraEnvironment: hermetic)
    #expect(verification.state == .noSignature)
}

@Test func configuredSigningIsAttemptedByDefault() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "ssh", in: repo)
    try set("user.signingKey", missingKeyPath, in: repo)
    try stageChange(in: repo)

    // No flag at all: commit.gpgsign=true alone must reach git and fail there.
    #expect(throws: CommitCreate.Failure.self) {
        _ = try CommitCreate.run(
            message: "signed", in: repo.url.path, extraEnvironment: hermetic)
    }
}

@Test func unsetSigningKeyFailsWithGitsConfigGuidance() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    try set("gpg.format", "ssh", in: repo)
    // user.signingKey deliberately unset — the fixture never sets one.
    try stageChange(in: repo)

    let thrown = #expect(throws: CommitCreate.Failure.self) {
        _ = try CommitCreate.run(
            message: "signed", signing: .sign, in: repo.url.path, extraEnvironment: hermetic)
    }
    let failure = try #require(thrown)
    #expect(reason(of: failure).contains("user.signingkey or gpg.ssh.defaultKeyCommand"))
}

@Test func nonSigningCommitFailurePropagatesAsGitProcessFailure() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    // Nothing staged: `git commit` exits 1. Not a signing failure.
    #expect(throws: GitProcess.Failure.self) {
        _ = try CommitCreate.run(
            message: "empty", in: repo.url.path, extraEnvironment: hermetic)
    }
}

@Test func signingFailureCarriesExitClassNine() throws {
    let failure: any ExitClassCarrying = CommitCreate.Failure.signingFailed(reason: "x")
    #expect(failure.exitClass == .signingFailed)
    #expect(failure.exitClass.rawValue == 9)
}

@Test func argumentsForEachSigningIntent() throws {
    #expect(CommitCreate.arguments(for: .config) == [])
    #expect(CommitCreate.arguments(for: .sign) == ["--gpg-sign"])
    #expect(CommitCreate.arguments(for: .noSign) == ["--no-gpg-sign"])
}

/// The two measured stderr shapes, verbatim from #0036's Givens (git 2.50.1).
private let measuredUnloadableKeyStderr = """
error: Couldn't load public key /nonexistent-signing-key-for-test: No such file or directory?

fatal: failed to write commit object
"""

private let measuredUnsetKeyStderr =
    "fatal: either user.signingkey or gpg.ssh.defaultKeyCommand needs to be configured\n"

@Test func classifierMatchesEachMeasuredStderrShape() throws {
    let unloadable = try #require(
        CommitCreate.classify(stderr: measuredUnloadableKeyStderr, signingInEffect: true))
    #expect(reason(of: unloadable).hasPrefix("error: Couldn't load public key"))
    #expect(reason(of: unloadable).hasSuffix("failed to write commit object"))

    let unset = try #require(
        CommitCreate.classify(stderr: measuredUnsetKeyStderr, signingInEffect: true))
    #expect(reason(of: unset).contains("gpg.ssh.defaultKeyCommand"))

    // A failure that is not about signing stays unclassified even while
    // signing is in effect — a declining hook must remain a repository error.
    #expect(CommitCreate.classify(
        stderr: "husky - pre-commit hook exited with code 1 (error)\n",
        signingInEffect: true) == nil)
}

@Test func classifierRequiresSigningToBeInEffect() throws {
    // The same stderr that classifies above must NOT classify when no
    // signature was being attempted: an unsigned commit whose object write
    // fails is a repository error, never exit 9.
    #expect(CommitCreate.classify(
        stderr: measuredUnloadableKeyStderr, signingInEffect: false) == nil)
}
