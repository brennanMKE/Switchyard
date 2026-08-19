// SignatureVerificationTests.swift

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

private let fakeSSHSignatureBlock = """
gpgsig -----BEGIN SSH SIGNATURE-----
 U1NIU0lHTAAAAAWZha2VmYWtlZmFrZQ==
 -----END SSH SIGNATURE-----
"""

private let fakePGPSignatureBlock = """
gpgsig -----BEGIN PGP SIGNATURE-----
 iQFAKEFAKEFAKE=
 =fake
 -----END PGP SIGNATURE-----
"""

private func craftedCommit(in repo: FixtureRepository, block: String) throws -> String {
    let tree = try repo.revParse("HEAD^{tree}")
    let ident = "Fixture <fixture@example.invalid> 1700000000 +0000"
    let object = """
    tree \(tree)
    author \(ident)
    committer \(ident)
    \(block)

    crafted signed commit
    """ + "\n"
    let out = try GitProcess().run(
        ["hash-object", "-t", "commit", "-w", "--stdin", "--literally"],
        workingDirectory: repo.url.path,
        standardInput: Data(object.utf8)
    )
    return out.lines[0]
}

@Test(arguments: FixtureRepository.RefFormat.supported()) func unsignedCommitReportsNoSignature(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([FixtureRepository.Commit("a")])

    let result = try SignatureVerification.run(revision: "HEAD", in: repo.url.path, extraEnvironment: hermetic)
    #expect(result.state == .noSignature)
    #expect(result.format == .none)
    #expect(result.signer == nil)
    #expect(result.key == nil)
}

@Test(arguments: FixtureRepository.RefFormat.supported()) func craftedBadSSHSignatureReportsBad(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([FixtureRepository.Commit("a")])

    let sha = try craftedCommit(in: repo, block: fakeSSHSignatureBlock)
    try repo.writeUntracked(["allowed_signers": ""])
    try GitProcess().run(
        ["config", "gpg.ssh.allowedSignersFile",
         repo.url.appendingPathComponent("allowed_signers").path],
        workingDirectory: repo.url.path
    )

    let result = try SignatureVerification.run(revision: sha, in: repo.url.path, extraEnvironment: hermetic)
    #expect(result.state == .bad)
    #expect(result.format == .ssh)
}

@Test func sshSignatureWithoutAllowedSignersFileIsCannotCheckNotNoSignature() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([FixtureRepository.Commit("a")])

    let sha = try craftedCommit(in: repo, block: fakeSSHSignatureBlock)
    // No allowedSignersFile configured.

    let result = try SignatureVerification.run(revision: sha, in: repo.url.path, extraEnvironment: hermetic)
    if case .cannotCheck(let reason) = result.state {
        #expect(reason.contains("allowedSignersFile"))
    } else {
        Issue.record("expected .cannotCheck, got \(result.state)")
    }
    #expect(result.state != .noSignature)
}

/// Writes `script` into the fixture worktree, marks it executable, and
/// points `gpg.program` at it -- the same shape as `CommitCreateGPGTests.
/// installFakeGpg` (#0037), duplicated here rather than shared across files.
/// `installFakeGpg` is declared `private` there, and Swift's top-level
/// `private` is file-scoped, so it is not visible from this file; promoting
/// it to module-visible would collide with the two *other* files that
/// already carry their own private copy of this exact helper for the same
/// reason (`FixupTests.swift`, and `GitProcessTimeoutTests.swift` -- whose
/// own comment reads "duplicated here so this file has no cross-file
/// private dependency"). De-duplicating three call sites at once is outside
/// #0270's scope, which names only this file and the one already holding
/// the helper, so this follows the pattern already established rather than
/// inventing a fourth approach.
private func installFakeGpg(_ script: String, in repo: FixtureRepository) throws {
    try repo.writeUntracked(["fake-gpg.sh": script])
    let path = repo.url.appendingPathComponent("fake-gpg.sh").path
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: path)
    try GitProcess().run(
        ["config", "gpg.program", path], workingDirectory: repo.url.path)
}

