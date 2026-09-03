// WindowStatePersistenceTests.swift
//
// #0083: the persisted layout -- windows in order, each window's tabs in
// tab-bar order keyed by the repository's `commonDir`, and the active tab --
// saved by `WindowStore.save(to:tabs:)` and restored by
// `WindowStore.restore(from:tabs:)`. Tested through YardUI's public API --
// this target imports YardUI WITHOUT `@testable`, so everything asserted
// here is reachable at exactly the access level the app target sees.
//
// What is deliberately asserted by COUNT, never wall-clock time: write
// throttling. `CoalescingStateWriter` coalesces every structural change
// since the last flush into at most one write, so a spy closure that counts
// writes is the whole test surface -- no timers, no sleeps.
//
// NOT covered here, and not fakeable with a store inspection: a real
// relaunch. The store seam is this issue's deliverable; the launch smoke
// test (the app actually restoring its windows) is #0125's.

import Foundation
import Testing
import YardGit
import YardUI

// MARK: - Helpers

private struct WrongOutcome: Error, CustomStringConvertible {
    let outcome: RepositoryTabs.Outcome
    var description: String { "unexpected outcome: \(outcome)" }
}

/// Extracts the tab from an `.opened` outcome; fails the test otherwise.
@MainActor
private func openedTab(_ outcome: RepositoryTabs.Outcome) throws -> RepositoryTab {
    guard case .opened(let tab) = outcome else { throw WrongOutcome(outcome: outcome) }
    return tab
}

/// A scratch directory for state files. The real state directory is never
/// touched: every test passes its own path explicitly into save/restore.
private func makeScratchDirectory() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("switchyard-0083-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
@Test("Save then restore preserves windows, tab order, the active tab, and worktree selection")
func roundTripRestoresWindowsTabOrderActiveTabAndSelection() throws {
    let repoA = try FixtureRepository.linear()
    let repoB = try FixtureRepository.linear()
    let repoC = try FixtureRepository.linear()
    defer {
        repoA.destroy()
        repoB.destroy()
        repoC.destroy()
    }
    let scratch = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let fileURL = scratch.appendingPathComponent("window-state.json")

    let originalStore = WindowStore()
    let originalTabs = RepositoryTabs()
    let tabA = try openedTab(originalTabs.open(path: repoA.url.path))
    let tabB = try openedTab(originalTabs.open(path: repoB.url.path))
    let tabC = try openedTab(originalTabs.open(path: repoC.url.path))
    // Display state a real session could hold: a linked-worktree selection.
    tabA.selectedWorktreeName = "agent-1"

    let first = try #require(originalStore.windows.first)
    let second = originalStore.addWindow()
    first.tabIDs = [tabA.id, tabB.id]
    second.tabIDs = [tabC.id]
    originalTabs.selectedTabID = tabB.id

    try originalStore.save(to: fileURL, tabs: originalTabs)

    // A fresh launch, then restore into it.
    let restoredStore = WindowStore()
    let restoredTabs = RepositoryTabs()
    restoredStore.restore(from: fileURL, tabs: restoredTabs)

    // Exactly the stored windows, in the stored order, with the stored
    // identities -- the #0078 phantom trap asserted after restore.
    #expect(restoredStore.windows.count == 2, "restore holds exactly the stored window count")
    #expect(restoredStore.windows.map(\.id) == [first.id, second.id])
    #expect(restoredStore.initialWindowID == first.id)
    let restoredFirst = try #require(restoredStore.windowState(for: first.id))
    let restoredSecond = try #require(restoredStore.windowState(for: second.id))

    // Per-window tab order, resolved back through the restored tab store.
    #expect(restoredFirst.tabIDs.count == 2)
    #expect(restoredSecond.tabIDs.count == 1)
    var firstTabDirs: [String] = []
    for id in restoredFirst.tabIDs {
        let tab = try #require(restoredTabs.tab(for: id), "every restored tabID must resolve")
        firstTabDirs.append(tab.context.commonDir)
    }
    #expect(firstTabDirs == [tabA.context.commonDir, tabB.context.commonDir])
    let secondOnlyID = try #require(restoredSecond.tabIDs.first)
    let restoredC = try #require(restoredTabs.tab(for: secondOnlyID))
    #expect(restoredC.context.commonDir == tabC.context.commonDir)

    // Display state and the active tab came back too.
    let restoredA = try #require(restoredTabs.tab(for: restoredFirst.tabIDs[0]))
    #expect(restoredA.selectedWorktreeName == "agent-1")
    #expect(restoredA.repositoryMissing == false, "every saved repository still exists here")
    let restoredB = try #require(restoredTabs.tab(for: restoredFirst.tabIDs[1]))
    #expect(restoredTabs.selectedTabID == restoredB.id, "the tab that was active is active again")
}

@MainActor
@Test("Restore holds exactly the stored windows and every stored id resolves (#0078)")
func restoreProducesExactlyTheStoredWindowsAndEveryStoredIDResolves() throws {
    let snapshot = WindowLayoutSnapshot(windows: [
        .init(
            id: WindowID(),
            tabs: [.init(commonDir: "/nowhere/repo-one/.git", selectedWorktreeName: nil, isActive: true)]
        ),
        .init(id: WindowID(), tabs: []),
    ])
    let scratch = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let fileURL = scratch.appendingPathComponent("window-state.json")
    try JSONEncoder().encode(snapshot).write(to: fileURL)

    let store = WindowStore()
    let tabs = RepositoryTabs()
    store.restore(from: fileURL, tabs: tabs)

    // The seeded window is REPLACED, not joined: exactly the stored count,
    // every stored id resolvable, no third window, no fresh initial id.
    #expect(store.windows.count == 2, "restore must hold exactly the stored window count")
    let firstState = try #require(store.windowState(for: snapshot.windows[0].id))
    let secondState = try #require(store.windowState(for: snapshot.windows[1].id))
    #expect(firstState.tabIDs.count == 1)
    #expect(secondState.tabIDs.isEmpty)
    #expect(store.initialWindowID == snapshot.windows[0].id,
            "initialWindowID names the stored first window, never a fresh id")

    // The stored tab came back keyed by commonDir -- and because that path
    // never existed, the tab is present AND reported missing.
    #expect(tabs.tabs.count == 1, "the stored tab is restored, never dropped")
    let restoredTab = try #require(tabs.tabs.first)
    #expect(restoredTab.context.commonDir == "/nowhere/repo-one/.git")
    #expect(restoredTab.repositoryMissing == true)
    #expect(restoredTab.displayName == "repo-one", "the restored tab keeps its repository's name")
    #expect(tabs.selectedTabID == restoredTab.id, "the stored active tab is selected again")
}

