// WorktreeResolveRefSharedRefTests.swift

import Foundation
import Testing
@testable import YardGit

/// Verifies that resolveRef routes shared refs through their plain name and
/// per-worktree refs through the worktrees/ prefix, matching git's own split.
struct WorktreeResolveRefSharedRefTests {

    private let git = GitProcess()

    @Test func mainWorktreePath_hasSharedTagsResolvablePlainName() throws {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-rsr-\(UUID().uuidString)")
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("rsr-wt-\(UUID().uuidString.prefix(6))")

        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        var args = ["init", "-q"]
        try git.run(args + [repo.path])
        defer { try? FileManager.default.removeItem(at: repo) }
        defer { try? FileManager.default.removeItem(at: linked) }

        try git.run(["config", "user.name", "Test"], workingDirectory: repo.path)
        try git.run(["config", "user.email", "test@example.invalid"], workingDirectory: repo.path)
        try git.run(["commit", "-q", "--allow-empty", "-m", "base"], workingDirectory: repo.path)
        try git.run(["worktree", "add", "-q", "-b", "lb", linked.path], workingDirectory: repo.path)
        try git.run(["tag", "-q", "v1"], workingDirectory: repo.path)

        // From inside the linked worktree, create per-worktree refs so they
        // land in linked's private namespace.
        try git.run(["update-ref", "-q", "refs/bisect/good", "HEAD"], workingDirectory: linked.path)
        try git.run(["update-ref", "-q", "refs/worktree/mine", "HEAD"], workingDirectory: linked.path)

        let main = try WorktreeContext.resolve(path: repo.path)
        let linkedName = try (try WorktreeContext.resolve(path: linked.path)).worktreeName
            ?? "lb"

        // Shared tag resolves under its plain name from the main worktree.
        let v1 = try main.resolveRef("refs/tags/v1", inWorktree: nil)
        #expect(v1 != nil, "refs/tags/v1 should resolve from the main worktree")
        #expect(v1 != nil && v1!.count == 40, "tag ref should return a full object id")

        // Shared branch resolves under its plain name from the main worktree
        // (this is what the bug broke).
        let lb = try main.resolveRef("refs/heads/lb", inWorktree: nil)
        #expect(lb != nil, "refs/heads/lb should resolve from the main worktree")
        #expect(lb == v1, "shared branch and shared tag should point at the same commit")
    }

    @Test func perWorktreeHEADResolvesWithPrefix() throws {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-rsr-\(UUID().uuidString)")
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("rsr-wt-\(UUID().uuidString.prefix(6))")

        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        var args = ["init", "-q"]
        try git.run(args + [repo.path])
        defer { try? FileManager.default.removeItem(at: repo) }
        defer { try? FileManager.default.removeItem(at: linked) }

        try git.run(["config", "user.name", "Test"], workingDirectory: repo.path)
        try git.run(["config", "user.email", "test@example.invalid"], workingDirectory: repo.path)
        try git.run(["commit", "-q", "--allow-empty", "-m", "base"], workingDirectory: repo.path)
        try git.run(["worktree", "add", "-q", "-b", "lb", linked.path], workingDirectory: repo.path)

        let main = try WorktreeContext.resolve(path: repo.path)
        let linkedCtx = try WorktreeContext.resolve(path: linked.path)

        // Linked worktree's HEAD resolves under the per-worktree prefix from main.
        let linkedName = try #require(linkedCtx.worktreeName)
        let siblingHead = try main.resolveRef("HEAD", inWorktree: linkedName)
        #expect(siblingHead != nil, "worktrees/<name>/HEAD should resolve")

        // Shared refs do NOT resolve under the per-worktree prefix (verified
        // against git's own behaviour: worktrees/lw/refs/heads/lb returns 1).
        let sharedViaPrefix = try main.resolveRef("refs/heads/lb", inWorktree: linkedName)
        #expect(sharedViaPrefix == nil, "shared refs must not resolve via worktrees/<name>/ prefix")
    }

