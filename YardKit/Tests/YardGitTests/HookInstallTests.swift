// HookInstallTests.swift — install with chaining, idempotence, and the
// core.hooksPath refusal (#0041)

import Foundation
import Testing
@testable import YardGit

// MARK: - Helpers

/// Resolves the repo's effective hooks directory the way the engine does.
private func hooksDirectory(_ repo: FixtureRepository) throws -> String {
    try WorktreeContext.resolve(path: repo.url.path).path(for: "hooks")
}

/// Writes a hook file directly — a test constructing repository state, the
/// same "the file is the state" exception the engine itself uses.
private func writeHook(
    _ name: String, in directory: String, content: String, mode: Int = 0o755
) throws {
    let fm = FileManager.default
    try fm.createDirectory(
        atPath: directory, withIntermediateDirectories: true)
    let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
    try Data(content.utf8).write(to: url)
    try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

/// A pre-existing hook that logs its state argument and its stdin, exit 0.
private func loggerHook(to log: String) -> String {
    """
    #!/bin/sh
    { echo "state=$1"; sed 's/^/line: /'; } >> "\(log)"

    """
}

/// Fires a ref transaction in the repo with a PATH that cannot contain a
/// real `switchyard` binary — once M3 installs one into /usr/local/bin,
/// the wrapper would otherwise invoke it from inside the hook.
private func updateRef(
    _ name: String, in repo: FixtureRepository
) throws -> GitProcess.Output {
    try GitProcess().capture(
        ["update-ref", name, "HEAD"],
        workingDirectory: repo.url.path,
        extraEnvironment: ["PATH": "/usr/bin:/bin"])
}

private func installReports(
    _ repo: FixtureRepository
) throws -> [HookInstall.Report] {
    let context = try WorktreeContext.resolve(path: repo.url.path)
    return try HookInstall.run(context: context)
}

private func posixMode(_ path: String) throws -> UInt16 {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    let mode = try #require(attrs[.posixPermissions] as? NSNumber)
    return mode.uint16Value
}

// MARK: - Clean install

@Test func installIntoACleanRepositoryWritesBothHooksExecutable() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    let reports = try installReports(repo)
    #expect(reports.map(\.hook) == [.referenceTransaction, .postRewrite])
    #expect(reports.map(\.outcome) == [.installed, .installed])

    let dir = try hooksDirectory(repo)
    for hook in ObservedHook.allCases {
        let path = dir + "/" + hook.rawValue
        let content = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(content == Data(HookInstall.script(for: hook).utf8))
        let mode = try posixMode(path)
        #expect(mode & 0o111 != 0, "\(hook.rawValue) must be executable — git ignores a non-executable hook")
    }
}

// MARK: - Chaining

@Test(arguments: FixtureRepository.RefFormat.supported())
func aChainedHookStillRunsWithTheSameStdin(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("a")])
    let log = repo.url.appendingPathComponent("theirs.log").path
    try writeHook("reference-transaction", in: try hooksDirectory(repo),
                  content: loggerHook(to: log))

    let reports = try installReports(repo)
    #expect(reports.first?.outcome == .chained)

    let result = try updateRef("refs/heads/probe", in: repo)
    #expect(result.exitCode == 0)

    let logged = try String(contentsOfFile: log, encoding: .utf8)
    #expect(logged.contains("state=prepared"))
    #expect(logged.contains("state=committed"))
    #expect(logged.contains("refs/heads/probe"),
            "the chained hook must receive the transaction's stdin")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func aChainedHookFailureStillAbortsTheTransaction(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("a")])
    try writeHook("reference-transaction", in: try hooksDirectory(repo),
                  content: "#!/bin/sh\nexit 1\n")

    _ = try installReports(repo)

    let result = try updateRef("refs/heads/must-not-exist", in: repo)
    #expect(result.exitCode != 0,
            "the chained hook exits 1 in the prepared state, so the transaction must abort")

    let lookup = try GitProcess().capture(
        ["rev-parse", "--verify", "--quiet", "refs/heads/must-not-exist"],
        workingDirectory: repo.url.path)
    #expect(lookup.exitCode != 0, "the ref must not have been created")
}

