// WorkingDiffOptionsTests.swift — the Changes view's diffs drawn with diff
// options (#0539, guide §11 decision 42)

import Testing
@testable import YardGit
@testable import YardUI

@Test(arguments: FixtureRepository.RefFormat.supported())
func loadWorkingDiffsDrawsBothSidesWithTheOptions(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "setup\nfoo();\nbar();\n", "ws.txt": "y\n"])])
    try repo.writeUntracked(["ws.txt": "  y\n"])
    try await GitProcess().run(["add", "ws.txt"], workingDirectory: repo.url.path)
    try repo.writeUntracked(["a.txt": "setup\nif ready {\n    foo();\n}\nbar();\n"])

    let shown = try await loadWorkingDiffs(at: repo.url.path, options: DiffOptions(ignoresWhitespace: true))
    let pinned = try await loadWorkingDiffs(at: repo.url.path)

    #expect(shown.file("a.txt", staged: false)?.hunks.first?.body.contains("-foo();") == false,
            "the unstaged side is drawn with whitespace ignored")
    #expect(pinned.file("a.txt", staged: false)?.hunks.first?.body.contains("-foo();") == true)
    #expect(shown.staged.isEmpty, "the staged side is drawn with whitespace ignored")
    #expect(pinned.staged.map(\.path) == ["ws.txt"])
}
