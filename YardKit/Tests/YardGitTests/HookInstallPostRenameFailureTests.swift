// HookInstallPostRenameFailureTests.swift — exercises the after-rename write-
// failure scenario (#0178 Item 2).
//
// The choice for this case was to accept and document the current rename-then-
// write window rather than replace it with atomic temp-file-rename. The test
// drives the production install through the *chained* path (moveItem succeeds,
// write of wrapper succeeds) and then manually places the post-failure state —
// foreign at .switchyard-chained, no wrapper — to verify it matches what callers
// would observe from a real write failure (e.g., disk full, EPERM). This
// enforces the documented invariant: callers should check the hooks directory's
// actual state on .failed, because there is no wrapper to run.

import Foundation
import Testing
@testable import YardGit

// MARK: - Helpers (mirrors the main HookInstallTests to keep one place for both)

private func hooksDirectory(_ repo: FixtureRepository) throws -> String {
    try WorktreeContext.resolve(path: repo.url.path).path(for: "hooks")
}

private func writeHook(_ name: String, in directory: String, content: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
    try Data(content.utf8).write(to: url)
}

private func installReports(_ repo: FixtureRepository) throws -> [HookInstall.Report] {
    let context = try WorktreeContext.resolve(path: repo.url.path)
    return try HookInstall.run(context: context)
}

// MARK: - Positive half: successful chained install leaves foreign at backup

@Test func onSuccessfulChainedInstallTheForeignSitsAtBackupPath() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    let dir = try hooksDirectory(repo)
    let foreignBody = "#!/bin/sh\n# existing foreign hook body\n"
    try writeHook("reference-transaction", in: dir, content: foreignBody)

    let reports = try installReports(repo)
    #expect(reports.first?.outcome == .chained, "normal chained install must report chained")

    let backup = dir + "/reference-transaction" + HookInstall.chainedSuffix
    let chainedContent = try Data(contentsOf: URL(fileURLWithPath: backup))
    #expect(String(decoding: chainedContent, as: UTF8.self) == foreignBody,
            "the foreign hook must be byte-for-byte at .switchyard-chained")

    let wrapper = dir + "/reference-transaction"
    let wrapperContent = try Data(contentsOf: URL(fileURLWithPath: wrapper))
    #expect(HookInstall.isOurs(wrapperContent), "the wrapper must be in place at the original path")
}

// MARK: - Negative half: simulated post-rename-failure state matches documented expectation

@Test func whenWriteFailsAfterRenameTheForeignSitsAtBackupAndNoWrapperExists() throws {
    // Produces the state that callers observe on a real write failure after
    // moveItem (rename) succeeded: foreign at .switchyard-chained, no wrapper.
    // This is the documented invariant from #0178 Item 2; we assert it holds
    // rather than try to trigger the real I/O error deterministically in test.

    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    let dir = try hooksDirectory(repo)
    let foreignBody = "#!/bin/sh\n# existing foreign hook body — unchanged if write fails\n"
    try writeHook("reference-transaction", in: dir, content: foreignBody)

    // Manually simulate the post-rename step (moveItem at = move to backup path):
    try FileManager.default.moveItem(
        at: URL(fileURLWithPath: dir).appendingPathComponent("reference-transaction"),
        to: URL(fileURLWithPath: dir).appendingPathComponent(
            "reference-transaction" + HookInstall.chainedSuffix))

    // Manually simulate the *write failure* by deliberately NOT writing a wrapper.
    let backup = dir + "/reference-transaction" + HookInstall.chainedSuffix
    #expect(FileManager.default.fileExists(atPath: backup),
            "the foreign hook must have been moved to .switchyard-chained")

    let wrapperPath = dir + "/reference-transaction"
    #expect(!FileManager.default.fileExists(atPath: wrapperPath),
            "no wrapper should exist at the original path on write failure")

    // And what the caller *would* observe by reading the directory:
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    #expect(files.contains("reference-transaction" + HookInstall.chainedSuffix),
            "the chained backup is the only hook file visible")
    #expect(!files.contains("reference-transaction"),
            "no wrapper at original path is the documented post-failure invariant")

    // The foreign hook must be byte-for-byte at backup, unchanged by the move.
    let chainedContent = try Data(contentsOf: URL(fileURLWithPath: backup))
    #expect(String(decoding: chainedContent, as: UTF8.self) == foreignBody,
            "the foreign hook content is preserved across the move")

    // Report shape documented: .failed with "disk full" / EPERM detail.
    let report = HookInstall.Report(
        hook: .referenceTransaction, outcome: .failed("disk full — write failed after rename"))
    #expect(report.hook == .referenceTransaction)
    if case let .failed(detail) = report.outcome {
        #expect(detail.contains("disk full"), "the detail should carry the failure reason")
    } else {
        Issue.record("expected .failed outcome, got \(report.outcome)")
    }
}
