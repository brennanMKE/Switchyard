// HookStatusTests.swift — status reports what is actually installed

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

private func status(_ repo: FixtureRepository) throws -> HookStatus.Summary {
    try HookStatus.run(context: WorktreeContext.resolve(path: repo.url.path))
}

// MARK: - States

@Test func aCleanRepositoryReportsBothHooksAbsent() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let summary = try status(repo)
    #expect(summary.directory == (try hooksDirectory(repo)))
    #expect(summary.managedPath == nil)
    #expect(summary.entries == [
        .init(hook: .referenceTransaction, state: .absent, executable: false, chainedPresent: false),
        .init(hook: .postRewrite, state: .absent, executable: false, chainedPresent: false),
    ])
}

@Test func afterInstallBothHooksReportInstalled() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    try HookInstall.run(context: WorktreeContext.resolve(path: repo.url.path))
    let summary = try status(repo)
    #expect(summary.entries == [
        .init(hook: .referenceTransaction, state: .installed, executable: true, chainedPresent: false),
        .init(hook: .postRewrite, state: .installed, executable: true, chainedPresent: false),
    ])
}

@Test func aHandEditedWrapperReportsStale() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let dir = try hooksDirectory(repo)
    try HookInstall.run(context: WorktreeContext.resolve(path: repo.url.path))
    // Still ours by marker, no longer the current script.
    let edited = HookInstall.script(for: .referenceTransaction) + "# local edit\n"
    try writeHook("reference-transaction", in: dir, content: edited)

    let summary = try status(repo)
    #expect(summary.entries.first?.state == .stale)
    #expect(summary.entries.last?.state == .installed)
}

@Test func foreignHooksReportForeignWithTheirExecutableBit() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let dir = try hooksDirectory(repo)
    try writeHook("reference-transaction", in: dir, content: "#!/bin/sh\nexit 0\n")
    // Present but not executable: git ignores it, and status must say so.
    try writeHook("post-rewrite", in: dir, content: "#!/bin/sh\nexit 0\n", mode: 0o644)

    let summary = try status(repo)
    #expect(summary.entries == [
        .init(hook: .referenceTransaction, state: .foreign, executable: true, chainedPresent: false),
        .init(hook: .postRewrite, state: .foreign, executable: false, chainedPresent: false),
    ])
}

@Test func aChainedBackupIsReported() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let dir = try hooksDirectory(repo)
    try writeHook("reference-transaction", in: dir, content: "#!/bin/sh\nexit 0\n")
    try HookInstall.run(context: WorktreeContext.resolve(path: repo.url.path))

    let summary = try status(repo)
    #expect(summary.entries.first ==
            .init(hook: .referenceTransaction, state: .installed,
                  executable: true, chainedPresent: true))
}

// MARK: - core.hooksPath

@Test func managedHooksPathIsReportedAndItsDirectoryInspected() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let managed = repo.url.appendingPathComponent("managed-hooks").path
    try writeHook("reference-transaction", in: managed, content: "#!/bin/sh\nexit 0\n")
    try GitProcess().run(["config", "core.hooksPath", managed],
                         workingDirectory: repo.url.path)

    let summary = try status(repo)
    #expect(summary.managedPath == managed)
    // `git rev-parse --git-path hooks` returns the override, so the entries
    // describe what actually fires, not the inert $GIT_DIR/hooks.
    #expect(summary.directory == managed)
    #expect(summary.entries == [
        .init(hook: .referenceTransaction, state: .foreign, executable: true, chainedPresent: false),
        .init(hook: .postRewrite, state: .absent, executable: false, chainedPresent: false),
    ])
}

// MARK: - Wire encoding

@Test func summaryEncodesStableKeys() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let summary = HookStatus.Summary(
        directory: "/repo/.git/hooks",
        managedPath: nil,
        entries: [.init(hook: .referenceTransaction, state: .stale,
                        executable: true, chainedPresent: true)])
    let json = String(decoding: try encoder.encode(summary), as: UTF8.self)
    #expect(json == #"{"directory":"\/repo\/.git\/hooks","entries":[{"chainedPresent":true,"executable":true,"hook":"reference-transaction","state":"stale"}]}"#)
}