    @Test func perWorktreeBisectRefResolvesWithPrefix() throws {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-rsr-\(UUID().uuidString)")
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("rsr-wt-\(UUID().uuidString.prefix(6))")

        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        var args = ["init", "-q"]
        try git.run(args + [repo.path])
        defer { try? FileManager.default.removeItem(at: repo) }
        defer { try? FileManager.default.removeItem(at: linked) }

        try git.run(["config", "user.name", "Test"], workingDirectory: repo.path)
        try git.run(["config", "user.email", "test@example.invalid"], workingDirectory: repo.path)
        try git.run(["commit", "-q", "--allow-empty", "-m", "base"], workingDirectory: repo.path)
        try git.run(["worktree", "add", "-q", "-b", "lb", linked.path], workingDirectory: repo.path)

        // Per-worktree refs created from inside the linked worktree.
        try git.run(["update-ref", "-q", "refs/bisect/good", "HEAD"], workingDirectory: linked.path)
        try git.run(["update-ref", "-q", "refs/worktree/mine", "HEAD"], workingDirectory: linked.path)

        let main = try WorktreeContext.resolve(path: repo.path)
        let linkedCtx = try WorktreeContext.resolve(path: linked.path)
        let linkedName = try #require(linkedCtx.worktreeName)

        // Per-worktree refs resolve under the prefix.
        let bisectGood = try main.resolveRef("refs/bisect/good", inWorktree: linkedName)
        #expect(bisectGood != nil, "worktrees/<name>/refs/bisect/good should resolve")
        #expect(bisectGood == "HEAD", "bisect ref points at HEAD in this fixture")

        let worktreeMine = try main.resolveRef("refs/worktree/mine", inWorktree: linkedName)
        #expect(worktreeMine != nil, "worktrees/<name>/refs/worktree/mine should resolve")
        #expect(worktreeMine == bisectGood, "both per-worktree refs should hold the same value")
    }

    @Test func isPerWorktreeClassifiesCorrectly() {
        // HEAD qualifies.
        #expect(WorktreeContext.isPerWorktree("HEAD") == true)

        // Common refs do not qualify.
        #expect(WorktreeContext.isPerWorktree("refs/heads/main") == false)
        #expect(WorktreeContext.isPerWorktree("refs/tags/v1") == false)
        #expect(WorktreeContext.isPerWorktree("refs/remotes/origin/main") == false)
        #expect(WorktreeContext.isPerWorktree("refs/stash") == false)

        // Per-worktree prefixes qualify.
        #expect(WorktreeContext.isPerWorktree("refs/bisect/good") == true)
        #expect(WorktreeContext.isPerWorktree("refs/bisect/another") == true)
        #expect(WorktreeContext.isPerWorktree("refs/worktree/mine") == true)
        #expect(WorktreeContext.isPerWorktree("refs/rewritten/y") == true)

        // An empty string does not qualify (trivially).
        #expect(WorktreeContext.isPerWorktree("") == false)
    }

    @Test func resolveRefReturnsNilForGenuinelyAbsentShared() throws {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-rsr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        var args = ["init", "-q"]
        try git.run(args + [repo.path])
        defer { try? FileManager.default.removeItem(at: repo) }

        let ctx = try WorktreeContext.resolve(path: repo.path)
        #expect(try ctx.resolveRef("refs/heads/nonexistent", inWorktree: nil) == nil)
    }

    @Test func resolveRefReturnsNilForGenuinelyAbsentPerWorktree() throws {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-rsr-\(UUID().uuidString)")
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("rsr-wt-\(UUID().uuidString.prefix(6))")

        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        var args = ["init", "-q"]
        try git.run(args + [repo.path])
        defer { try? FileManager.default.removeItem(at: repo) }
        defer { try? FileManager.default.removeItem(at: linked) }

        let main = try WorktreeContext.resolve(path: repo.path)
        // A per-worktree ref that was never created should still return nil.
        #expect(try main.resolveRef("refs/worktree/never-made", inWorktree: "any-name") == nil)
    }

    @Test func resolveRefAlsoWorksAgainstReftableRepository() throws {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-rsr-\(UUID().uuidString)")
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("rsr-wt-\(UUID().uuidString.prefix(6))")

        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        var args = ["init", "-q", "--ref-format=reftable"]
        try git.run(args + [repo.path])
        defer { try? FileManager.default.removeItem(at: repo) }
        defer { try? FileManager.default.removeItem(at: linked) }

        try git.run(["config", "user.name", "Test"], workingDirectory: repo.path)
        try git.run(["config", "user.email", "test@example.invalid"], workingDirectory: repo.path)
        try git.run(["commit", "-q", "--allow-empty", "-m", "base"], workingDirectory: repo.path)
        try git.run(["worktree", "add", "-q", "-b", "lb", linked.path], workingDirectory: repo.path)
        try git.run(["tag", "-q", "v1"], workingDirectory: repo.path)

        let main = try WorktreeContext.resolve(path: repo.path)
        let v1 = try main.resolveRef("refs/tags/v1", inWorktree: nil)
        #expect(v1 != nil, "refs/tags/v1 should resolve from the main worktree")
    }

}
