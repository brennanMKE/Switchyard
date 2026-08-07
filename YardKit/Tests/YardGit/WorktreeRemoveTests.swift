// WorktreeRemoveTests.swift

import Testing
@testable import YardGit

/// Tests for `worktreeRemove` — cover every documented case:
/// existing linked, unknown path, nested-in-another-worktree, lock released for agent session,
/// unclean with force vs without force (refusal and forced-removal), untracked file, and
/// nested-path error.
@Test("removes an existing linked worktree without forcing") func removesExistingWorktree() throws {
    var fixture = try FixtureRepository()

    let worktreePath: URL = try fixture.addWorktree(named: "test-remove", branch: "main")
    let context = try WorktreeContext.resolve(forPath: worktreePath.path)

    let result: WorktreeRemoveResult = try worktreeRemove(
        at: context.repositoryPath!,
        worktree.path,
        git: fixture.git
    )

    #expect(result.success)
    let removed = URL(fileURLWithPath: result.worktreePath).lastPathComponent
    #expect(removed.contains("wt-test-remove"))

    let entries = try worktreeList(path: context.repositoryPath, git: fixture.git)
    let stillThere = entries.contains(where: { canonicalize($0.path ?? "") == result.worktreePath })
    #expect(!stillThere)

    #expect(result.lockedRelease == false)
}

/// If the path is not a worktree known to this repository, refuse cleanly rather than crash.
@Test("refuses with --unknown when the path is not a worktree") func refusesUnknownPath() throws {
    var fixture = try FixtureRepository()
    let context = try WorktreeContext.resolve(forPath: fixture.url.path)

    let nonexistentPath = String(fixture.url.deletingLastPathComponent().path
        + "/not-a-worktree-xyz")

    let result: WorktreeRemoveResult = try worktreeRemove(
        at: context.repositoryPath!,
        nonexistentPath,
        git: fixture.git
    )

    #expect(result.error is WorktreeRemoveError.unclean == false)
    if case let .unknown(path) = result.error {
        #expect(path == nonexistentPath)
    } else if case .unclean = result.error {
        Issue.record("refusal error should be .unknown, got \(result.error ?? "")")
    } else {
        Issue.record("expected .unknown error, got \(result.error ?? "")")
    }

    #expect(!result.success)
}

/// Locks an agent session on the worktree, then removes — we should release the lock
/// and remove cleanly.
@Test("releases an agent session lock before removing") func releasesAgentLock() throws {
    var fixture = try FixtureRepository()

    let worktreePath: URL = try fixture.addWorktree(named: "agent-lock-wt", branch: "main")
    let context = try WorktreeContext.resolve(forPath: worktreePath.path)

    // Lock the worktree with an agent session reason.
    try fixture.lockWorktree(worktreePath, reason: "agent testing 123")

    let result: WorktreeRemoveResult = try worktreeRemove(
        at: context.repositoryPath!,
        worktree.path,
        git: fixture.git
    )

    #expect(result.success)
    #expect(result.lockedRelease == true)

    let entries = try worktreeList(path: context.repositoryPath, git: fixture.git)
    let stillThere = entries.contains(where: { canonicalize($0.path ?? "") == result.worktreePath })
    #expect(!stillThere)

    // The lock was actually released — a second list should have no locked line.
    let remaining = try worktreeList(path: context.repositoryPath, git: fixture.git)
    if let entry = remaining.first(where: { canonicalize($0.path ?? "") == result.worktreePath }) {
        #expect(entry.locked == false)
    }
}