@MainActor
@Test("A restored tab whose repository was deleted stays present and reports missing")
func deletedRepositoryTabStaysPresentAndReportsMissing() throws {
    let repo = try FixtureRepository.linear()
    let scratch = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let fileURL = scratch.appendingPathComponent("window-state.json")

    let storedCommonDir: String
    let storedTabID: UUID
    do {
        let store = WindowStore()
        let tabs = RepositoryTabs()
        let tab = try openedTab(tabs.open(path: repo.url.path))
        let seeded = try #require(store.windows.first)
        seeded.tabIDs = [tab.id]
        try store.save(to: fileURL, tabs: tabs)
        storedCommonDir = tab.context.commonDir
        storedTabID = tab.id
    }
    // The repository disappears AFTER the save -- the torn-down agent
    // worktree case the issue calls normal, not an edge case.
    repo.destroy()

    let restoredStore = WindowStore()
    let restoredTabs = RepositoryTabs()
    restoredStore.restore(from: fileURL, tabs: restoredTabs)

    #expect(restoredTabs.tabs.count == 1, "the stale tab stays present, never dropped")
    let staleTab = try #require(restoredTabs.tabs.first)
    #expect(staleTab.id != storedTabID, "a restored tab is a fresh runtime object")
    #expect(staleTab.context.commonDir == storedCommonDir, "identity is the stored commonDir")
    #expect(staleTab.isRestored == true)
    #expect(staleTab.repositoryMissing == true, "the deleted repository is reported in its tab")
    #expect(staleTab.displayName == repo.url.lastPathComponent)
    let window = try #require(restoredStore.windowState(for: restoredStore.initialWindowID))
    #expect(window.tabIDs == [staleTab.id], "the window's tab list survived with the new identity")
    #expect(restoredTabs.selectedTabID == staleTab.id, "the tab that was active stays active")
}

