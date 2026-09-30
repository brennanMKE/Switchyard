// FileInspectorMenuTests.swift — File ▸ Show File History… / Blame File… (#0519)

import Foundation
import Testing
import YardGit
import YardUI

@Test func aChosenFileIsTheWorkingTreesFileAtItsRelativePath() throws {
    let repo = try FixtureRepository()
    defer { repo.destroy() }
    let root = repo.url.path

    let target = FileInspectorTarget.forChosenFile(
        URL(fileURLWithPath: root + "/dir/a.txt"), worktreePath: root, mode: .blame)
    #expect(target == FileInspectorTarget(mode: .blame, path: "dir/a.txt", revision: nil))
}

/// `FixtureRepository` resolves its own path with `realpath(3)`, so its
/// `/private/var/…` path and the unresolved `/var/…` name the same folder;
/// the panel may hand back either.
@Test func theWorktreeAndTheChosenFileAreComparedResolved() throws {
    let repo = try FixtureRepository()
    defer { repo.destroy() }
    let resolved = repo.url.path
    try #require(resolved.hasPrefix("/private/var/"))
    let unresolved = String(resolved.dropFirst("/private".count))
    try "x\n".write(toFile: resolved + "/a.txt", atomically: true, encoding: .utf8)

    #expect(FileInspectorTarget.forChosenFile(
        URL(fileURLWithPath: unresolved + "/a.txt"), worktreePath: resolved, mode: .history)?.path == "a.txt")
    #expect(FileInspectorTarget.forChosenFile(
        URL(fileURLWithPath: resolved + "/a.txt"), worktreePath: unresolved, mode: .history)?.path == "a.txt")
}

@Test func aFileOutsideTheWorktreeOrInsideDotGitIsRefused() throws {
    let repo = try FixtureRepository()
    defer { repo.destroy() }
    let root = repo.url.path

    #expect(FileInspectorTarget.forChosenFile(
        URL(fileURLWithPath: "/etc/hosts"), worktreePath: root, mode: .history) == nil)
    #expect(FileInspectorTarget.forChosenFile(
        URL(fileURLWithPath: root + "-sibling/a.txt"), worktreePath: root, mode: .history) == nil,
        "a sibling folder whose name starts with the worktree's is outside it")
    #expect(FileInspectorTarget.forChosenFile(
        URL(fileURLWithPath: root + "/.git/config"), worktreePath: root, mode: .history) == nil)
    #expect(FileInspectorTarget.forChosenFile(
        URL(fileURLWithPath: root), worktreePath: root, mode: .history) == nil)
}
