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

// MARK: - Non-executable foreign hook

/// Git does not run a non-executable hook, so the wrapper's `[ -x "$chained" ]`
/// tests must not either (#0041 Given 7 asserted this and nothing covered it).
///
/// The negative half — "it did not run" — passes for free if the hook was
/// never going to run anyway, so the positive half is asserted in the same
/// fixture: the bytes and the non-executable mode both survive the rename.
/// The mutation for this is a FIXTURE mutation; see the table.
@Test func aNonExecutableForeignHookIsPreservedButNeverRun() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    let log = repo.url.appendingPathComponent("theirs.log").path
    let hooks = try hooksDirectory(repo)
    let body = loggerHook(to: log)
    try writeHook("reference-transaction", in: hooks, content: body, mode: 0o644)

    let reports = try installReports(repo)
    #expect(reports.first?.outcome == .chained)

    // Positive half: the foreign hook survived the rename, byte-for-byte and
    // mode-for-mode.
    let chained = hooks + "/reference-transaction" + HookInstall.chainedSuffix
    #expect(try String(contentsOfFile: chained, encoding: .utf8) == body)
    let mode = try #require(
        FileManager.default.attributesOfItem(atPath: chained)[.posixPermissions] as? NSNumber)
    #expect(mode.intValue & 0o111 == 0, "the non-executable bit must survive")

    // Negative half: a ref transaction runs the wrapper, and the chained hook
    // must stay silent because git would not have run it either.
    let result = try updateRef("refs/heads/probe", in: repo)
    #expect(result.exitCode == 0)
    #expect(!FileManager.default.fileExists(atPath: log),
            "a non-executable chained hook must not be executed")
}

// MARK: - Atomic replace (#0178 item 2)

/// The wrapper must be executable even when the hook it replaces was not.
/// `replaceItemAt` carries the original's metadata unless told otherwise, so
/// without `.usingNewMetadataOnly` chaining over a 0644 hook installs a 0644
/// wrapper and git silently ignores it. Measured: 644 without the option, 755
/// with it — and the entire hook suite passes either way, which is why this
/// assertion exists.
@Test func chainingOverANonExecutableHookInstallsAnExecutableWrapper() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    let hooks = try hooksDirectory(repo)
    try writeHook("reference-transaction", in: hooks,
                  content: loggerHook(to: repo.url.appendingPathComponent("t.log").path),
                  mode: 0o644)

    #expect(try installReports(repo).first?.outcome == .chained)

    let wrapper = hooks + "/reference-transaction"
    let mode = try #require(
        FileManager.default.attributesOfItem(atPath: wrapper)[.posixPermissions] as? NSNumber)
    #expect(mode.intValue & 0o111 != 0, "git ignores a non-executable hook")
    let chained = try #require(
        FileManager.default.attributesOfItem(atPath: wrapper + HookInstall.chainedSuffix)[.posixPermissions] as? NSNumber)
    #expect(chained.intValue & 0o111 == 0, "the foreign hook keeps its own mode")
}

/// #0178 item 2: a failure AFTER the foreign hook has been copied aside must
/// leave the user's hook in place and running. The old ordering (move, then
/// write) left the hook path empty, so a failed write silently disabled it.
///
/// The failure is injected by marking the hook immutable, which lets the copy
/// and the staging write succeed and fails only the final replace — i.e. it
/// fails exactly inside the window this issue is about.
@Test func aFailureAfterTheBackupCopyLeavesTheForeignHookRunning() throws {
    let fm = FileManager.default
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    let hooks = try hooksDirectory(repo)
    let hook = hooks + "/reference-transaction"
    let body = loggerHook(to: repo.url.appendingPathComponent("theirs.log").path)
    try writeHook("reference-transaction", in: hooks, content: body, mode: 0o755)

    try fm.setAttributes([.immutable: true], ofItemAtPath: hook)
    defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: hook) }

    let report = try #require(try installReports(repo).first)
    guard case .failed = report.outcome else {
        Issue.record("expected .failed, got \(report.outcome)")
        return
    }

    // The invariant: the user's hook is still there, still theirs, still
    // executable. Never an empty path, never a partial file.
    #expect(try String(contentsOfFile: hook, encoding: .utf8) == body)
    let mode = try #require(fm.attributesOfItem(atPath: hook)[.posixPermissions] as? NSNumber)
    #expect(mode.intValue & 0o111 != 0)
    #expect(!fm.fileExists(atPath: hook + ".switchyard-installing"),
            "a failed install leaves no staging file")
}