@MainActor
@Test("Corrupt, truncated, foreign, partial, or absent state degrades to the fresh launch")
func corruptOrAbsentStateDegradesToFreshLaunch() throws {
    let scratch = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }

    // A valid two-window layout, corrupted in every way the issue names.
    let valid = WindowLayoutSnapshot(windows: [
        .init(
            id: WindowID(),
            tabs: [.init(commonDir: "/x/repo/.git", selectedWorktreeName: nil, isActive: true)]
        ),
        .init(id: WindowID(), tabs: []),
    ])
    let validData = try JSONEncoder().encode(valid)
    let truncated = Data(validData.prefix(validData.count / 2))

    let cases: [(name: String, data: Data?)] = [
        ("invalid JSON", Data("this is not json {".utf8)),
        ("truncated JSON", truncated),
        ("empty file", Data()),
        ("foreign schema version", try JSONEncoder().encode(
            WindowLayoutSnapshot(schemaVersion: 99, windows: valid.windows))),
        ("partial: windows key missing", Data("{\"schemaVersion\":1}".utf8)),
        ("zero windows", try JSONEncoder().encode(WindowLayoutSnapshot(windows: []))),
        ("absent file", nil),
    ]

    for (name, data) in cases {
        let fileURL = scratch.appendingPathComponent("state-\(UUID().uuidString).json")
        if let data {
            try data.write(to: fileURL)
        }

        // Each case starts from the fresh-launch invariant and must end at
        // exactly it -- one seeded, empty window; untouched tab store.
        let store = WindowStore()
        let tabs = RepositoryTabs()
        store.restore(from: fileURL, tabs: tabs)

        #expect(store.windows.count == 1, "\(name): degrades to the single-window launch")
        let seeded = try #require(store.windows.first)
        #expect(store.initialWindowID == seeded.id, "\(name): the seeded window still resolves")
        #expect(seeded.tabIDs.isEmpty, "\(name): the degraded window has no tabs")
        #expect(tabs.tabs.isEmpty, "\(name): no tab may come back from \(name) state")
        #expect(tabs.selectedTabID == nil, "\(name): no selection may survive \(name) state")
    }
}

@MainActor
@Test("Structural changes coalesce into at most one write per flush, activations included")
func structuralChangesCoalesceIntoAtMostOneWritePerFlush() throws {
    let repoA = try FixtureRepository.linear()
    let repoB = try FixtureRepository.linear()
    defer {
        repoA.destroy()
        repoB.destroy()
    }

    // The spy IS the write seam: every write the throttled path performs
    // bumps this count. No file, no clock.
    var writes = 0
    let writer = CoalescingStateWriter { writes += 1 }

    let store = WindowStore()
    let tabs = RepositoryTabs()
    store.stateWriter = writer
    tabs.stateWriter = writer

    // Nothing pending: a flush with no structural change writes nothing.
    #expect(writer.hasPendingWrite == false)
    #expect(writer.flushNow() == false)
    #expect(writes == 0)

    // Open (append + activate), reorder (the array mutation the tab bar
    // binding commits), activate, tab-list mutation, window open + close.
    let tabA = try openedTab(tabs.open(path: repoA.url.path))
    let tabB = try openedTab(tabs.open(path: repoB.url.path))
    tabs.tabs = tabs.tabs.reversed()
    tabs.selectedTabID = tabA.id
    let added = store.addWindow()
    added.tabIDs.append(tabA.id)
    store.removeWindow(added.id)

    #expect(writer.hasPendingWrite == true, "every structural change marks a write pending")
    #expect(writer.flushNow() == true)
    #expect(writes == 1, "every change since the last flush folds into ONE write")

    // Flushing again with nothing pending performs no write.
    #expect(writer.flushNow() == false)
    #expect(writes == 1)

    // Rapid activation: fifty selection flips coalesce to one write.
    for _ in 0..<25 {
        tabs.selectedTabID = tabB.id
        tabs.selectedTabID = tabA.id
    }
    #expect(writer.flushNow() == true)
    #expect(writes == 2, "rapid tab switches coalesce: one write, not fifty")

    // With the writer detached, mutations mark nothing pending.
    store.stateWriter = nil
    tabs.stateWriter = nil
    tabs.selectedTabID = tabB.id
    #expect(writer.hasPendingWrite == false)
    #expect(writes == 2)
}

