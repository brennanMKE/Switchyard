// FixtureRepositoryTests.swift

import Foundation
import Testing
@testable import YardGit

/// The harness has to be trustworthy before anything is verified with it, so
/// these tests check the fixtures themselves — every shape, in every ref format
/// the local git supports.
struct FixtureRepositoryTests {

    /// Both formats when git can build them, `files` alone when it cannot.
    /// Declared once so every parameterized test covers the same matrix.
    static let formats = FixtureRepository.RefFormat.supported()

    @Test func localGitSupportsBothRefFormats() {
        // Not an assertion about the code — an assertion about the machine, so
        // a reduced matrix is visible rather than silently narrowing coverage.
        #expect(Self.formats.contains(.files))
        if !Self.formats.contains(.reftable) {
            Issue.record("""
                git \(gitVersion()) cannot create reftable repositories, so the reftable half of \
                this suite is being skipped. Reftable becomes git's default in 3.0 — coverage is \
                reduced until git is updated.
                """)
        }
    }

    private func gitVersion() -> String {
        (try? GitProcess().run(["--version"]).lines.first) as? String ?? "unknown"
    }

    // MARK: - Shapes

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func linearHistoryHasThreeCommits(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let count = try GitProcess().run(["rev-list", "--count", "HEAD"],
                                         workingDirectory: repo.url.path).lines[0]
        #expect(count == "3")
        #expect(repo.oids.count == 3)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func mergeCommitHasTwoParents(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.merged(refFormat: format)
        defer { repo.destroy() }
        let merge = try #require(repo.oids["merge"])
        let parents = try GitProcess()
            .run(["rev-list", "--parents", "-n", "1", merge], workingDirectory: repo.url.path)
            .lines[0].split(separator: " ")
        #expect(parents.count == 3, "expected commit + 2 parents, got \(parents.count)")
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func octopusMergeHasThreeParents(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.octopus(refFormat: format)
        defer { repo.destroy() }
        let octo = try #require(repo.oids["octo"])
        let parents = try GitProcess()
            .run(["rev-list", "--parents", "-n", "1", octo], workingDirectory: repo.url.path)
            .lines[0].split(separator: " ")
        #expect(parents.count == 4, "expected commit + 3 parents, got \(parents.count)")
    }

    /// The state `git write-tree` refuses, which is why #0027 snapshots the
    /// index file as a blob instead.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func conflictedFixtureLeavesAnUnmergedIndex(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.conflicted(refFormat: format)
        defer { repo.destroy() }
        #expect(repo.hasConflicts, "expected an unmerged index")

        let writeTree = try GitProcess().capture(["write-tree"], workingDirectory: repo.url.path)
        #expect(writeTree.exitCode != 0, "git write-tree should refuse an unmerged index")
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func emptyRepositoryHasNoCommits(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        let head = try GitProcess().capture(["rev-parse", "--verify", "HEAD"],
                                            workingDirectory: repo.url.path)
        #expect(head.exitCode != 0, "a fresh repository has no HEAD commit")
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func detachedHeadIsDetached(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])
        try repo.checkoutDetached(try #require(repo.oids["a"]))

        let symbolic = try GitProcess().capture(["symbolic-ref", "-q", "HEAD"],
                                                workingDirectory: repo.url.path)
        #expect(symbolic.exitCode != 0, "detached HEAD should not resolve symbolically")
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func untrackedFilesAreNotStaged(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])
        try repo.writeUntracked(["loose.txt": "not staged\n"])

        let status = try GitProcess().run(["status", "--porcelain"],
                                          workingDirectory: repo.url.path)
        #expect(status.lines.contains { $0.hasPrefix("??") })
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func linkedWorktreeSharesTheCommonDir(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])
        let wt = try repo.addWorktree(named: "agent-a", branch: "agent-a")
        defer { try? FileManager.default.removeItem(at: wt) }

        let main = try WorktreeContext.resolve(path: repo.url.path)
        let linked = try WorktreeContext.resolve(path: wt.path)
        #expect(linked.isLinkedWorktree)
        #expect(linked.commonDir == main.commonDir)
    }

    /// A snapshot taken mid-rebase must capture the sequencer state or the
    /// rebase cannot be resumed after restore (#0035).
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func interruptedRebaseLeavesSequencerState(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"),
                        FixtureRepository.Commit("b"),
                        FixtureRepository.Commit("c")])
        try repo.beginInterruptedRebase(onto: try #require(repo.oids["a"]))
        #expect(repo.isMidRebase, "expected rebase-merge or rebase-apply to exist")
    }

    // MARK: - The two rules the harness must not break

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func fixtureUsesItsOwnIdentityNotTheUsers(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let email = try GitProcess().run(["log", "-1", "--format=%ae"],
                                         workingDirectory: repo.url.path).lines[0]
        #expect(email == "fixture@example.invalid",
                "fixtures must not commit as the real user")

        let signing = try GitProcess().run(["config", "commit.gpgsign"],
                                           workingDirectory: repo.url.path).lines[0]
        #expect(signing == "false", "fixtures must never attempt to sign with a real key")
    }

    @Test func refFormatIsWhatWasAsked() throws {
        for format in Self.formats {
            let repo = try FixtureRepository(refFormat: format)
            defer { repo.destroy() }
            let actual = try GitProcess().run(["rev-parse", "--show-ref-format"],
                                              workingDirectory: repo.url.path).lines[0]
            #expect(actual == format.rawValue)
        }
    }

    @Test func destroyRemovesTheDirectory() throws {
        let repo = try FixtureRepository()
        let path = repo.url.path
        #expect(FileManager.default.fileExists(atPath: path))
        repo.destroy()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func unknownParentIsAClearError() throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }
        #expect(throws: FixtureRepository.Error.self) {
            try repo.build([FixtureRepository.Commit("x", parents: ["nope"])])
        }
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func commitWithEmbeddedDelimiterInBodyRoundTripsThroughLog(format: FixtureRepository.RefFormat) throws {
        let soH = "\u{01}"
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        let body = "has \(soH) delimiter inside\n\nbody paragraph"
        try repo.build([FixtureRepository.Commit("x", message: body)])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        let entry = try #require(entries.first(where: { $0.oid == repo.oids["x"] }))
        // git's `commit -m` appends a trailing newline to the message stored in the object store;
        // CommitLog must preserve whatever git actually wrote, not what was originally supplied.
        #expect(entry.message == body + "\n")
    }
}
