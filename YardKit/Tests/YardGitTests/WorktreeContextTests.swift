// WorktreeContextTests.swift

import Foundation
import Testing
@testable import YardGit

struct WorktreeContextTests {

    private let git = GitProcess()

    private func makeRepo(refFormat: String = "files", bare: Bool = false) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var args = ["init", "-q", "--ref-format=\(refFormat)"]
        if bare { args.append("--bare") }
        args.append(dir.path)
        try git.run(args)
        if !bare {
            try git.run(["config", "user.name", "Test"], workingDirectory: dir.path)
            try git.run(["config", "user.email", "test@example.invalid"], workingDirectory: dir.path)
            try git.run(["commit", "-q", "--allow-empty", "-m", "base"], workingDirectory: dir.path)
        }
        return dir
    }

    // MARK: - Main worktree

    @Test func mainWorktreeHasMatchingGitDirAndCommonDir() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let ctx = try WorktreeContext.resolve(path: repo.path)
        #expect(ctx.gitDir == ctx.commonDir, "main worktree should share GIT_DIR and GIT_COMMON_DIR")
        #expect(!ctx.isLinkedWorktree)
        #expect(!ctx.isBare)
        #expect(ctx.worktreeName == nil)
        #expect(ctx.topLevel == WorktreeContext.canonicalize(repo.path))
    }

    /// Agents and drag-and-drop hand over paths inside the tree, not its root.
    @Test func resolvesFromASubdirectory() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let nested = repo.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let fromRoot = try WorktreeContext.resolve(path: repo.path)
        let fromNested = try WorktreeContext.resolve(path: nested.path)
        #expect(fromNested.commonDir == fromRoot.commonDir)
        #expect(fromNested.topLevel == fromRoot.topLevel)
    }

    // MARK: - Linked worktree

    @Test func linkedWorktreeSplitsGitDirFromCommonDir() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-agent-a-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: linked) }
        try git.run(["worktree", "add", "-q", "-b", "agent-a", linked.path],
                    workingDirectory: repo.path)

        let ctx = try WorktreeContext.resolve(path: linked.path)
        #expect(ctx.isLinkedWorktree)
        #expect(ctx.gitDir != ctx.commonDir, "a linked worktree must not share GIT_DIR")
        #expect(ctx.gitDir.contains("/worktrees/"))
        #expect(ctx.worktreeName != nil)

        // The identity that matters: a linked worktree resolves to the same
        // repository as its parent. This is what makes #0079's tab de-dup work.
        let main = try WorktreeContext.resolve(path: repo.path)
        #expect(ctx.commonDir == main.commonDir,
                "worktree and main must share GIT_COMMON_DIR — repository identity")
    }

    /// #0307: a repository whose own path contains a `worktrees` path
    /// component makes `gitDir` contain **two** `/worktrees/` occurrences —
    /// one from the repository's own path, one from git's real
    /// `worktrees/<name>` layout. A forward search on `/worktrees/` matches
    /// the first (wrong) occurrence and returns everything after it,
    /// including the rest of the repository path; only a backward search
    /// lands on git's own `worktrees/<name>` and yields the bare name.
    ///
    /// Naming the *worktree* itself `worktrees` would not reproduce this —
    /// the ambiguity requires the **repository's own path** to contain the
    /// component, which is why this fixture is created under a directory
    /// literally named `worktrees` rather than under a plain temp directory.
    @Test func worktreeNameIsCleanWhenRepositoryPathContainsWorktreesComponent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-wt-ambiguous-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("worktrees").appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try git.run(["init", "-q", repo.path])
        try git.run(["config", "user.name", "Test"], workingDirectory: repo.path)
        try git.run(["config", "user.email", "test@example.invalid"], workingDirectory: repo.path)
        try git.run(["commit", "-q", "--allow-empty", "-m", "base"], workingDirectory: repo.path)

        let linked = root.appendingPathComponent("wt1")
        try git.run(["worktree", "add", "-q", "-b", "agent-b", linked.path], workingDirectory: repo.path)

        let ctx = try WorktreeContext.resolve(path: linked.path)

        // Confirm the fixture actually reproduces the ambiguity: a forward
        // (first-match) search on the same marker used in production would
        // land on the repository's own `worktrees` path component and
        // return a tail that still contains a slash, not a bare name.
        let marker = "/worktrees/"
        let forwardRange = try #require(
            ctx.gitDir.range(of: marker),
            "gitDir should contain the worktrees/ marker at all")
        let forwardTail = String(ctx.gitDir[forwardRange.upperBound...])
        #expect(forwardTail.contains("/"),
                "fixture must reproduce the ambiguity: a forward search's tail should still contain a path separator")

        let name = try #require(ctx.worktreeName)
        #expect(name == "wt1")
        #expect(!name.contains("/"), "worktreeName must be a bare name, never a path fragment")
    }

    /// `.git` in a linked worktree is a file holding a `gitdir:` pointer, not a
    /// directory. Anything that assumed a directory would fail here.
    @Test func linkedWorktreeDotGitIsAFile() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-file-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: linked) }
        try git.run(["worktree", "add", "-q", "-b", "probe", linked.path], workingDirectory: repo.path)

        var isDirectory: ObjCBool = true
        let exists = FileManager.default.fileExists(
            atPath: linked.appendingPathComponent(".git").path, isDirectory: &isDirectory)
        #expect(exists)
        #expect(!isDirectory.boolValue, ".git in a linked worktree is a file, not a directory")
    }

    // MARK: - Cross-worktree ref access

    @Test func readsAnotherWorktreesHead() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-cross-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: linked) }
        try git.run(["worktree", "add", "-q", "-b", "sibling", linked.path], workingDirectory: repo.path)

        let ctx = try WorktreeContext.resolve(path: linked.path)
        let name = try #require(ctx.worktreeName)

        // From the main worktree, read the sibling's HEAD.
        let main = try WorktreeContext.resolve(path: repo.path)
        let siblingHead = try main.resolveRef("HEAD", inWorktree: name)
        #expect(siblingHead != nil, "worktrees/\(name)/HEAD should resolve from the main worktree")

        // And the main worktree's HEAD from the linked one.
        let mainHead = try ctx.resolveRef("HEAD", inWorktree: nil)
        #expect(mainHead != nil, "main-worktree/HEAD should resolve from a linked worktree")
    }

    @Test func refNameUsesGitsSpecialPrefixes() {
        #expect(WorktreeContext.refName("HEAD", inWorktree: nil) == "main-worktree/HEAD")
        #expect(WorktreeContext.refName("HEAD", inWorktree: "agent-a") == "worktrees/agent-a/HEAD")
    }

    @Test func missingRefResolvesToNil() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let ctx = try WorktreeContext.resolve(path: repo.path)
        #expect(try ctx.resolveRef("HEAD", inWorktree: "no-such-worktree") == nil)
    }

    // MARK: - Path lookup

    /// `HEAD` is per-worktree and `refs/heads/*` is shared, so in a linked
    /// worktree the two resolve under different directories. This is the
    /// distinction that makes journal restore correct or catastrophic (#0044).
    @Test func gitPathChoosesGitDirOrCommonDirCorrectly() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-path-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: linked) }
        try git.run(["worktree", "add", "-q", "-b", "paths", linked.path], workingDirectory: repo.path)

        let ctx = try WorktreeContext.resolve(path: linked.path)
        let headPath = try ctx.path(for: "HEAD")
        let indexPath = try ctx.path(for: "index")

        #expect(headPath.hasPrefix(ctx.gitDir), "HEAD is per-worktree")
        #expect(indexPath.hasPrefix(ctx.gitDir), "the index is per-worktree")
        #expect(headPath.contains("/worktrees/"))
    }

    // MARK: - Bare and reftable

    @Test func bareRepositoryHasNoTopLevel() throws {
        let repo = try makeRepo(bare: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let ctx = try WorktreeContext.resolve(path: repo.path)
        #expect(ctx.isBare)
        #expect(ctx.topLevel == nil)
    }

    @Test func worksAgainstAReftableRepository() throws {
        let repo = try makeRepo(refFormat: "reftable")
        defer { try? FileManager.default.removeItem(at: repo) }
        let ctx = try WorktreeContext.resolve(path: repo.path)
        #expect(ctx.gitDir == ctx.commonDir)
        #expect(ctx.topLevel != nil)
    }

    // MARK: - Newline safety (#0285)

    /// The case #0284's round deliberately deferred: resolving *from inside*
    /// a worktree whose own path contains a newline exercises
    /// `WorktreeContext.resolve`'s own `rev-parse` parsing, not
    /// `worktree list --porcelain`'s. Models
    /// `WorktreeListTests.newlineInPathRoundTrips` and
    /// `WorktreeWhereTests.newlineInLinkedWorktreePathDoesNotCorruptParsing`,
    /// which cover the porcelain-listing layer this issue sits underneath.
    @Test func newlineInOwnPathDoesNotTruncateOrShiftAnyValue() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let nameWithNewline = "has\nnewline"
        let wtPath = try repo.addWorktree(path: nameWithNewline, branch: "nlbranch")
        defer { try? FileManager.default.removeItem(at: wtPath) }

        let ctx = try WorktreeContext.resolve(path: wtPath.path)

        // topLevel must retain the embedded newline whole, not truncate at
        // the first line break.
        #expect(ctx.topLevel == WorktreeContext.canonicalize(wtPath.path),
                "topLevel must round-trip the newline in the worktree's own path")

        // gitDir must resolve to this worktree's private state under
        // <common>/worktrees/<name> -- not get shifted onto the wrong line
        // by a newline earlier in some combined multi-value read.
        #expect(ctx.gitDir.contains("/worktrees/"), "gitDir must resolve whole")
        #expect(ctx.isLinkedWorktree)

        // commonDir must land on the parent repository's own $GIT_COMMON_DIR
        // (its `.git`), not on a newline-shifted fragment of gitDir.
        let main = try WorktreeContext.resolve(path: repo.url.path)
        #expect(ctx.commonDir == main.commonDir,
                "commonDir must not be corrupted by a newline in gitDir")
    }

    // MARK: - Failure

    @Test func nonRepositoryThrows() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: WorktreeContext.Error.self) {
            _ = try WorktreeContext.resolve(path: dir.path)
        }
    }

    // MARK: - The rule holds across the package

    /// No source may build a git path by concatenating onto `.git/`.
    @Test func noSourceConcatenatesOntoDotGit() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")

        let fm = FileManager.default
        var offenders: [String] = []
        guard let walker = fm.enumerator(at: sources, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                if line.contains("\".git/") || line.contains("appendingPathComponent(\".git\")") {
                    offenders.append("\(url.lastPathComponent):\(n + 1)")
                }
            }
        }
        #expect(offenders.isEmpty,
                "git paths must come from rev-parse --git-path, not concatenation: \(offenders)")
    }
}
