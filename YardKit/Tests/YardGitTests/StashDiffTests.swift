// StashDiffTests.swift — what a stash holds, for the detail pane (#0493)

import Foundation
import Testing
@testable import YardGit

@Test(arguments: FixtureRepository.RefFormat.supported())
func stashDiffShowsTrackedChangesThenUntrackedFiles(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\n", "b.txt": "b\n"])])
    try repo.writeUntracked(["a.txt": "a\nstaged\n", "b.txt": "b\nunstaged\n", "new.txt": "new\n"])
    try await GitProcess().run(["add", "a.txt"], workingDirectory: repo.url.path)
    try await GitProcess().run(["stash", "push", "-q", "-u"], workingDirectory: repo.url.path)
    let oid = try repo.revParse("refs/stash")

    let files = try await stashDiff(at: repo.url.path, oid: oid)

    #expect(files.map(\.path) == ["a.txt", "b.txt", "new.txt"])
    try #require(files.count == 3)
    #expect(files[0].hunks.first?.body == [" a", "+staged"], "the staged change is in the stash's diff")
    #expect(files[1].hunks.first?.body == [" b", "+unstaged"])
    #expect(files[2].oldMode == nil, "an untracked file is shown as new")
    #expect(files[2].hunks.first?.body == ["+new"])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func stashDiffOfAStashWithNoUntrackedCommitIsTheTrackedHalfOnly(
    format: FixtureRepository.RefFormat
) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\n"])])
    try repo.writeUntracked(["a.txt": "a\nmore\n", "new.txt": "new\n"])
    try await GitProcess().run(["stash", "push", "-q"], workingDirectory: repo.url.path)

    let files = try await stashDiff(at: repo.url.path, oid: try repo.revParse("refs/stash"))

    #expect(files.map(\.path) == ["a.txt"])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func stashDiffIsAgainstTheStashBaseNotHead(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\n"])])
    try repo.writeUntracked(["a.txt": "a\nstashed\n"])
    try await GitProcess().run(["stash", "push", "-q"], workingDirectory: repo.url.path)
    try repo.writeUntracked(["later.txt": "later\n"])
    try await GitProcess().run(["add", "later.txt"], workingDirectory: repo.url.path)
    try await GitProcess().run(["commit", "-q", "-m", "later"], workingDirectory: repo.url.path)

    let files = try await stashDiff(at: repo.url.path, oid: try repo.revParse("refs/stash"))

    #expect(files.map(\.path) == ["a.txt"], "a commit made after the stash is not part of it")
}
