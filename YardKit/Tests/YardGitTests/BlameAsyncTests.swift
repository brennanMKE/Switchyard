// BlameAsyncTests.swift — the async `blameFile` twin (#0515)

import Foundation
import Testing
@testable import YardGit

/// `base` writes three lines; `edit` changes the middle one.
private func editedRepo() throws -> FixtureRepository {
    var repo = try FixtureRepository()
    try repo.build([
        .init("base", files: ["f.txt": "one\ntwo\nthree\n"]),
        .init("edit", files: ["f.txt": "one\nTWO\nthree\n"]),
    ])
    return repo
}

/// The synchronous overload. An async context resolves an unawaited
/// `blameFile` call to the async twin and refuses it (`expression is 'async'
/// but is not marked with 'await'`), so the synchronous call lives in a
/// synchronous function.
private func synchronousBlame(_ path: String) throws -> [BlameLine] {
    try blameFile(at: path, file: "f.txt")
}

@Test func theAsyncTwinBlamesWhatTheSynchronousOneDoes() async throws {
    let repo = try editedRepo()
    defer { repo.destroy() }
    let base = try #require(repo.oids["base"])
    let edit = try #require(repo.oids["edit"])

    let lines: [BlameLine] = try await blameFile(at: repo.url.path, file: "f.txt")

    #expect(lines.map(\.oid) == [base, edit, base])
    #expect(lines.map(\.content) == ["one", "TWO", "three"])
    #expect(lines == (try synchronousBlame(repo.url.path)))
}

@Test func theAsyncTwinBlamesAtARevision() async throws {
    let repo = try editedRepo()
    defer { repo.destroy() }
    let base = try #require(repo.oids["base"])

    let lines: [BlameLine] = try await blameFile(at: repo.url.path, file: "f.txt", revision: base)

    #expect(lines.map(\.oid) == [base, base, base])
    #expect(lines.map(\.content) == ["one", "two", "three"])
}

/// The point of the twin: a cancelled blame stops instead of finishing.
/// The task waits until it has been cancelled before it starts the blame,
/// so the outcome does not depend on timing.
@Test func aCancelledBlameThrowsCancellation() async throws {
    let repo = try editedRepo()
    defer { repo.destroy() }
    let path = repo.url.path

    let task = Task { () async throws -> [BlameLine] in
        while !Task.isCancelled { await Task.yield() }
        return try await blameFile(at: path, file: "f.txt")
    }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
}