/// Nested-path refusal: a child of another worktree's working tree cannot be removed.
@Test("refuses to remove a nested worktree path") func refusesNested() throws {
    var fixture = try FixtureRepository()

    // Create a worktree and then add another one inside it — git will refuse that
    // configuration, but for the test we just call remove on a nested path.
    let basePath: URL = try fixture.addWorktree(named: "parent-wt", branch: "main")
    let nestedPath = basePath.appendingPathComponent("nested-child")

    let context = try WorktreeContext.resolve(forPath: fixture.url.path)

    // Manually add a real worktree at that path. This produces the correct
    // inner .git that makes git think it is a nested worktree.
    try fixture.git.run(["worktree", "add", "-q", nestedPath.path],
                        workingDirectory: context.repositoryPath!)

    let result: WorktreeRemoveResult = try worktreeRemove(
        at: context.repositoryPath!,
        nestedPath.path,
        git: fixture.git
    )

    #expect(!result.success)
}

/// On unclean worktrees without --force, refuse with the list of dirty paths.
@Test("refuses to remove a worktree that contains modified files without force") func refusesDirtyWorktreeWithoutForce() throws {
    var fixture = try FixtureRepository()

    let worktreePath: URL = try fixture.addWorktree(named: "dirty-wt", branch: "main")
    let context = try WorktreeContext.resolve(forPath: worktreePath.path)

    // Modify a tracked file in the linked worktree to make it dirty.
    try fixture.writeUntracked(["dirty.txt": "this is a change"])

    let result: WorktreeRemoveResult = try worktreeRemove(
        at: context.repositoryPath!,
        worktree.path,
        force: false,
        git: fixture.git
    )

    #expect(!result.success)
}

/// Same unclean worktree but with --force, should remove cleanly.
@Test("removes an unclean worktree when forced") func removesDirtyWorktreeWithForce() throws {
    var fixture = try FixtureRepository()

    let worktreePath: URL = try fixture.addWorktree(named: "dirty-forced-wt", branch: "main")
    let context = try WorktreeContext.resolve(forPath: worktree.path)

    // Modify a tracked file to make it dirty.
    try fixture.writeUntracked(["dirty.txt": "this is a change"])

    let result: WorktreeRemoveResult = try worktreeRemove(
        at: context.repositoryPath!,
        worktree.path,
        force: true,
        git: fixture.git
    )

    #expect(result.success)
}

/// A worktree with untracked files is dirty and refuses without --force.
@Test("refuses to remove a worktree with untracked files") func refusesWorktreeWithUntracked() throws {
    var fixture = try FixtureRepository()

    let worktreePath: URL = try fixture.addWorktree(named: "untracked-wt", branch: "main")
    let context = try WorktreeContext.resolve(forPath: worktree.path)

    // Create a file that is not tracked.
    try "untracked content".write(to: worktreePath.appendingPathComponent("hello.txt"),
                                 atomically: true, encoding: .utf8)

    let result: WorktreeRemoveResult = try worktreeRemove(
        at: context.repositoryPath!,
        worktree.path,
        force: false,
        git: fixture.git
    )

    #expect(!result.success)
}

/// Test the nested path refusal: a child of another worktree's working tree cannot be removed.
@Test("refuses to remove when the target path is nested inside another worktree") func refusesNestedTarget() throws {
    var fixture = try FixtureRepository()

    let basePath: URL = try fixture.addWorktree(named: "nested-parent-wt", branch: "main")
    let nestedPath = basePath.appendingPathComponent("child-nested-wt")

    // Manually create a git directory and mark it as linked inside the parent.
    let nestedGit = nestedPath.appendingPathComponent(".git")
    try FileManager.default.createDirectory(at: nestedGit, withIntermediateDirectories: true)

    // Write a proper 'gitdir:' reference back to the parent repo.
    let gitDirPath = nestedGit.appendingPathComponent("gitdir")
    var contents = "gitdir: \(fixture.url.path)\n".data(using: .utf8)!
    try contents.write(to: gitDirPath, options: [.atomic])

    let context = try WorktreeContext.resolve(forPath: fixture.url.path)

    let result: WorktreeRemoveResult = try worktreeRemove(
        at: context.repositoryPath!,
        nestedPath.path,
        git: fixture.git
    )

    #expect(!result.success)
}