@MainActor
@Test("restoreTab inserts without resolving, without duplicating, and without stealing selection")
func restoreTabIsInsertOnlyAndDoesNotStealSelection() throws {
    let tabs = RepositoryTabs()
    // A real directory that is NOT a repository: existence and repository-
    // ness are different questions, and restore must not ask git either one.
    let plainDirectory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: plainDirectory) }

    let missing = tabs.restoreTab(commonDir: "/nowhere/repo/.git")
    #expect(missing.context.commonDir == "/nowhere/repo/.git")
    #expect(missing.context.topLevel == nil, "restore never resolves -- no top level is fabricated")
    #expect(missing.isRestored == true)
    #expect(missing.repositoryMissing == true, "a gone path is reported missing in its tab")
    #expect(missing.displayName == "repo", "the restored tab keeps its repository's name")

    let present = tabs.restoreTab(commonDir: plainDirectory.path, selectedWorktreeName: "agent-9")
    #expect(present.isRestored == true)
    #expect(present.repositoryMissing == false, "an existing path is not reported missing")
    #expect(present.selectedWorktreeName == "agent-9", "stored worktree selection rides along")

    // Insert-only: no tab is focused by an insert, and the same commonDir
    // never produces a second tab.
    #expect(tabs.selectedTabID == nil, "an insert-only seam must not steal selection")
    #expect(tabs.tabs.count == 2)
    let again = tabs.restoreTab(commonDir: "/nowhere/repo/.git")
    #expect(again === missing, "the same commonDir never produces a second tab")
    #expect(tabs.tabs.count == 2)
}

@MainActor
@Test("Opening the repository upgrades a restored tab to a real resolved context in place")
func openingTheRepositoryUpgradesARestoredTabInPlace() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    // The commonDir the way a real save would have stored it: resolved.
    let storedCommonDir: String
    do {
        let discovery = RepositoryTabs()
        let discovered = try openedTab(discovery.open(path: repo.url.path))
        storedCommonDir = discovered.context.commonDir
    }

    let tabs = RepositoryTabs()
    let restored = tabs.restoreTab(commonDir: storedCommonDir)
    #expect(restored.isRestored == true)
    #expect(restored.repositoryMissing == false, "the repository still exists on disk")

    let outcome = tabs.open(path: repo.url.path)
    guard case .focusedExisting(let tab, let worktree) = outcome else {
        throw WrongOutcome(outcome: outcome)
    }
    #expect(tab === restored, "the restored tab is focused, not duplicated")
    #expect(worktree == nil, "the main-worktree path selects the main worktree")
    #expect(restored.isRestored == false, "opening upgrades the tab in place")
    #expect(restored.repositoryMissing == false)
    let topLevel = try #require(restored.context.topLevel)
    #expect(topLevel == repo.url.path)
    #expect(restored.context.commonDir == storedCommonDir, "identity never changed")
    #expect(tabs.tabs.count == 1, "the upgrade happens in place -- no second tab")
}

@MainActor
@Test("save creates missing intermediate directories and writes the current schema")
func saveCreatesMissingDirectoriesAndWritesCurrentSchema() throws {
    let scratch = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let fileURL = scratch.appendingPathComponent("nested/deeper/window-state.json")

    let store = WindowStore()
    let tabs = RepositoryTabs()
    try store.save(to: fileURL, tabs: tabs)

    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    let data = try Data(contentsOf: fileURL)
    let snapshot = try JSONDecoder().decode(WindowLayoutSnapshot.self, from: data)
    #expect(snapshot.schemaVersion == WindowLayoutSnapshot.schemaVersionCurrent)
    #expect(snapshot.windows.count == 1, "the fresh store saves its one seeded window")
}
