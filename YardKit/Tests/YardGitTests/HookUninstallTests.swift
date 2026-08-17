// HookUninstallTests.swift — the uninstall/restore round trip

import Foundation
import Testing
@testable import YardGit

// MARK: - Helpers

private func hooksDirectory(_ repo: FixtureRepository) throws -> String {
    try WorktreeContext.resolve(path: repo.url.path).path(for: "hooks")
}

/// Writes a hook file directly — a test constructing repository state, the
/// same "the file is the state" exception the engine itself uses.
private func writeHook(
    _ name: String, in directory: String, content: String, mode: Int = 0o755
) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
    try Data(content.utf8).write(to: url)
    try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

private func install(_ repo: FixtureRepository) throws -> [HookInstall.Report] {
    try HookInstall.run(context: WorktreeContext.resolve(path: repo.url.path))
}

private func uninstall(_ repo: FixtureRepository) throws -> [HookUninstall.Report] {
    try HookUninstall.run(context: WorktreeContext.resolve(path: repo.url.path))
}

private func posixMode(_ path: String) throws -> UInt16 {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    let mode = try #require(attrs[.posixPermissions] as? NSNumber)
    return mode.uint16Value
}

// MARK: - The round trip

@Test func uninstallRestoresAChainedHookByteForByteAndModeForMode() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let dir = try hooksDirectory(repo)
    let theirs = "#!/bin/sh\n# their linter\nexit 0\n"
    // 0o700, not the 0o755 install writes — so a restore that rewrites
    // instead of renaming shows up in the mode.
    try writeHook("reference-transaction", in: dir, content: theirs, mode: 0o700)

    let installed = try install(repo)
    #expect(installed.map(\.outcome) == [.chained, .installed])

    let reports = try uninstall(repo)
    #expect(reports.map(\.outcome) == [.restored, .removed])

    let hookPath = dir + "/reference-transaction"
    let restored = try Data(contentsOf: URL(fileURLWithPath: hookPath))
    #expect(restored == Data(theirs.utf8), "the previous hook must come back byte-for-byte")
    #expect(try posixMode(hookPath) == 0o700, "and mode-for-mode")
    #expect(!FileManager.default.fileExists(
        atPath: hookPath + HookInstall.chainedSuffix), "the backup name is vacated")
}

@Test func uninstallRemovesACleanInstallEntirely() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    _ = try install(repo)

    let reports = try uninstall(repo)
    #expect(reports.map(\.outcome) == [.removed, .removed])

    let dir = try hooksDirectory(repo)
    for hook in ObservedHook.allCases {
        #expect(!FileManager.default.fileExists(atPath: dir + "/" + hook.rawValue))
    }
}

// MARK: - States that are not a clean round trip

@Test func uninstallOnANeverInstalledRepositoryReportsNotInstalled() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let reports = try uninstall(repo)
    #expect(reports.map(\.outcome) == [.notInstalled, .notInstalled])
}

@Test func uninstallLeavesAForeignHookInPlace() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let dir = try hooksDirectory(repo)
    let theirs = "#!/bin/sh\n# not ours\n"
    try writeHook("reference-transaction", in: dir, content: theirs)

    let reports = try uninstall(repo)
    #expect(reports.map(\.outcome) ==
            [.foreignLeftInPlace(backupRetained: false), .notInstalled])

    let content = try Data(contentsOf: URL(
        fileURLWithPath: dir + "/reference-transaction"))
    #expect(content == Data(theirs.utf8))
}

@Test func uninstallRestoresWhenTheWrapperWasDeletedByHand() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let dir = try hooksDirectory(repo)
    let theirs = "#!/bin/sh\n# their hook\n"
    try writeHook("reference-transaction", in: dir, content: theirs)
    _ = try install(repo)
    try FileManager.default.removeItem(atPath: dir + "/reference-transaction")

    let reports = try uninstall(repo)
    #expect(reports.first?.outcome == .restored)
    let content = try Data(contentsOf: URL(
        fileURLWithPath: dir + "/reference-transaction"))
    #expect(content == Data(theirs.utf8))
}

@Test func aForeignReplacementOfTheWrapperRetainsTheBackup() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let dir = try hooksDirectory(repo)
    try writeHook("reference-transaction", in: dir, content: "#!/bin/sh\n# original\n")
    _ = try install(repo)
    // Someone replaced our wrapper with a hook of their own; the backup of
    // the original must not clobber it.
    let replacement = "#!/bin/sh\n# replacement\n"
    try writeHook("reference-transaction", in: dir, content: replacement)

    let reports = try uninstall(repo)
    #expect(reports.first?.outcome == .foreignLeftInPlace(backupRetained: true))

    let fm = FileManager.default
    let content = try Data(contentsOf: URL(
        fileURLWithPath: dir + "/reference-transaction"))
    #expect(content == Data(replacement.utf8))
    #expect(fm.fileExists(
        atPath: dir + "/reference-transaction" + HookInstall.chainedSuffix))
}

// MARK: - core.hooksPath

@Test func managedHooksPathRefusesSymmetricallyWithInstall() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let managed = repo.url.appendingPathComponent("managed-hooks").path
    try FileManager.default.createDirectory(
        atPath: managed, withIntermediateDirectories: true)
    try GitProcess().run(["config", "core.hooksPath", managed],
                         workingDirectory: repo.url.path)

    let context = try WorktreeContext.resolve(path: repo.url.path)
    #expect(throws: HookInstall.Failure.hooksPathManaged(path: managed)) {
        try HookUninstall.run(context: context)
    }
}

// MARK: - Wire encoding

@Test func reportEncodesStableCodesAndDetail() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    let restored = HookUninstall.Report(hook: .referenceTransaction, outcome: .restored)
    #expect(String(decoding: try encoder.encode(restored), as: UTF8.self)
            == #"{"hook":"reference-transaction","outcome":{"code":"restored"}}"#)

    let foreign = HookUninstall.Report(
        hook: .postRewrite, outcome: .foreignLeftInPlace(backupRetained: true))
    #expect(String(decoding: try encoder.encode(foreign), as: UTF8.self)
            == #"{"hook":"post-rewrite","outcome":{"backupRetained":true,"code":"foreignLeftInPlace"}}"#)
}

// MARK: - Atomicity of restore (2026-08-17 planning correction)

/// A non-executable hook must come back non-executable: `replaceItemAt` uses the
/// REPLACEMENT's metadata only when told to, and the restored file is the
/// replacement. Without `.usingNewMetadataOnly` it inherits the wrapper's 0755
/// and git starts running a hook the user had deliberately disabled.
@Test func uninstallRestoresANonExecutableHookAsNonExecutable() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    let hooks = try hooksDirectory(repo)
    let body = "#!/bin/sh\necho theirs\n"
    try writeHook("reference-transaction", in: hooks, content: body, mode: 0o644)
    _ = try install(repo)

    _ = try HookUninstall.run(context: WorktreeContext.resolve(path: repo.url.path))

    let hook = hooks + "/reference-transaction"
    #expect(try String(contentsOfFile: hook, encoding: .utf8) == body)
    let mode = try #require(
        FileManager.default.attributesOfItem(atPath: hook)[.posixPermissions] as? NSNumber)
    #expect(mode.intValue & 0o111 == 0, "a disabled hook must not come back enabled")
}