/// Reports a good, trusted signature the way `%G?`/`%GS`/`%GK` read it,
/// measured against git 2.50.1: git invokes `gpg.program` with
/// `--keyid-format=long --status-fd=1 --verify <tmp> -` for `git log`'s
/// `%G?` family, so status lines belong on stdout here (unlike the
/// signing-time scripts in `CommitCreateGPGTests`, which write to stderr
/// because git passes `--status-fd=2` when signing).
private let verifyingGpgScript = """
#!/bin/sh
echo "[GNUPG:] NEWSIG"
echo "[GNUPG:] GOODSIG DEADBEEFCAFE1234 Fixture <f@example.invalid>"
echo "[GNUPG:] VALIDSIG ABCDEF0123456789ABCDEF0123456789ABCDEF01 2026-01-01 1700000000 0 4 0 1 8 00 ABCDEF0123456789ABCDEF0123456789ABCDEF01"
echo "[GNUPG:] TRUST_ULTIMATE 0 pgp"
exit 0
"""

/// `run`'s `%GS`/`%GK` extraction (`fields[1]`/`fields[2]`), reached through
/// `run` itself rather than through `parse` alone. No real signing key is
/// involved: `craftedCommit` fabricates a `gpgsig` header directly (as the
/// other tests here do), and `installFakeGpg` — reused from
/// `CommitCreateGPGTests` rather than reimplemented — points `gpg.program`
/// at a script that reports success the way `git log` invokes it for
/// verification. Measured: `git -c gpg.program=./fakegpg.sh log -1
/// --format='%G?%x01%GS%x01%GK' <sha> --` prints
/// `G\u{01}Fixture <f@example.invalid>\u{01}DEADBEEFCAFE1234`.
@Test func goodSignatureReportsSignerAndKeyFromFakeGpg() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([FixtureRepository.Commit("a")])

    let sha = try craftedCommit(in: repo, block: fakePGPSignatureBlock)
    try installFakeGpg(verifyingGpgScript, in: repo)

    let result = try SignatureVerification.run(revision: sha, in: repo.url.path, extraEnvironment: hermetic)
    #expect(result.state == .good)
    #expect(result.format == .openpgp)
    #expect(result.signer == "Fixture <f@example.invalid>")
    #expect(result.key == "DEADBEEFCAFE1234")
}

@Test func missingGpgToolReportsCannotCheckWithOpenPGPFormat() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([FixtureRepository.Commit("a")])

    let sha = try craftedCommit(in: repo, block: fakePGPSignatureBlock)
    try GitProcess().run(
        ["config", "gpg.program", "/nonexistent-gpg-for-test"],
        workingDirectory: repo.url.path
    )

    let result = try SignatureVerification.run(revision: sha, in: repo.url.path, extraEnvironment: hermetic)
    if case .cannotCheck(let reason) = result.state {
        #expect(reason.contains("cannot exec"))
    } else {
        Issue.record("expected .cannotCheck, got \(result.state)")
    }
    #expect(result.format == .openpgp)
}

/// #0324: `log.showSignature=true` prepends a prose verification line ahead
/// of `--format`'s output even though `--format` is explicit, which used to
/// swallow `SignatureVerification.run`'s `\u{01}`-delimited fields and report
/// a validly signed commit as `.cannotCheck`. Uses a real SSH-signed commit —
/// `installFakeGpg` cannot produce a signature git calls *good* — per the
/// recipe measured in the issue notes (git 2.50.1). The key is a throwaway
/// keypair generated fresh into the fixture's own directory, registered
/// nowhere; its fingerprint differs every run, so nothing here asserts on it.
@Test func showSignatureConfigDoesNotBreakVerification() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([FixtureRepository.Commit("a")])

    let keyPath = repo.url.appendingPathComponent("k").path
    try GitProcess(executablePath: "/usr/bin/ssh-keygen").run(
        ["-q", "-t", "ed25519", "-N", "", "-C", "t@t", "-f", keyPath],
        standardInput: Data()
    )
    let publicKey = try String(contentsOf: URL(fileURLWithPath: "\(keyPath).pub"), encoding: .utf8)
    try repo.writeUntracked(["allowed": "t@t \(publicKey)"])
    for (key, value) in [
        "gpg.format": "ssh",
        "user.signingkey": "\(keyPath).pub",
        "gpg.ssh.allowedSignersFile": repo.url.appendingPathComponent("allowed").path,
    ] {
        try GitProcess().run(["config", key, value], workingDirectory: repo.url.path)
    }
    try GitProcess().run(
        ["commit", "-q", "-S", "--allow-empty", "-m", "signed subject"],
        workingDirectory: repo.url.path
    )
    let signedSha = try repo.revParse("HEAD")

    // Verify the config bites first: plain `git log --format=%G?` under it
    // must emit the prose line, not the raw flag. Anchored on the literal
    // git wording rather than on non-emptiness, so a config that silently
    // failed to apply (a vacuous probe) cannot pass this.
    let flagUnderConfig = try GitProcess().run(
        ["-c", "log.showSignature=true", "log", "-1", "--format=%G?", "HEAD"],
        workingDirectory: repo.url.path
    )
    let firstLine = flagUnderConfig.lines.first ?? ""
    #expect(firstLine.hasPrefix("Good \"git\" signature for t@t"))
    #expect(firstLine != "G")

    // The commit really is signed and verifiable with the config off --
    // establishes the baseline `run` must still report once the config is on.
    let withoutConfig = try SignatureVerification.run(
        revision: signedSha, in: repo.url.path, extraEnvironment: hermetic)
    #expect(withoutConfig.state == .good)

    // The fix: `run` passes `--no-show-signature`, so `log.showSignature`
    // (set here as repository-local config, which `hermetic` does not null)
    // must not change what `run` reports.
    try GitProcess().run(
        ["config", "log.showSignature", "true"], workingDirectory: repo.url.path)
    let underConfig = try SignatureVerification.run(
        revision: signedSha, in: repo.url.path, extraEnvironment: hermetic)
    #expect(underConfig.state == .good)
    #expect(underConfig.format == .ssh)
    #expect(underConfig.signer == "t@t")
}

