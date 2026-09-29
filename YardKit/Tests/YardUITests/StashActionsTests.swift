// StashActionsTests.swift — the stash list's data layer (#0495)

import Foundation
import Testing
@testable import YardGit
@testable import YardUI

private func item(_ index: Int, message: String, date: Int = 1_700_000_000) -> Stash.Item {
    Stash.Item(index: index, oid: String(repeating: "\(index)", count: 40),
               baseOID: String(repeating: "b", count: 40), includesUntracked: false,
               date: date, message: message)
}

@Test func aRowShowsTheMessageWithoutGitsOnBranchPrefix() {
    #expect(StashRowText.label(for: item(0, message: "On main: half done")) == "half done")
    #expect(StashRowText.label(for: item(0, message: "On (no branch): detached")) == "detached")
    #expect(StashRowText.label(for: item(0, message: "WIP on main: 1234567 base"))
        == "WIP on main: 1234567 base", "a stash with no message keeps git's whole name")
    #expect(StashRowText.label(for: item(0, message: "On main: a: b")) == "a: b",
            "only the first `: ` is the prefix's")
}

@Test func aRowsCaptionIsItsNameAndItsDate() {
    let now = Date(timeIntervalSince1970: 1_700_000_000 + 7_200)
    let caption = StashRowText.caption(for: item(2, message: "On main: x"), now: now)
    #expect(caption.hasPrefix("stash@{2} · "))
    #expect(caption.contains("2 hours"))
}

@Test func dropAsksFirstAndSaysUndoBringsItBack() {
    let confirmation = StashDropConfirmation(item: item(1, message: "On main: half done"))
    #expect(confirmation.title == "Drop stash “half done”?")
    #expect(confirmation.message
        == "stash@{1} is removed from the stash list. Edit ▸ Undo Drop Stash brings it back.")
    #expect(confirmation.action == .drop(oid: String(repeating: "1", count: 40)))
}

@Test func eachActionHasItsProgressLabelAndAlertTitle() {
    let refusal = Stash.Refusal.notFound(oid: "abcdef0123")
    #expect(StashAction.apply(oid: "a", restoreIndex: false).progressLabel == "Applying stash…")
    #expect(StashAction.pop(oid: "a", restoreIndex: false).progressLabel == "Popping stash…")
    #expect(StashAction.drop(oid: "a").progressLabel == "Dropping stash…")
    #expect(StashAction.apply(oid: "a", restoreIndex: false).failure(for: refusal).title == "Couldn’t Apply Stash")
    #expect(StashAction.pop(oid: "a", restoreIndex: false).failure(for: refusal).title == "Couldn’t Pop Stash")
    let drop = StashAction.drop(oid: "a").failure(for: refusal)
    #expect(drop.title == "Couldn’t Drop Stash")
    #expect(drop.message == refusal.description, "a refusal is its own sentence")
}

@Test func aGitRefusalShowsGitsStderrAndHowToPutThingsBack() {
    let failure = GitProcess.Failure.exited(
        code: 1, stderr: "n.txt already exists, no checkout\n",
        arguments: ["stash", "pop", "-q", "stash@{0}"])
    let pop = StashAction.pop(oid: "a", restoreIndex: false).failure(for: failure)
    #expect(pop.message == "n.txt already exists, no checkout\n\n"
        + "The stash was kept. If anything changed, Edit ▸ Undo Pop Stash puts it back.")
    #expect(!pop.message.contains("stash@{0}"), "the argument vector is not shown")
    let apply = StashAction.apply(oid: "a", restoreIndex: false).failure(for: failure)
    #expect(apply.message.hasSuffix("Edit ▸ Undo Apply Stash puts it back."))
}

@Test func aConflictIsANoticeAndPopSaysTheStashWasKept() {
    let pop = StashAction.pop(oid: "a", restoreIndex: false)
    #expect(pop.conflictNotice(for: .applied) == nil)
    let notice = pop.conflictNotice(for: .conflicted(paths: ["f.txt"]))
    #expect(notice?.title == "The stash conflicts with f.txt")
    #expect(notice?.message.contains("The stash was kept.") == true)
    #expect(notice?.message.contains("Resolve Conflicts…") == true)
    let apply = StashAction.apply(oid: "a", restoreIndex: false)
        .conflictNotice(for: .conflicted(paths: ["f.txt", "g.txt"]))
    #expect(apply?.title == "The stash conflicts with 2 files")
    #expect(apply?.message.contains("kept") == false)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func theSidebarLoadsTheStashesAndPerformAppliesPopsAndDrops(
    format: FixtureRepository.RefFormat
) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\n", "b.txt": "b\n"])])
    let path = repo.url.path
    let git = GitProcess()
    try repo.writeUntracked(["a.txt": "a\nolder\n"])
    try await git.run(["stash", "push", "-q", "-m", "older"], workingDirectory: path)
    try repo.writeUntracked(["b.txt": "b\nnewer\n"])
    try await git.run(["stash", "push", "-q", "-m", "newer"], workingDirectory: path)

    let stashes = try await loadRepositorySidebar(at: path).stashes
    #expect(stashes.map(\.message) == ["On main: newer", "On main: older"])
    try #require(stashes.count == 2)

    #expect(try await performStashAction(.apply(oid: stashes[1].oid, restoreIndex: false), at: path)
        == .applied)
    #expect(try String(contentsOf: repo.url.appendingPathComponent("a.txt"), encoding: .utf8)
        == "a\nolder\n")
    try await git.run(["checkout", "-q", "--", "a.txt"], workingDirectory: path)

    try await performStashAction(.pop(oid: stashes[0].oid, restoreIndex: false), at: path)
    #expect(try await loadRepositorySidebar(at: path).stashes.map(\.oid) == [stashes[1].oid])

    try await performStashAction(.drop(oid: stashes[1].oid), at: path)
    #expect(try await loadRepositorySidebar(at: path).stashes.isEmpty)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func loadStashDiffShowsTheStashsFiles(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "a\n"])])
    try repo.writeUntracked(["a.txt": "a\nstashed\n", "new.txt": "new\n"])
    try await GitProcess().run(["stash", "push", "-q", "-u"], workingDirectory: repo.url.path)

    let files = try await loadStashDiff(at: repo.url.path, oid: try repo.revParse("refs/stash"))

    #expect(files.map(\.path) == ["a.txt", "new.txt"])
}
