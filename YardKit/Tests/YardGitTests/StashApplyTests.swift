// StashApplyTests.swift — apply, pop and drop a stash, journaled (#0492)

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

/// One commit holding `f.txt` (`a b c`) and `g.txt`; then two stashes,
/// made with plain `git stash push`: `stash@{1}` is `older` (`g.txt`
/// edited), `stash@{0}` is `newer` — `f.txt`'s middle line edited and
/// staged, `new.txt` added and staged. The tree is clean afterwards.
private func stashedRepo(_ format: FixtureRepository.RefFormat) throws -> FixtureRepository {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base", files: ["f.txt": "a\nb\nc\n", "g.txt": "g\n"])])
    let git = GitProcess()
    let path = repo.url.path
    try repo.writeUntracked(["g.txt": "g\nolder\n"])
    try git.run(["stash", "push", "-q", "-m", "older"], workingDirectory: path)
    try repo.writeUntracked(["f.txt": "a\nSTASHED\nc\n", "new.txt": "new\n"])
    try git.run(["add", "f.txt", "new.txt"], workingDirectory: path)
    try git.run(["stash", "push", "-q", "-m", "newer"], workingDirectory: path)
    return repo
}

private func oid(_ index: Int, in repo: FixtureRepository) throws -> String {
    try #require(try Stash.list(at: repo.url.path).first { $0.index == index }).oid
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func applyKeepsTheStashAndBringsStagedChangesBackUnstaged(format: FixtureRepository.RefFormat) throws {
    let repo = try stashedRepo(format)
    defer { repo.destroy() }

    let outcome = try Stash.apply(oid: try oid(0, in: repo), at: repo.url.path)

    #expect(outcome == .applied)
    #expect(try xy(in: repo) == ["f.txt": ".M", "new.txt": "A."])
    #expect(read("f.txt", in: repo) == "a\nSTASHED\nc\n")
    #expect(try Stash.list(at: repo.url.path).count == 2, "apply keeps the stash")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func applyWithRestoreIndexKeepsStagedChangesStaged(format: FixtureRepository.RefFormat) throws {
    let repo = try stashedRepo(format)
    defer { repo.destroy() }

    try Stash.apply(oid: try oid(0, in: repo), restoreIndex: true, at: repo.url.path)

    #expect(try xy(in: repo) == ["f.txt": "M.", "new.txt": "A."])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func popAppliesAndDropsTheStashItNamesNotTheTop(format: FixtureRepository.RefFormat) throws {
    let repo = try stashedRepo(format)
    defer { repo.destroy() }
    let newer = try oid(0, in: repo)

    let outcome = try Stash.pop(oid: try oid(1, in: repo), at: repo.url.path)

    #expect(outcome == .applied)
    #expect(read("g.txt", in: repo) == "g\nolder\n")
    #expect(try Stash.list(at: repo.url.path).map(\.oid) == [newer])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func undoPopPutsTheStashAndTheTreeBack(format: FixtureRepository.RefFormat) throws {
    let repo = try stashedRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let listBefore = try Stash.list(at: repo.url.path)
    let entries = try JournalAnchor.list(in: ctx).count

    try Stash.pop(oid: listBefore[0].oid, at: repo.url.path)
    #expect(try JournalAnchor.list(in: ctx).count == entries + 1, "apply and drop are one entry")

    try JournalUndo.undo(in: ctx)

    #expect(try Stash.list(at: repo.url.path) == listBefore)
    #expect(try xy(in: repo).isEmpty)
    #expect(read("new.txt", in: repo) == nil)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func dropRemovesTheStashItNamesAndUndoDropBringsItBack(format: FixtureRepository.RefFormat) throws {
    let repo = try stashedRepo(format)
    defer { repo.destroy() }
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let listBefore = try Stash.list(at: repo.url.path)

    try Stash.drop(oid: listBefore[1].oid, at: repo.url.path)
    #expect(try Stash.list(at: repo.url.path).map(\.message) == ["On main: newer"])

    try JournalUndo.undo(in: ctx)

    #expect(try Stash.list(at: repo.url.path).map(\.message) == ["On main: newer", "On main: older"])
    #expect(try Stash.list(at: repo.url.path).map(\.oid) == listBefore.map(\.oid))
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func aConflictingPopKeepsTheStashAndReportsTheConflict(format: FixtureRepository.RefFormat) throws {
    let repo = try stashedRepo(format)
    defer { repo.destroy() }
    let newer = try oid(0, in: repo)
    try repo.writeUntracked(["f.txt": "a\nCOMMITTED\nc\n"])
    try GitProcess().run(["commit", "-q", "-am", "moves f.txt"], workingDirectory: repo.url.path)

    let outcome = try Stash.pop(oid: newer, at: repo.url.path)

    #expect(outcome == .conflicted(paths: ["f.txt"]))
    #expect(try Stash.list(at: repo.url.path).first?.oid == newer, "git keeps the stash on a conflict")
    #expect(try gitStatus(at: repo.url.path).entries.first { $0.path == "f.txt" }?.staged == .conflicted)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func applyOverLocalChangesToTheSameFileThrowsGitsRefusal(format: FixtureRepository.RefFormat) throws {
    let repo = try stashedRepo(format)
    defer { repo.destroy() }
    try repo.writeUntracked(["f.txt": "a\nb\nc\nlocal\n"])

    let failure = try #require(throws: GitProcess.Failure.self) {
        try Stash.apply(oid: try oid(0, in: repo), at: repo.url.path)
    }
    guard case let .exited(_, stderr, _) = failure else {
        Issue.record("not a git exit: \(failure)")
        return
    }
    #expect(stderr.contains("would be overwritten"))
    #expect(read("f.txt", in: repo) == "a\nb\nc\nlocal\n", "git changed nothing")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func applyRefusesWhileTheIndexHasConflicts(format: FixtureRepository.RefFormat) throws {
    let repo = try stashedRepo(format)
    defer { repo.destroy() }
    let newer = try oid(0, in: repo)
    try repo.writeUntracked(["f.txt": "a\nCOMMITTED\nc\n"])
    try GitProcess().run(["commit", "-q", "-am", "moves f.txt"], workingDirectory: repo.url.path)
    try Stash.apply(oid: newer, at: repo.url.path)
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    let entries = try JournalAnchor.list(in: ctx).count

    #expect(throws: Stash.Refusal.conflicted) {
        try Stash.apply(oid: try oid(1, in: repo), at: repo.url.path)
    }
    #expect(try JournalAnchor.list(in: ctx).count == entries)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func aStashThatIsNoLongerListedIsRefused(format: FixtureRepository.RefFormat) throws {
    let repo = try stashedRepo(format)
    defer { repo.destroy() }
    let newer = try oid(0, in: repo)
    try GitProcess().run(["stash", "drop", "-q"], workingDirectory: repo.url.path)

    #expect(throws: Stash.Refusal.notFound(oid: newer)) {
        try Stash.drop(oid: newer, at: repo.url.path)
    }
    #expect(try Stash.list(at: repo.url.path).count == 1, "the neighbour was not dropped instead")
}