@Test func unknownRevisionThrows() throws {
    let repo = try FixtureRepository()
    defer { repo.destroy() }

    #expect(throws: GitProcess.Failure.self) {
        _ = try SignatureVerification.run(revision: "deadbeef", in: repo.url.path, extraEnvironment: hermetic)
    }
}

@Test func flagMappingsMatchGitsDocumentedSet() {
    #expect(SignatureVerification.parse(flag: "G", signer: "", key: "", stderr: "", format: .none).state == .good)
    #expect(SignatureVerification.parse(flag: "U", signer: "", key: "", stderr: "", format: .none).state == .goodUntrusted)
    #expect(SignatureVerification.parse(flag: "B", signer: "", key: "", stderr: "", format: .none).state == .bad)
    #expect(SignatureVerification.parse(flag: "X", signer: "", key: "", stderr: "", format: .none).state == .expiredSignature)
    #expect(SignatureVerification.parse(flag: "Y", signer: "", key: "", stderr: "", format: .none).state == .expiredKey)
    #expect(SignatureVerification.parse(flag: "R", signer: "", key: "", stderr: "", format: .none).state == .revokedKey)
    if case SignatureVerification.State.cannotCheck = SignatureVerification.parse(flag: "E", signer: "", key: "", stderr: "", format: .none).state {
        // pass
    } else {
        Issue.record("E should map to .cannotCheck")
    }
    #expect(SignatureVerification.parse(flag: "N", signer: "", key: "", stderr: "", format: .none).state == .noSignature)
}

@Test func flagNWithStderrIsCannotCheckAndCarriesReason() {
    let result = SignatureVerification.parse(flag: "N", signer: "", key: "", stderr: "error: gpg.ssh.allowedSignersFile needs to be configured", format: .ssh)
    if case .cannotCheck(let reason) = result.state {
        #expect(reason == "error: gpg.ssh.allowedSignersFile needs to be configured")
    } else {
        Issue.record("expected .cannotCheck, got \(result.state)")
    }
}

@Test func unrecognizedFlagIsCannotCheck() {
    let result = SignatureVerification.parse(flag: "?", signer: "", key: "", stderr: "", format: .none)
    if case .cannotCheck(let reason) = result.state {
        #expect(reason.contains("unrecognized"))
    } else {
        Issue.record("expected .cannotCheck, got \(result.state)")
    }
}

@Test func emptySignerAndKeyBecomeNil() {
    let empty = SignatureVerification.parse(flag: "N", signer: "", key: "", stderr: "", format: .none)
    #expect(empty.signer == nil)
    #expect(empty.key == nil)

    let filled = SignatureVerification.parse(flag: "N", signer: "Fixture <fixture@example.invalid>", key: "SHA256:abc", stderr: "", format: .none)
    #expect(filled.signer == "Fixture <fixture@example.invalid>")
    #expect(filled.key == "SHA256:abc")
}

