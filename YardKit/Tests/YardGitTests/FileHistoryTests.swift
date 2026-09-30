// FileHistoryTests.swift — one file's commits, following renames (#0514)

import Foundation
import Testing
@testable import YardGit

/// `one` adds f.txt, `rename` moves it to g.txt, `three` edits g.txt, and
/// `other` touches only other.txt.
private func renamedFileRepo(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("one", files: ["f.txt": "a\nb\n"])])
    let git = GitProcess()
    try git.run(["mv", "f.txt", "g.txt"], workingDirectory: repo.url.path)
    try git.run(["commit", "-q", "-m", "rename"], workingDirectory: repo.url.path)
    try repo.build([
        .init("three", files: ["g.txt": "a\nb\nc\n"]),
        .init("other", files: ["other.txt": "x\n"]),
    ])
    return repo
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func historyFollowsTheFileAcrossARename(format: FixtureRepository.RefFormat) async throws {
    let repo = try renamedFileRepo(format)
    defer { repo.destroy() }

    let entries = try await FileHistory.run(path: repo.url.path, file: "g.txt")

    #expect(entries.map(\.subject) == ["three", "rename", "one"],
            "newest first, the pre-rename commit included, `other` left out")
    #expect(entries.map(\.status) == ["M", "R", "A"])
    #expect(entries.map(\.path) == ["g.txt", "g.txt", "f.txt"])
    #expect(entries.map(\.previousPath) == [nil, "f.txt", nil])
    #expect(entries[0].oid == repo.oids["three"])
    #expect(entries[2].oid == repo.oids["one"])
    #expect(entries.allSatisfy { $0.author == "Fixture" && $0.authorTime > 0 })
}

@Test func historyFromADeletingCommitStartsWithTheDeletion() async throws {
    var repo = try renamedFileRepo(.files)
    defer { repo.destroy() }
    try await GitProcess().run(["rm", "-q", "g.txt"], workingDirectory: repo.url.path)
    try repo.build([.init("gone", message: "delete g")])
    let gone = try #require(repo.oids["gone"])

    let entries = try await FileHistory.run(path: repo.url.path, file: "g.txt", revision: gone)

    #expect(entries.map(\.subject) == ["delete g", "three", "rename", "one"])
    #expect(entries[0].isDeletion)
    #expect(entries[0].path == "g.txt")
    #expect(!entries[1].isDeletion)
}

@Test func aRevisionBeforeTheFileExistedHasNoHistory() async throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\n"]), .init("later", files: ["b.txt": "b\n"])])
    let base = try #require(repo.oids["base"])

    #expect(try await FileHistory.run(path: repo.url.path, file: "b.txt", revision: base).isEmpty)
    #expect(try await FileHistory.run(path: repo.url.path, file: "b.txt").count == 1)
}

/// `-z` keeps a non-ASCII name raw; without it, `core.quotepath`'s default
/// C-quotes it (`"na\303\257ve.txt"`) and the path would not match.
@Test func aNonASCIIPathComesBackRaw() async throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["naïve.txt": "a\n"])])

    let entries = try await FileHistory.run(path: repo.url.path, file: "naïve.txt")

    #expect(entries.map(\.path) == ["naïve.txt"])
}

@Test func theParserReadsRenamesAndSubjectsWithSeparators() throws {
    let a = String(repeating: "a", count: 40)
    let b = String(repeating: "b", count: 40)
    let text = "\(a)\u{01}Ann\u{01}100\u{01}move\u{01}it\0\nR100\0old name\0new\tname\0"
        + "\(b)\u{01}Bo\u{01}50\u{01}add\0\nA\0old name\0"
    let entries = try FileHistory.parse(text)
    #expect(entries == [
        .init(oid: a, author: "Ann", authorTime: 100, subject: "move\u{01}it",
              status: "R", path: "new\tname", previousPath: "old name"),
        .init(oid: b, author: "Bo", authorTime: 50, subject: "add",
              status: "A", path: "old name", previousPath: nil),
    ])
    #expect(try FileHistory.parse("").isEmpty)
}

@Test func aRecordWithoutAStatusIsRefused() {
    let a = String(repeating: "a", count: 40)
    #expect(throws: FileHistory.Failure.malformedRecord("\(a)\u{01}Ann\u{01}100\u{01}merge")) {
        try FileHistory.parse("\(a)\u{01}Ann\u{01}100\u{01}merge\0")
    }
    #expect(throws: FileHistory.Failure.malformedRecord("not a record")) {
        try FileHistory.parse("not a record\0\nM\0f.txt\0")
    }
}
