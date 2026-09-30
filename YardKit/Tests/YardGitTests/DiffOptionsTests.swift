// DiffOptionsTests.swift — diffs drawn with whitespace ignored or more
// context, for display only (#0535, guide §11 decision 42)

import Foundation
import Testing
@testable import YardGit

private let ignoringWhitespace = DiffOptions(ignoresWhitespace: true)

@Test(arguments: FixtureRepository.RefFormat.supported())
func ignoringWhitespaceShowsANewlyIndentedLineAsContext(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "setup\nfoo();\nbar();\n"])])
    try repo.writeUntracked(["a.txt": "setup\nif ready {\n    foo();\n}\nbar();\n"])

    let shown = try await listHunks(at: repo.url.path, area: .unstaged, options: ignoringWhitespace)
    let pinned = try await listHunks(at: repo.url.path, area: .unstaged)

    #expect(shown.first?.hunks.map(\.body) == [[" setup", "+if ready {", "     foo();", "+}", " bar();"]],
            "-w: the re-indented line is context, printed as it is now")
    #expect(pinned.first?.hunks.map(\.body) == [[" setup", "-foo();", "+if ready {", "+    foo();", "+}", " bar();"]])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func ignoringWhitespaceLeavesOutAFileWhoseOnlyChangeIsWhitespace(
    format: FixtureRepository.RefFormat
) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\nb\n", "ws.txt": "y\n"])])
    try repo.writeUntracked(["a.txt": "a\nB\n", "ws.txt": "  y\t\n"])
    try await GitProcess().run(["add", "-A"], workingDirectory: repo.url.path)

    let shown = try await listHunks(at: repo.url.path, area: .staged, options: ignoringWhitespace)
    let pinned = try await listHunks(at: repo.url.path, area: .staged)

    #expect(shown.map(\.path) == ["a.txt"])
    #expect(pinned.map(\.path) == ["a.txt", "ws.txt"])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func contextLinesOverrideThePinnedThree(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    let lines = (1...40).map(String.init)
    try repo.build([.init("base", files: ["n.txt": lines.joined(separator: "\n") + "\n"])])
    var edited = lines
    edited[19] = "twenty"
    try repo.writeUntracked(["n.txt": edited.joined(separator: "\n") + "\n"])

    let three = try await listHunks(at: repo.url.path, area: .unstaged)
    let ten = try await listHunks(at: repo.url.path, area: .unstaged, options: DiffOptions(contextLines: 10))
    let whole = try await listHunks(
        at: repo.url.path, area: .unstaged, options: DiffOptions(contextLines: DiffOptions.wholeFile))

    #expect(three.first?.hunks.map(\.header) == ["@@ -17,7 +17,7 @@"])
    #expect(ten.first?.hunks.map(\.header) == ["@@ -10,21 +10,21 @@"])
    #expect(whole.first?.hunks.map(\.header) == ["@@ -1,40 +1,40 @@"])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func commitDiffTakesTheOptions(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([
        .init("base", files: ["a.txt": "a\n"]),
        .init("reindent", files: ["a.txt": "    a\n"]),
    ])

    let shown = try await commitDiff(at: repo.url.path, revision: "HEAD", options: ignoringWhitespace)
    let pinned = try await commitDiff(at: repo.url.path, revision: "HEAD")

    #expect(shown.isEmpty, "a whitespace-only commit shows nothing with whitespace ignored")
    #expect(pinned.map(\.path) == ["a.txt"])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func stashDiffTakesTheOptions(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\n", "b.txt": "b\n"])])
    try repo.writeUntracked(["a.txt": "a \n", "b.txt": "b\nmore\n"])
    try await GitProcess().run(["stash", "push", "-q"], workingDirectory: repo.url.path)
    let oid = try repo.revParse("refs/stash")

    let shown = try await stashDiff(at: repo.url.path, oid: oid, options: ignoringWhitespace)
    let pinned = try await stashDiff(at: repo.url.path, oid: oid)

    #expect(shown.map(\.path) == ["b.txt"])
    #expect(pinned.map(\.path) == ["a.txt", "b.txt"])
}

@Test
func standardOptionsAddNoFlags() {
    #expect(DiffOptions.standard.flags.isEmpty, "the pinned vector is unchanged by default")
    #expect(DiffOptions.standard.isStandard)
    #expect(!DiffOptions(ignoresWhitespace: true).isStandard)
    #expect(DiffOptions(contextLines: -1).contextLines == 0)
}

/// Guide §11 decision 42: staging re-lists with the pinned flags alone, so a
/// hunk shown with whitespace ignored is not a hunk it can stage.
@Test(arguments: FixtureRepository.RefFormat.supported())
func aHunkIDFromAWhitespaceIgnoringListingStagesNothing(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "setup\nfoo();\nbar();\n"])])
    try repo.writeUntracked(["a.txt": "setup\nif ready {\n    foo();\n}\nbar();\n"])
    let shown = try await listHunks(at: repo.url.path, area: .unstaged, options: ignoringWhitespace)
    let id = try #require(shown.first?.hunks.first?.id)

    #expect(throws: StagingError.unknownHunkIDs(ids: [id], area: .unstaged)) {
        try stageHunks(ids: [id], at: repo.url.path)
    }
    #expect(try await listHunks(at: repo.url.path, area: .staged).isEmpty, "nothing was staged")
}
