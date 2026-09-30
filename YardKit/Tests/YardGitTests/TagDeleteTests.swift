// TagDeleteTests.swift — Delete Tag…, journaled (guide §11 decision 38)

import Foundation
import Testing
@testable import YardGit

private let git = GitProcess()

private func tagShape(_ name: String, in repo: FixtureRepository) throws -> String? {
    try git.run(
        ["for-each-ref", "--format=%(objectname) %(objecttype)", "refs/tags/\(name)"],
        workingDirectory: repo.url.path
    ).lines.first
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func deleteTagRemovesALightweightAndAnAnnotatedTagAndUndoRestoresThem(
    format: FixtureRepository.RefFormat
) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("c1")])
    try git.run(["tag", "light"], workingDirectory: repo.url.path)
    try git.run(["tag", "-a", "-m", "notes", "heavy"], workingDirectory: repo.url.path)
    let light = try #require(try tagShape("light", in: repo))
    let heavy = try #require(try tagShape("heavy", in: repo))
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let entries = try JournalAnchor.list(in: ctx).count

    let removedLight = try Tag.delete(name: "light", at: repo.url.path)
    let removedHeavy = try Tag.delete(name: "heavy", at: repo.url.path)

    #expect(removedLight == .init(ref: "refs/tags/light", oid: try repo.revParse("HEAD"), annotated: false))
    #expect(removedHeavy.annotated)
    #expect(try tagShape("light", in: repo) == nil)
    #expect(try tagShape("heavy", in: repo) == nil)
    #expect(try JournalAnchor.list(in: ctx).count == entries + 2, "one entry per delete")

    try JournalUndo.undo(in: ctx)
    #expect(try tagShape("heavy", in: repo) == heavy, "the annotated tag object comes back")
    try JournalUndo.undo(in: ctx)
    #expect(try tagShape("light", in: repo) == light)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func deleteTagRefusesAnUnknownTagAndWritesNothing(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("c1")])
    try git.run(["tag", "v1.0"], workingDirectory: repo.url.path)
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let entries = try JournalAnchor.list(in: ctx).count

    #expect(throws: RefManageError.unknownTag("v1")) {
        try Tag.delete(name: "v1", at: repo.url.path)
    }
    #expect(try JournalAnchor.list(in: ctx).count == entries)
    #expect(try tagShape("v1.0", in: repo) != nil)
}
