// HistorySearchTests.swift — path and content search over given commits (#0522)

import Foundation
import Testing
@testable import YardGit

/// `add` creates Sources/Engine/HistoryFilter.swift; `docs` adds
/// docs/readme.md containing "hello Needle"; `side` (on a branch off `docs`)
/// edits HistoryFilter.swift; `weird` adds `docs/we[ird].txt`; `merge` merges
/// `side` into `weird`; `gone` rewrites readme.md without "Needle".
private func searchRepo(_ format: FixtureRepository.RefFormat = .files) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([
        .init("add", files: ["Sources/Engine/HistoryFilter.swift": "let x = 1\n"]),
        .init("docs", files: ["docs/readme.md": "hello Needle\n"]),
        .init("side", parents: ["docs"], files: ["Sources/Engine/HistoryFilter.swift": "let x = 2\n"]),
        .init("weird", parents: ["docs"], files: ["docs/we[ird].txt": "a[1]\n"]),
        .init("merge", parents: ["weird", "side"], files: ["merge-note.txt": "m\n"]),
        .init("gone", files: ["docs/readme.md": "gone\n"]),
    ])
    return repo
}

/// Every commit, newest first — what the History pane would pass.
private func all(_ repo: FixtureRepository) throws -> [String] {
    try ["gone", "merge", "weird", "side", "docs", "add"].map { try #require(repo.oids[$0]) }
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func aPathSearchFindsTheCommitsThatTouchedAMatchingPath(format: FixtureRepository.RefFormat) async throws {
    let repo = try searchRepo(format)
    defer { repo.destroy() }

    let found = try await HistorySearch.run(
        kind: .path, query: "historyfilter", candidates: try all(repo), at: repo.url.path)

    #expect(found == [repo.oids["side"], repo.oids["add"]].compactMap { $0 },
            "case-insensitive, in the candidates' order")
}

@Test func aPathSearchMatchesADirectoryName() async throws {
    let repo = try searchRepo()
    defer { repo.destroy() }

    let found = try await HistorySearch.run(
        kind: .path, query: "Sources/eng", candidates: try all(repo), at: repo.url.path)

    #expect(found == [repo.oids["side"], repo.oids["add"]].compactMap { $0 })
}

@Test func globCharactersInAPathQueryMatchThemselves() async throws {
    let repo = try searchRepo()
    defer { repo.destroy() }

    let found = try await HistorySearch.run(
        kind: .path, query: "[ird]", candidates: try all(repo), at: repo.url.path)

    #expect(found == [repo.oids["weird"]].compactMap { $0 },
            "unescaped, [ird] is a character class and matches every path with an i, r or d")
}

@Test func aContentSearchFindsTheCommitsThatAddedOrRemovedTheText() async throws {
    let repo = try searchRepo()
    defer { repo.destroy() }

    let found = try await HistorySearch.run(
        kind: .content, query: "needle", candidates: try all(repo), at: repo.url.path)

    #expect(found == [repo.oids["gone"], repo.oids["docs"]].compactMap { $0 },
            "the commit that removed it and the one that added it, case-insensitively")
}

@Test func onlyTheCandidatesAreSearched() async throws {
    let repo = try searchRepo()
    defer { repo.destroy() }
    let gone = try #require(repo.oids["gone"])

    let found = try await HistorySearch.run(
        kind: .content, query: "needle", candidates: [gone], at: repo.url.path)

    #expect(found == [gone], "`docs` also matches, but it was not a candidate")
}

@Test func aBlankQueryOrNoCandidatesFindsNothing() async throws {
    let repo = try searchRepo()
    defer { repo.destroy() }
    let candidates = try all(repo)

    #expect(try await HistorySearch.run(kind: .content, query: "  ", candidates: candidates, at: repo.url.path).isEmpty)
    #expect(try await HistorySearch.run(kind: .path, query: "readme", candidates: [], at: repo.url.path).isEmpty)
    #expect(try await HistorySearch.run(kind: .path, query: "readme", candidates: candidates, at: repo.url.path)
        == [repo.oids["gone"], repo.oids["docs"]].compactMap { $0 },
        "the same query over candidates does find commits")
}

/// `left` and `right` each add a file under engine/ and `merge` joins them,
/// so the merge differs from both parents under engine/: without
/// `--no-merges`, git lists it too — measured.
@Test func aMergeIsNotAMatch() async throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("base", files: ["readme.md": "r\n"]),
        .init("left", parents: ["base"], files: ["engine/left.swift": "l\n"]),
        .init("right", parents: ["base"], files: ["engine/right.swift": "r\n"]),
        .init("merge", parents: ["left", "right"], files: ["note.txt": "m\n"]),
    ])
    let candidates = try ["merge", "right", "left", "base"].map { try #require(repo.oids[$0]) }

    let found = try await HistorySearch.run(
        kind: .path, query: "engine/", candidates: candidates, at: repo.url.path)

    #expect(found == [repo.oids["right"], repo.oids["left"]].compactMap { $0 })
}

/// A rename moves text without adding it. `diff.renames=false` would make
/// the renaming commit a content match for every line of the file.
@Test func aRenameIsNotAContentMatchWhateverDiffRenamesSays() async throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("add", files: ["old.txt": "alpha\ncharlie\n"])])
    try await GitProcess().run(["mv", "old.txt", "new.txt"], workingDirectory: repo.url.path)
    try await GitProcess().run(["commit", "-q", "-m", "rename"], workingDirectory: repo.url.path)
    try await GitProcess().run(["config", "diff.renames", "false"], workingDirectory: repo.url.path)
    let add = try #require(repo.oids["add"])
    let rename = try await GitProcess().run(["rev-parse", "HEAD"], workingDirectory: repo.url.path).lines[0]

    let found = try await HistorySearch.run(
        kind: .content, query: "charlie", candidates: [rename, add], at: repo.url.path)

    #expect(found == [add])
}

@Test func theArgumentsPinTheWalkAndEscapeThePathspec() {
    #expect(HistorySearch.pathspec(for: "a*b?[c]\\d") == ":(icase)*a\\*b\\?\\[c\\]\\\\d*")
    #expect(HistorySearch.arguments(kind: .content, query: "x").suffix(3) == ["-M", "-i", "-Sx"])
    #expect(HistorySearch.arguments(kind: .path, query: "x").contains("--no-merges"))
}
