// CommitDiffOptionsTests.swift — the commit changes window's diff drawn with
// diff options (#0540, guide §11 decision 42)

import Testing
@testable import YardGit
@testable import YardUI

@Test(arguments: FixtureRepository.RefFormat.supported())
func loadCommitDiffDrawsTheCommitWithTheOptions(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([
        .init("base", files: ["a.txt": "a\n", "ws.txt": "y\n"]),
        .init("both", files: ["a.txt": "A\n", "ws.txt": "\ty\n"]),
    ])

    let full = try await loadCommitDiff(at: repo.url.path, revision: "HEAD")
    let shown = try await loadCommitDiff(
        at: repo.url.path, revision: "HEAD", options: DiffViewOptions(ignoresWhitespace: true).diffOptions)

    #expect(full.map(\.path) == ["a.txt", "ws.txt"])
    #expect(shown.map(\.path) == ["a.txt"])
    #expect(full.map { DiffViewOptions.file($0, in: shown)?.path } == ["a.txt", nil],
            "the window draws a.txt and notes ws.txt")
}
