// WorktreeSparseTests.swift — sparse worktree creation, cone mode (#0128)

import Foundation
import Testing
@testable import YardGit

// MARK: - Fixture

/// One commit with three directories and a root file — the shape every
/// sparse assertion below runs against.
private func threeDirRepo(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: [
        "app/a.txt": "a\n",
        "docs/d.txt": "d\n",
        "tools/t.txt": "t\n",
        "root.txt": "r\n",
    ])])
    return repo
}

private func sibling(_ repo: FixtureRepository, _ suffix: String) -> String {
    repo.url.deletingLastPathComponent()
        .appendingPathComponent("\(repo.url.lastPathComponent)-\(suffix)").path
}

// MARK: - Tests

@Test(arguments: FixtureRepository.RefFormat.supported())
func sparseWorktreeContainsTheConeAndOnlyTheCone(format: FixtureRepository.RefFormat) throws {
    let repo = try threeDirRepo(format)
    defer { repo.destroy() }
    let path = sibling(repo, "sparse")

    let result = try worktreeAddSparse(
        at: repo.url.path, path: path,
        target: .newBranch(name: "sparsework"),
        directories: ["app", "tools"])
    #expect(result.success)
    #expect(result.sparseError == nil)

    let fm = FileManager.default
    // Both requested directories, and root files (cone semantics).
    #expect(fm.fileExists(atPath: path + "/app/a.txt"))
    #expect(fm.fileExists(atPath: path + "/tools/t.txt"))
    #expect(fm.fileExists(atPath: path + "/root.txt"))
    // The unrequested directory is absent.
    #expect(!fm.fileExists(atPath: path + "/docs"))
    // And its content is fully tracked, clean, and listable.
    let git = GitProcess()
    let status = try git.run(["status", "--porcelain=v2"], workingDirectory: path)
    #expect(status.lines.isEmpty)
    let listed = try git.run(["sparse-checkout", "list"], workingDirectory: path)
    #expect(listed.lines == ["app", "tools"])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func sparseConfigurationIsScopedToTheNewWorktree(format: FixtureRepository.RefFormat) throws {
    let repo = try threeDirRepo(format)
    defer { repo.destroy() }
    let path = sibling(repo, "scoped")

    let result = try worktreeAddSparse(
        at: repo.url.path, path: path,
        target: .newBranch(name: "scopedwork"),
        directories: ["docs"])
    #expect(result.success)

    let fm = FileManager.default
    // The MAIN worktree keeps its full tree — one agent's sparse cone must
    // never reshape a sibling.
    #expect(fm.fileExists(atPath: repo.url.appendingPathComponent("app/a.txt").path))
    #expect(fm.fileExists(atPath: repo.url.appendingPathComponent("docs/d.txt").path))
    #expect(fm.fileExists(atPath: repo.url.appendingPathComponent("tools/t.txt").path))

    let git = GitProcess()
    // Measured: `sparse-checkout list` in a non-sparse worktree exits 128
    // with `fatal: this worktree is not sparse`.
    let mainList = try git.capture(["sparse-checkout", "list"],
                                   workingDirectory: repo.url.path)
    #expect(mainList.exitCode == 128)
    // git scoped the sparse config per-worktree by enabling
    // extensions.worktreeConfig itself.
    let extensionOn = try git.run(["config", "extensions.worktreeConfig"],
                                  workingDirectory: path)
    #expect(extensionOn.lines == ["true"])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func patternArgumentIsRefusedStructurally(format: FixtureRepository.RefFormat) throws {
    let repo = try threeDirRepo(format)
    defer { repo.destroy() }
    let path = sibling(repo, "pattern")

    let result = try worktreeAddSparse(
        at: repo.url.path, path: path,
        target: .newBranch(name: "patternwork"),
        directories: ["app/*"])
    #expect(!result.success)
    // The add itself succeeded; the sparse step is what refused.
    #expect(result.add.success)
    guard case let .patternRefused(detail) = try #require(result.sparseError) else {
        Issue.record("expected patternRefused, got \(String(describing: result.sparseError))")
        return
    }
    #expect(detail.contains("specify directories rather than patterns"))
    #expect(result.sparseError?.code == "patternRefused")
    // The worktree exists but was never populated.
    let contents = try FileManager.default.contentsOfDirectory(atPath: path)
    #expect(contents == [".git"])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func agentLockSurvivesTheSparseSequence(format: FixtureRepository.RefFormat) throws {
    let repo = try threeDirRepo(format)
    defer { repo.destroy() }
    let path = sibling(repo, "agent")

    let result = try worktreeAddSparse(
        at: repo.url.path, path: path,
        target: .newBranch(name: "agentwork"),
        directories: ["app"],
        agentID: "s9")
    #expect(result.success)
    #expect(result.add.lockReason == "switchyard-agent:session=s9")

    let entry = try worktreeList(path: repo.url.path).first {
        WorktreeContext.canonicalize($0.path ?? "") == WorktreeContext.canonicalize(path)
    }
    let found = try #require(entry)
    #expect(found.locked)
    #expect(found.lockReason == "switchyard-agent:session=s9")
    // The lock was taken at creation, before population — and the sparse tree
    // still checked out through it.
    #expect(FileManager.default.fileExists(atPath: path + "/app/a.txt"))
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func addRefusalShortCircuitsTheSparseSteps(format: FixtureRepository.RefFormat) throws {
    let repo = try threeDirRepo(format)
    defer { repo.destroy() }
    // `main` is held by the main worktree — the add is refused, and the
    // sparse steps must not run (there is no worktree to run them in).
    let result = try worktreeAddSparse(
        at: repo.url.path, path: sibling(repo, "refused"),
        target: .branch("main"),
        directories: ["app"])
    #expect(!result.success)
    #expect(result.sparseError == nil)
    let error = try #require(result.add.error)
    guard case .branchInUse = error else {
        Issue.record("expected branchInUse, got \(error)")
        return
    }
}