@Test func detectFormatRecognizesEachArmor() {
    let sshHeader = "tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nauthor x <x@x> 0 +0000\ncommitter y <y@y> 0 +0000\ngpgsig -----BEGIN SSH SIGNATURE-----\n U1NIU0lHTAAAAAWZha2VmYWtlZmFrZQ==\n -----END SSH SIGNATURE-----"
    #expect(SignatureVerification.detectFormat(rawCommit: sshHeader) == .ssh)

    let pgpHeader = "tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nauthor x <x@x> 0 +0000\ncommitter y <y@y> 0 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n iQFAKEFAKEFAKE=\n =fake\n -----END PGP SIGNATURE-----"
    #expect(SignatureVerification.detectFormat(rawCommit: pgpHeader) == .openpgp)

    // `git commit -S` always calls gpg with `-bsau` (detached, armored),
    // which only ever emits `BEGIN PGP SIGNATURE` -- not measured here to
    // emit `BEGIN PGP MESSAGE` from any real git invocation. This case is
    // defensive: git's own gpg-interface.c carries `BEGIN PGP MESSAGE`
    // alongside `BEGIN PGP SIGNATURE` in its `openpgp_sigs` recognition
    // array, so `detectFormat` matches what git itself is prepared to see
    // in a `gpgsig` header, even though its own signing path never produces
    // that form.
    let pgpMessageHeader = "tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nauthor x <x@x> 0 +0000\ncommitter y <y@y> 0 +0000\ngpgsig -----BEGIN PGP MESSAGE-----\n iQFAKEFAKEFAKE=\n =fake\n -----END PGP MESSAGE-----"
    #expect(SignatureVerification.detectFormat(rawCommit: pgpMessageHeader) == .openpgp)

    let x509Header = "tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nauthor x <x@x> 0 +0000\ncommitter y <y@y> 0 +0000\ngpgsig -----BEGIN SIGNED MESSAGE-----\n MIIGaw=="
    #expect(SignatureVerification.detectFormat(rawCommit: x509Header) == .x509)

    #expect(SignatureVerification.detectFormat(rawCommit: "tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nauthor x <x@x> 0 +0000\ncommitter y <y@y> 0 +0000\n\nmessage body") == .none)

    let unrecognizedHeader = "tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nauthor x <x@x> 0 +0000\ncommitter y <y@y> 0 +0000\ngpgsig -----BEGIN SOMETHING WEIRD-----\n dGVzdA==\n -----END SOMETHING WEIRD-----"
    #expect(SignatureVerification.detectFormat(rawCommit: unrecognizedHeader) == .unrecognized)
}

/// Pins the `gpgsig-sha256` clause at `SignatureVerification.swift:158` —
/// git's header name for a commit signature in a SHA-256 repository
/// (`--object-format=sha256`), measured to be written as `gpgsig-sha256
/// -----BEGIN PGP SIGNATURE-----` by git 2.50.1 during the M1 milestone
/// review that found this gap (#0306).
///
/// Route taken: a fabricated header through a raw string, the same shape as
/// `detectFormatRecognizesEachArmor` above, rather than building a real
/// `--object-format=sha256` fixture repository. This pins the *detection*
/// clause `detectFormat` is missing — the thing the mutation at line 158
/// removes — at the cost of a string literal. It does **not** exercise
/// `SignatureVerification.run` end to end against a real SHA-256 repository,
/// so it says nothing about `%G?`/`%GS`/`%GK` parsing, `git cat-file`, or any
/// other git behavior specific to that ref/object format; #0308 tracks
/// whether SHA-256 repositories are supported by the engine at all.
@Test func detectFormatRecognizesSha256Header() {
    let sha256PgpHeader = "tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nauthor x <x@x> 0 +0000\ncommitter y <y@y> 0 +0000\ngpgsig-sha256 -----BEGIN PGP SIGNATURE-----\n iQFAKEFAKEFAKE=\n =fake\n -----END PGP SIGNATURE-----"
    #expect(SignatureVerification.detectFormat(rawCommit: sha256PgpHeader) == .openpgp)
}

@Test func detectFormatIgnoresGpgsigTextInMessageBody() {
    let commit = """
    tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    author x <x@x> 0 +0000
    committer y <y@y> 0 +0000

    gpgsig -----BEGIN SSH SIGNATURE-----
     this is message text, not a header continuation, because it is after the blank line
    """
    // The body line must *begin* with `gpgsig ` for this test to have any force.
    // The original fixture read "This commit is mentioned to use `gpgsig …`",
    // which fails `hasPrefix("gpgsig ")` on its own — so it passed whether or
    // not detectFormat restricted itself to the header block, and could not
    // distinguish the two implementations it exists to distinguish.
    #expect(SignatureVerification.detectFormat(rawCommit: commit) == .none)
}
