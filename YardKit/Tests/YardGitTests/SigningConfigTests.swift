// SigningConfigTests.swift

import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

private func set(_ key: String, _ value: String, in repo: FixtureRepository) throws {
    try GitProcess().run(["config", key, value], workingDirectory: repo.url.path)
}

private func unset(_ key: String, in repo: FixtureRepository) throws {
    try GitProcess().run(["config", "--unset", key], workingDirectory: repo.url.path)
}

@Test func explicitFalseIsFalseNotNil() throws {
    let fixture = FixtureRepository.RefFormat.supported().first!
    var repo = try FixtureRepository(refFormat: fixture)
    defer { repo.destroy() }

    let config = try SigningConfig.read(in: repo.url.path, extraEnvironment: hermetic)
    #expect(config.commitSigningEnabled == false)
    #expect(config.willSign == false)
}

@Test func unsetKeysReportNil() throws {
    let fixture = FixtureRepository.RefFormat.supported().first!
    var repo = try FixtureRepository(refFormat: fixture)
    defer { repo.destroy() }

    // Required — fixture init sets commit.gpgsign=false, so we must unset it
    // to test the truly-unset state.
    try unset("commit.gpgsign", in: repo)

    let config = try SigningConfig.read(in: repo.url.path, extraEnvironment: hermetic)
    #expect(config.commitSigningEnabled == nil)
    #expect(config.format == nil)
    #expect(config.signingKey == nil)
    #expect(config.allowedSignersFile == nil)
    #expect(config.willSign == false)
    #expect(config.canVerifySSHSignatures == false)
}

@Test func sshSigningWithoutAllowedSignersWillSignButCannotVerify() throws {
    let fixture = FixtureRepository.RefFormat.supported().first!
    var repo = try FixtureRepository(refFormat: fixture)
    defer { repo.destroy() }

    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "ssh", in: repo)
    try set("user.signingKey", "~/.ssh/id_ed25519.pub", in: repo)

    let config = try SigningConfig.read(in: repo.url.path, extraEnvironment: hermetic)
    #expect(config.commitSigningEnabled == true)
    #expect(config.format == .ssh)
    #expect(config.signingKey == "~/.ssh/id_ed25519.pub")
    #expect(config.willSign == true)
    #expect(config.canVerifySSHSignatures == false)
}

@Test func allowedSignersFileTurnsVerificationOn() throws {
    let fixture = FixtureRepository.RefFormat.supported().first!
    var repo = try FixtureRepository(refFormat: fixture)
    defer { repo.destroy() }

    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "ssh", in: repo)
    try set("user.signingKey", "~/.ssh/id_ed25519.pub", in: repo)
    try set("gpg.ssh.allowedSignersFile", "/path/to/allowed-signers", in: repo)

    let config = try SigningConfig.read(in: repo.url.path, extraEnvironment: hermetic)
    #expect(config.allowedSignersFile == "/path/to/allowed-signers")
    #expect(config.canVerifySSHSignatures == true)
}

@Test func booleanAliasesAndFormatsNormalize() throws {
    let fixture = FixtureRepository.RefFormat.supported().first!
    var repo = try FixtureRepository(refFormat: fixture)
    defer { repo.destroy() }

    try set("commit.gpgsign", "yes", in: repo)
    try set("gpg.format", "openpgp", in: repo)

    let config = try SigningConfig.read(in: repo.url.path, extraEnvironment: hermetic)
    #expect(config.commitSigningEnabled == true)
    #expect(config.format == .openpgp)
}

@Test func malformedBooleanThrows() throws {
    let fixture = FixtureRepository.RefFormat.supported().first!
    var repo = try FixtureRepository(refFormat: fixture)
    defer { repo.destroy() }

    try set("commit.gpgsign", "banana", in: repo)
    #expect(throws: (any Error).self) {
        _ = try SigningConfig.read(in: repo.url.path, extraEnvironment: hermetic)
    }
}

@Test func localScopeOverridesGlobal() throws {
    let fixture = FixtureRepository.RefFormat.supported().first!
    var repo = try FixtureRepository(refFormat: fixture)
    defer { repo.destroy() }

    let globalConfig = repo.url.appendingPathComponent("fake-global-config")
    try "[commit]\n\tgpgsign = true\n".write(to: globalConfig, atomically: true, encoding: .utf8)

    let hermeticWithGlobal = [
        "GIT_CONFIG_GLOBAL": globalConfig.path,
        "GIT_CONFIG_SYSTEM": "/dev/null",
    ]

    // Local false (from init) wins over global true.
    let config1 = try SigningConfig.read(in: repo.url.path, extraEnvironment: hermeticWithGlobal)
    #expect(config1.commitSigningEnabled == false)

    // Unset local -> global true shows through.
    try unset("commit.gpgsign", in: repo)
    let config2 = try SigningConfig.read(in: repo.url.path, extraEnvironment: hermeticWithGlobal)
    #expect(config2.commitSigningEnabled == true)
}

@Test(arguments: FixtureRepository.RefFormat.supported()) func reportsInBothRefFormats(_ format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }

    try set("commit.gpgsign", "true", in: repo)
    let config = try SigningConfig.read(in: repo.url.path, extraEnvironment: hermetic)
    #expect(config.commitSigningEnabled == true)
    #expect(config.willSign == true)
}
