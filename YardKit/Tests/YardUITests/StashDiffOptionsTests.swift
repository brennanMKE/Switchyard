// StashDiffOptionsTests.swift — the stash detail pane's diff drawn with
// diff options (#0541, guide §11 decision 42)

import Testing
@testable import YardGit
@testable import YardUI

@Test(arguments: FixtureRepository.RefFormat.supported())
func loadStashDiffDrawsTheStashWithTheOptions(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\n", "ws.txt": "y\n"])])
    try repo.writeUntracked(["a.txt": "a\nmore\n", "ws.txt": "y  \n"])
    try await GitProcess().run(["stash", "push", "-q"], workingDirectory: repo.url.path)
    let oid = try repo.revParse("refs/stash")

    let full = try await loadStashDiff(at: repo.url.path, oid: oid)
    let shown = try await loadStashDiff(
        at: repo.url.path, oid: oid, options: DiffViewOptions(ignoresWhitespace: true).diffOptions)

    #expect(full.map(\.path) == ["a.txt", "ws.txt"])
    #expect(full.map { DiffViewOptions.file($0, in: shown)?.path } == ["a.txt", nil],
            "the pane draws a.txt and notes ws.txt")
}
