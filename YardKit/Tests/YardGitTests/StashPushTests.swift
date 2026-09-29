// StashPushTests.swift — list and Stash Changes, journaled (#0491)

import Foundation
import Testing
@testable import YardGit

private func read(_ path: String, in repo: FixtureRepository) -> String? {
    try? String(contentsOf: repo.url.appendingPathComponent(path), encoding: .utf8)
}

/// `git status --porcelain=v2`'s XY per path; untracked reads `"??"`.
private func xy(in repo: FixtureRepository) throws -> [String: String] {
    Dictionary(uniqueKeysWithValues: try gitStatus(at: repo.url.path).entries.map {
        ($0.path, $0.worktree == .untracked ? "??" : "\($0.staged.rawValue)\($0.worktree.rawValue)")
    })
}

/// One commit holding `a.txt` and `b.txt`; then `a.txt` edited and
/// staged, `b.txt` edited and not staged, `new.txt` untracked.
private func dirtyRepo(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["a.txt": "a\n", "b.txt": "b\n"])])
    try repo.writeUntracked(["a.txt": "a\nstaged\n", "b.txt": "b\nunstaged\n", "new.txt": "new\n"])
    try GitProcess().run(["add", "a.txt"], workingDirectory: repo.url.path)
    return repo
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func pushSavesStagedAndUnstagedChangesAndCleansTheTree(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }

    try Stash.push(message: "work in progress", includeUntracked: false, at: repo.url.path)

    let items = try Stash.list(at: repo.url.path)
    #expect(items.count == 1)
    #expect(items.first?.message == "On main: work in progress")
    #expect(items.first?.includesUntracked == false)
    #expect(items.first?.baseOID == (try repo.revParse("HEAD")))
    #expect(items.first?.name == "stash@{0}")
    #expect(try xy(in: repo) == ["new.txt": "??"], "without -u the untracked file stays")
    #expect(read("a.txt", in: repo) == "a\n")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func pushWithIncludeUntrackedTakesTheUntrackedFileToo(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }

    try Stash.push(message: nil, includeUntracked: true, at: repo.url.path)

    #expect(try xy(in: repo).isEmpty)
    #expect(read("new.txt", in: repo) == nil)
    let item = try #require(try Stash.list(at: repo.url.path).first)
    #expect(item.includesUntracked)
    #expect(item.message.hasPrefix("WIP on main: "), "no message: git names the stash after HEAD")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func pushWorksOnADetachedHead(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }
    try repo.checkoutDetached(try repo.revParse("HEAD"))

    try Stash.push(message: "detached", includeUntracked: false, at: repo.url.path)

    #expect(try Stash.list(at: repo.url.path).first?.message == "On (no branch): detached")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func undoStashChangesPutsTheChangesBackAndRemovesTheStash(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let before = try xy(in: repo)
    let entries = try JournalAnchor.list(in: ctx).count

    try Stash.push(message: "undo me", includeUntracked: true, at: repo.url.path)
    #expect(try JournalAnchor.list(in: ctx).count == entries + 1, "one entry per stash")

    try JournalUndo.undo(in: ctx)

    #expect(try xy(in: repo) == before, "staged stays staged, untracked comes back")
    #expect(read("b.txt", in: repo) == "b\nunstaged\n")
    #expect(try Stash.list(at: repo.url.path).isEmpty)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func pushRefusesWhenOnlyUntrackedFilesAndNoIncludeUntracked(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\n"])])
    try repo.writeUntracked(["new.txt": "new\n"])
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let entries = try JournalAnchor.list(in: ctx).count

    // git itself exits 0 here with "No local changes to save".
    #expect(throws: Stash.Refusal.nothingToStash) {
        try Stash.push(message: nil, includeUntracked: false, at: repo.url.path)
    }
    #expect(try JournalAnchor.list(in: ctx).count == entries, "a refusal writes no entry")

    try Stash.push(message: nil, includeUntracked: true, at: repo.url.path)
    #expect(try Stash.list(at: repo.url.path).count == 1)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func pushRefusesOnABranchWithNoCommits(format: FixtureRepository.RefFormat) throws {
    let repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.writeUntracked(["a.txt": "a\n"])
    try GitProcess().run(["add", "a.txt"], workingDirectory: repo.url.path)

    #expect(throws: Stash.Refusal.noCommits) {
        try Stash.push(message: nil, includeUntracked: false, at: repo.url.path)
    }
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func pushRefusesAnIntentToAddFile(format: FixtureRepository.RefFormat) throws {
    let repo = try dirtyRepo(format)
    defer { repo.destroy() }
    try GitProcess().run(["add", "-N", "new.txt"], workingDirectory: repo.url.path)

    #expect(throws: Stash.Refusal.intentToAdd(path: "new.txt")) {
        try Stash.push(message: nil, includeUntracked: false, at: repo.url.path)
    }
}

@Test
func parseListReadsParentsDateAndMessage() throws {
    let w = String(repeating: "a", count: 40)
    let b = String(repeating: "b", count: 40)
    let i = String(repeating: "c", count: 40)
    let u = String(repeating: "d", count: 40)
    let text = "\(w)\0\(b) \(i) \(u)\01700000000\0On main: two words\n"
        + "\(b)\0\(b) \(i)\01600000000\0WIP on main: bbbbbbb base\n"

    let items = try Stash.parseList(text)

    #expect(items == [
        .init(index: 0, oid: w, baseOID: b, includesUntracked: true, date: 1_700_000_000,
              message: "On main: two words"),
        .init(index: 1, oid: b, baseOID: b, includesUntracked: false, date: 1_600_000_000,
              message: "WIP on main: bbbbbbb base"),
    ])
}
