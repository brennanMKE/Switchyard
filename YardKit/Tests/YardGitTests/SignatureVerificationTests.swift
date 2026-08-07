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

    let x509Header = "tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nauthor x <x@x> 0 +0000\ncommitter y <y@y> 0 +0000\ngpgsig -----BEGIN SIGNED MESSAGE-----\n MIIGaw=="
    #expect(SignatureVerification.detectFormat(rawCommit: x509Header) == .x509)

    #expect(SignatureVerification.detectFormat(rawCommit: "tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nauthor x <x@x> 0 +0000\ncommitter y <y@y> 0 +0000\n\nmessage body") == .none)

    let unrecognizedHeader = "tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nauthor x <x@x> 0 +0000\ncommitter y <y@y> 0 +0000\ngpgsig -----BEGIN SOMETHING WEIRD-----\n dGVzdA==\n -----END SOMETHING WEIRD-----"
    #expect(SignatureVerification.detectFormat(rawCommit: unrecognizedHeader) == .unrecognized)
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