// MARK: - Idempotence

@Test func installingTwiceIsIdempotentAndNeverChainsToItself() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let theirs = "#!/bin/sh\nexit 0\n"
    let dir = try hooksDirectory(repo)
    try writeHook("reference-transaction", in: dir, content: theirs)

    let first = try installReports(repo)
    #expect(first.map(\.outcome) == [.chained, .installed])

    let second = try installReports(repo)
    #expect(second.map(\.outcome) == [.alreadyInstalled, .alreadyInstalled])

    // The backup still holds the foreign hook, not a copy of the wrapper.
    let backup = dir + "/reference-transaction" + HookInstall.chainedSuffix
    let backupContent = try Data(contentsOf: URL(fileURLWithPath: backup))
    #expect(backupContent == Data(theirs.utf8),
            "a reinstall must never chain the wrapper to itself")
}

@Test func aForeignHookWithAnExistingBackupIsBlocked() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let dir = try hooksDirectory(repo)
    try writeHook("reference-transaction", in: dir, content: "#!/bin/sh\n# somebody else\n")
    try writeHook("reference-transaction" + HookInstall.chainedSuffix, in: dir,
                  content: "#!/bin/sh\n# older backup\n")

    let reports = try installReports(repo)
    #expect(reports.first?.outcome == .blockedByExistingBackup)

    let hook = try Data(contentsOf: URL(fileURLWithPath: dir + "/reference-transaction"))
    #expect(String(decoding: hook, as: UTF8.self).contains("somebody else"),
            "a blocked install must not touch the existing hook")
}

// MARK: - core.hooksPath

@Test func managedHooksPathRefusesBeforeWritingAnything() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    // Resolved before the override goes in, so the assertion below can name
    // the default directory without assembling a `.git/` path by hand.
    let defaultDir = try hooksDirectory(repo)
    let managed = repo.url.appendingPathComponent("managed-hooks").path
    try FileManager.default.createDirectory(
        atPath: managed, withIntermediateDirectories: true)
    try GitProcess().run(["config", "core.hooksPath", managed],
                         workingDirectory: repo.url.path)

    let context = try WorktreeContext.resolve(path: repo.url.path)
    #expect(throws: HookInstall.Failure.hooksPathManaged(path: managed)) {
        try HookInstall.run(context: context)
    }

    // Nothing written to the managed directory, and nothing to the (inert)
    // default directory either.
    let fm = FileManager.default
    #expect(!fm.fileExists(atPath: managed + "/reference-transaction"))
    #expect(!fm.fileExists(atPath: defaultDir + "/reference-transaction"))
}

// MARK: - Worktrees

@Test func installFromALinkedWorktreeLandsInTheSharedHooksDirectory() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let wt = try repo.addWorktree(named: "agent", branch: "agent")

    let wtContext = try WorktreeContext.resolve(path: wt.path)
    let reports = try HookInstall.run(context: wtContext)
    #expect(reports.map(\.outcome) == [.installed, .installed])

    // The hooks directory resolves identically from both worktrees — hooks
    // are shared state under $GIT_COMMON_DIR — so one install covers all.
    let mainDir = try hooksDirectory(repo)
    let wtDir = try wtContext.path(for: "hooks")
    #expect(mainDir == wtDir)

    let content = try Data(contentsOf: URL(
        fileURLWithPath: mainDir + "/reference-transaction"))
    #expect(HookInstall.isOurs(content))
}

// MARK: - Wire encoding

@Test func reportEncodesStableCodesAndHookStrings() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    let chained = HookInstall.Report(hook: .referenceTransaction, outcome: .chained)
    let chainedJSON = String(decoding: try encoder.encode(chained), as: UTF8.self)
    #expect(chainedJSON == #"{"hook":"reference-transaction","outcome":{"code":"chained"}}"#)

    let failed = HookInstall.Report(hook: .postRewrite, outcome: .failed("disk full"))
    let failedJSON = String(decoding: try encoder.encode(failed), as: UTF8.self)
    #expect(failedJSON == #"{"hook":"post-rewrite","outcome":{"code":"failed","detail":"disk full"}}"#)
}
