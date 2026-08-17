// CommitHunksTests.swift — commit a named hunk set (#0208)
//
// NO SIGNING KEY IS CREATED OR USED ANYWHERE IN THIS FILE. `commitHunks`
// composes `stageHunks` (#0040) with `CommitCreate.run` (#0036/#0038); every
// test here commits unsigned, through the hermetic environment CommitCreate's
// own tests use.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

// MARK: - Fixture helpers (same two-hunk shape StagingTests measures)

/// `line 01` … `line 20`, one per line, trailing newline.
private func base20() -> String {
    (1...20).map { String(format: "line %02d", $0) }.joined(separator: "\n") + "\n"
}

/// A line inserted after `line 03`, and `line 17` replaced — far enough apart
/// that git keeps them as two hunks at -U3. The insertion is the earlier
/// hunk in listing order; the replacement is the later one.
private func edited20() -> String {
    var lines = (1...20).map { String(format: "line %02d", $0) }
    lines[16] = "line 17 CHANGED"
    lines.insert("inserted after 03", at: 3)
    return lines.joined(separator: "\n") + "\n"
}

private func twoHunkRepo(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["f.txt": base20()])])
    try repo.writeUntracked(["f.txt": edited20()])
    return repo
}

/// The hunks of the one changed file, in listing order.
private func listedHunks(in repo: FixtureRepository, area: DiffArea) throws -> [Hunk] {
    try listHunks(at: repo.url.path, area: area).flatMap(\.hunks)
}

/// `git diff --cached --name-only`, the same probe `commitHunks` uses.
private func stagedPaths(in repo: FixtureRepository) throws -> [String] {
    try GitProcess().run(
        ["diff", "--cached", "--name-only"], workingDirectory: repo.url.path
    ).lines
}

// MARK: - The named hunk is committed; the other is left alone

@Test(arguments: FixtureRepository.RefFormat.supported())
func commitsOnlyTheNamedHunkLeavingTheOtherUnstagedAndUncommitted(
    format: FixtureRepository.RefFormat
) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }
    let before = try listedHunks(in: repo, area: .unstaged)
    let first = try #require(before.first)
    let second = try #require(before.last)
    #expect(first.id != second.id)

    let result = try commitHunks(
        ids: [first.id], message: "commit first hunk only",
        at: repo.url.path, extraEnvironment: hermetic)

    // By content, not merely by count: the second hunk's change never
    // reached HEAD, and the first hunk's change did.
    let headContent = try GitProcess().run(
        ["show", "HEAD:f.txt"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).text
    #expect(headContent.contains("inserted after 03"))
    #expect(!headContent.contains("line 17 CHANGED"))
    #expect(result.oid == (try repo.revParse("HEAD")))

    // The other hunk is still there, unstaged, by content — not committed
    // and not left sitting in the index either.
    let unstaged = try listedHunks(in: repo, area: .unstaged)
    #expect(unstaged.map(\.id) == [second.id])
    let staged = try listedHunks(in: repo, area: .staged)
    #expect(staged.isEmpty)
}

// MARK: - The staged-work refusal this issue exists to pin (#0208 Decision)

@Test(arguments: FixtureRepository.RefFormat.supported())
func refusesWhenUnrelatedWorkIsAlreadyStagedAndNamesThePath(
    format: FixtureRepository.RefFormat
) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }
    try repo.writeUntracked(["unrelated.txt": "unrelated content\n"])
    try GitProcess().run(["add", "unrelated.txt"], workingDirectory: repo.url.path)
    let baseHead = try repo.revParse("HEAD")

    let first = try #require(try listedHunks(in: repo, area: .unstaged).first)

    let error = try #require(throws: CommitHunksError.self) {
        _ = try commitHunks(
            ids: [first.id], message: "must not commit",
            at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(error == .indexNotClean(paths: ["unrelated.txt"]))

    // Nothing moved: HEAD unchanged, the named hunk was never staged, and
    // the caller's unrelated work is exactly as they left it.
    #expect(try repo.revParse("HEAD") == baseHead)
    #expect(try stagedPaths(in: repo) == ["unrelated.txt"])
    let unstaged = try listedHunks(in: repo, area: .unstaged)
    #expect(unstaged.count == 2)
}

@Test func commitHunksErrorMapsToRepositoryError() {
    let error = CommitHunksError.indexNotClean(paths: ["a.txt"])
    #expect(error.exitClass == .repositoryError)
}

// MARK: - Mutation, observed: an unknown id stages nothing and commits nothing

@Test(arguments: FixtureRepository.RefFormat.supported())
func unknownHunkIdCommitsNothingAndStagesNothing(format: FixtureRepository.RefFormat) throws {
    let repo = try twoHunkRepo(format)
    defer { repo.destroy() }
    let baseHead = try repo.revParse("HEAD")
    let bogus = "000000000000"

    #expect(throws: StagingError.self) {
        _ = try commitHunks(
            ids: [bogus], message: "must not commit",
            at: repo.url.path, extraEnvironment: hermetic)
    }

    // stageHunks throws before applying (#0040): nothing was staged, so HEAD
    // never moved and both hunks are still unstaged.
    #expect(try repo.revParse("HEAD") == baseHead)
    let staged = try listedHunks(in: repo, area: .staged)
    #expect(staged.isEmpty)
    let unstaged = try listedHunks(in: repo, area: .unstaged)
    #expect(unstaged.count == 2)
}
