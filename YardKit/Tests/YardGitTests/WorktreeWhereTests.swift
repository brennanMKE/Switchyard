// WorktreeWhereTests.swift

import Foundation
import Testing
@testable import YardGit

struct WorktreeWhereTests {

    private let git = GitProcess()

    // MARK: - Main worktree

    @Test func mainWorktreeReturnsNameNilAndCorrectPaths() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let result = try yardWhere(path: repo.url.path)
        #expect(result.worktreeName == nil, "main worktree has no name")
        #expect(result.path != nil)
        #expect(!result.gitDir.isEmpty)
        #expect(!result.commonDir.isEmpty)
        #expect(result.mainWorktreePath != nil, "main worktree path must be reported")

        // gitDir and commonDir match in the main worktree.
        #expect(result.gitDir == result.commonDir,
                "main worktree must share GIT_DIR and GIT_COMMON_DIR")

        // mainWorktreePath is the primary checkout, which equals our repo path.
        #expect(result.mainWorktreePath == WorktreeContext.canonicalize(repo.url.path),
                "main worktree path must be the primary checkout")
    }

    @Test func mainWorktreePathInTopLevelDoesNotTruncateGitDir() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        // Resolve from a subdirectory rather than the root. The main path
        // must still come from `git worktree list`, not by string surgery.
        let sub = repo.url.appendingPathComponent("dummy-dir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let result = try yardWhere(path: sub.path)
        #expect(result.mainWorktreePath == WorktreeContext.canonicalize(repo.url.path))

        // And it is definitely not just `commonDir` with `.git` stripped —
        // that string surgery breaks on bare repos and .git files.
        #expect(result.mainWorktreePath != result.commonDir)
    }

    // MARK: - Linked worktree

    @Test func linkedWorktreeSplitsGitDirFromCommonDir() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let wtPath = try repo.addWorktree(named: "agent-a", branch: "agent-a")
        defer { try? FileManager.default.removeItem(at: wtPath) }

        let result = try yardWhere(path: wtPath.path)
        // Git names a linked worktree after the basename of the directory it
        // was created at (`addWorktree(named:)` builds that as
        // "<fixture>-wt-agent-a") -- not the literal fixture label passed in.
        // `WorktreeContextTests.readsAnotherWorktreesHead` confirms the same
        // thing indirectly, for `WorktreeContext.worktreeName`.
        #expect(result.worktreeName == wtPath.lastPathComponent,
                "linked worktree must report its actual name")

        // The key assertion: $GIT_DIR != $GIT_COMMON_DIR in a linked worktree.
        #expect(result.gitDir != result.commonDir,
                "a linked worktree must report distinct GIT_DIR and GIT_COMMON_DIR")

        // And the name ends with /worktrees/<name>.
        #expect(result.gitDir.contains("/worktrees/"))

        // mainWorktreePath is the primary checkout, NOT the linked one.
        #expect(result.mainWorktreePath != wtPath.path,
                "main worktree path must be the primary checkout, not the linked one")
        #expect(result.mainWorktreePath == WorktreeContext.canonicalize(repo.url.path),
                "main worktree path must be the primary checkout")
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func linkedWorktreeSplitsGitDirFromCommonDirAcrossRefFormats(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }

        let wtPath = try repo.addWorktree(named: "fmt-agent", branch: "fmt-agent")
        defer { try? FileManager.default.removeItem(at: wtPath) }

        let result = try yardWhere(path: wtPath.path)
        #expect(result.gitDir != result.commonDir,
                "a linked worktree must report distinct GIT_DIR and GIT_COMMON_DIR in \(format.rawValue)")
        #expect(result.mainWorktreePath == WorktreeContext.canonicalize(repo.url.path))
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func mainWorktreeInBothRefFormats(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }

        let result = try yardWhere(path: repo.url.path)
        #expect(result.gitDir == result.commonDir, "main worktree shares dirs in \(format.rawValue)")
        #expect(result.worktreeName == nil)
        #expect(result.mainWorktreePath != nil)

        // main worktree path equals the repo's URL, verified via WorktreeContext.
        let ctx = try WorktreeContext.resolve(path: repo.url.path)
        #expect(result.mainWorktreePath == ctx.topLevel)
    }

    // MARK: - Bare repository

    @Test func bareRepositoryReturnsNoTopLevel() throws {
        let repo = try FixtureRepository(refFormat: .files, bare: true)
        defer { repo.destroy() }

        let result = try yardWhere(path: repo.url.path)
        #expect(result.worktreeName == nil, "bare repo has no worktree name")
        #expect(result.path == nil, "bare repo has no working tree path")

        // Bare repos still have a git dir and common dir (the same one).
        #expect(!result.gitDir.isEmpty)
        #expect(!result.commonDir.isEmpty)

        // mainWorktreePath is nil for bare repos — there is no primary checkout.
        #expect(result.mainWorktreePath == nil, "bare repo has no main worktree")
    }

    // MARK: - Error path

    @Test func nonRepositoryThrows() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: (any Error).self) {
            _ = try yardWhere(path: dir.path)
        }
    }

    // MARK: - Value-type round-trip

    @Test func resultIsEqualWhenFieldsMatch() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let first = try yardWhere(path: repo.url.path)
        let second = try yardWhere(path: repo.url.path)

        #expect(first == second, "two calls from the same path must yield equal results")
    }

    @Test func resultIsNotEqualAcrossWorktrees() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let wtPath = try repo.addWorktree(named: "diff", branch: "diff")
        defer { try? FileManager.default.removeItem(at: wtPath) }

        let mainResult = try yardWhere(path: repo.url.path)
        let linkedResult = try yardWhere(path: wtPath.path)

        #expect(mainResult != linkedResult,
                "main worktree and linked worktree must produce different results")
    }

    // MARK: - porcelain-first-is-main

    @Test func mainWorktreeLineComesFirstInPorcelainEvenFromLinked() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let wtPath = try repo.addWorktree(named: "first-linked", branch: "first-linked")
        defer { try? FileManager.default.removeItem(at: wtPath) }

        // Resolve from the linked worktree. The main path must still be
        // the primary checkout, never the current one.
        let result = try yardWhere(path: wtPath.path)

        // Sanity: we are running from the linked worktree.
        #expect(result.worktreeName != nil)

        // The main path must be the primary, NOT this linked checkout.
        #expect(result.mainWorktreePath != wtPath.path)

        // The primary is exactly the repo URL.
        let expected = WorktreeContext.canonicalize(repo.url.path)
        #expect(result.mainWorktreePath == expected,
                "main worktree path must be the primary checkout even when resolving from linked")
    }

    // MARK: - path extraction is non-empty before compare (Rule 7 guard)

    @Test func mainPathExtractionIsNonEmptyBeforeCompare() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let result = try yardWhere(path: repo.url.path)
        #expect(result.mainWorktreePath != nil, "main path must be non-nil in a non-bare repo")
        let mainPath = result.mainWorktreePath!
        #expect(!mainPath.isEmpty, "extraction must be non-empty before compare")

        let ctx = try WorktreeContext.resolve(path: repo.url.path)
        #expect(result.mainWorktreePath == ctx.topLevel, "must equal top-level after non-empty check")
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func mainPathExtractionIsNonEmptyAcrossRefFormats(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }

        let result = try yardWhere(path: repo.url.path)
        #expect(result.mainWorktreePath != nil, "main path must be non-nil in \(format.rawValue)")
        let mainPath = result.mainWorktreePath!
        #expect(!mainPath.isEmpty, "extraction non-empty in \(format.rawValue)")
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func linkedGitDirDiffersFromCommonInRefFormats(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }

        let wtPath = try repo.addWorktree(named: "fmt-linked", branch: "fmt-linked")
        defer { try? FileManager.default.removeItem(at: wtPath) }

        let result = try yardWhere(path: wtPath.path)
        #expect(result.mainWorktreePath != nil, "main path must be non-nil in \(format.rawValue)")
        let mainPath = result.mainWorktreePath!
        #expect(!mainPath.isEmpty, "main path non-empty in \(format.rawValue)")
        #expect(result.gitDir != result.commonDir,
                "linked worktree git dir differs in \(format.rawValue)")

        // And main path is not the linked one.
        let ctx = try WorktreeContext.resolve(path: wtPath.path)
        #expect(result.mainWorktreePath != ctx.topLevel,
                "main path must not equal the linked worktree's top-level in \(format.rawValue)")
    }

    // MARK: - Newline safety (#0284)

    @Test func newlineInLinkedWorktreePathDoesNotCorruptParsing() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let nameWithNewline = "has\nnewline"
        let wtPath = try repo.addWorktree(path: nameWithNewline, branch: "nlbranch")
        defer { try? FileManager.default.removeItem(at: wtPath) }

        // The newline lives in a *linked* worktree's record, elsewhere in the
        // porcelain output -- mirrors `WorktreeListTests.newlineInPathRoundTrips`,
        // which pins the same hazard for `worktreeList`. Both commands parse
        // the same `-z`-terminated output and must not disagree about how.
        //
        // Resolved from the main worktree only: resolving *from inside* the
        // newline-path worktree itself would also exercise
        // `WorktreeContext.resolve`'s own `rev-parse` line parsing
        // (WorktreeContext.swift), which is a separate, out-of-scope
        // newline hazard -- see the round report.
        let result = try yardWhere(path: repo.url.path)
        #expect(result.mainWorktreePath != nil,
                "main path must survive a newline elsewhere in the porcelain output")
        #expect(result.mainWorktreePath == WorktreeContext.canonicalize(repo.url.path),
                "main worktree path must be exact and unmutated by the embedded newline")
    }
}
