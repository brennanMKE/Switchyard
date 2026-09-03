// RepositoryOpenerTests.swift
//
// #0084's testable seams, exercised through YardUI's public API -- this
// target imports YardUI WITHOUT `@testable`, so everything asserted here is
// reachable at exactly the access level the app target sees.
//
// NOT duplicated from #0079: the identity cases (same path, symlink,
// trailing slash, subdirectory, /var spelling, linked worktree) and the
// plain refusal behaviour live in RepositoryTabsTests.swift. What is new
// here is the shell-side seam the four entry points share: the
// human-readable refusal formatter, the `switchyard://` URL parse, and the
// open-into-frontmost-window model half the XPC entry point drives.
//
// NOT covered here, and not fakeable: the open panel, the alert, real URL
// opens, real Dock drops, real XPC activations, and window counts --
// #0054's manual script owns those. No test in this file calls a function
// that presents UI; only the value-returning seams are exercised.

import Foundation
import Testing
import YardGit
import YardKit
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

/// Extracts the tab from a `.focusedExisting` outcome; fails the test
/// otherwise.
@MainActor
private func focusedExisting(_ outcome: RepositoryTabs.Outcome) throws -> RepositoryTab {
    guard case .focusedExisting(let tab, _) = outcome else {
        throw WrongOutcome(outcome: outcome)
    }
    return tab
}

// MARK: - Refusal message (the one formatter all four entry points report through)

@MainActor
@Test("A non-repository refusal formats a message that is non-empty and names the path")
func refusalMessageForNonRepositoryIsNotEmptyAndNamesPath() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("not-a-repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = RepositoryTabs()
    let outcome = store.open(path: dir.path)

    let message = try #require(
        RepositoryOpener.refusalMessage(for: outcome),
        "a refused outcome must carry a reportable message")
    #expect(!message.isEmpty)
    #expect(message.contains(dir.path), "the message must name the path that was refused")
}

@MainActor
@Test("A refusal message carries the resolver's detail")
func refusalMessageCarriesResolverDetail() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("not-a-repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = RepositoryTabs()
    guard case .refused(_, let detail) = store.open(path: dir.path) else {
        throw WrongOutcome(outcome: store.open(path: dir.path))
    }

    let message = try #require(
        RepositoryOpener.refusalMessage(for: store.open(path: dir.path)))
    #expect(message.contains(detail), "the message must carry the resolver's detail")
}

@MainActor
@Test("A successful open and a successful focus produce no refusal message")
func successfulOutcomesProduceNoRefusalMessage() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    let store = RepositoryTabs()
    #expect(RepositoryOpener.refusalMessage(for: store.open(path: repo.url.path)) == nil)
    #expect(RepositoryOpener.refusalMessage(for: store.open(path: repo.url.path)) == nil)
}

// MARK: - switchyard:// URL parsing (entry point 3's argument shape)

@Test("A switchyard:// URL with a path query yields the percent-decoded repository path")
func switchyardURLWithQueryYieldsDecodedPath() throws {
    let url = try #require(URL(string: "switchyard://open?path=%2FUsers%2Fme%2FMy%20Repo"))
    #expect(RepositoryOpener.repositoryPath(from: url) == "/Users/me/My Repo")
    #expect(RepositoryOpener.deliveredPath(from: url) == "/Users/me/My Repo")
}

@Test("A foreign scheme or a URL without a path query names no repository")
func foreignOrPathlessURLNameNoRepository() throws {
    let foreign = try #require(URL(string: "https://example.com/open?path=%2Ftmp%2Frepo"))
    let pathless = try #require(URL(string: "switchyard://open"))
    let emptyPath = try #require(URL(string: "switchyard://open?path="))

    #expect(RepositoryOpener.repositoryPath(from: foreign) == nil)
    #expect(RepositoryOpener.repositoryPath(from: pathless) == nil)
    #expect(RepositoryOpener.repositoryPath(from: emptyPath) == nil)
    #expect(RepositoryOpener.deliveredPath(from: foreign) == nil)
    #expect(RepositoryOpener.deliveredPath(from: pathless) == nil)
}

@Test("A file URL delivers its own path")
func fileURLDeliversItsOwnPath() throws {
    let url = URL(fileURLWithPath: "/tmp/some repository")
    #expect(url.isFileURL)
    #expect(RepositoryOpener.deliveredPath(from: url) == "/tmp/some repository")
}

// MARK: - Entry point 4's model half: open into the frontmost window

@MainActor
@Test("An XPC open for a repository with no tab attaches the new tab to the active window")
func xpcOpenAttachesNewTabToActiveWindow() throws {
    let repoA = try FixtureRepository.linear()
    let repoB = try FixtureRepository.linear()
    defer { repoA.destroy(); repoB.destroy() }

    let windowStore = WindowStore()
    let secondWindow = windowStore.addWindow()
    #expect(windowStore.windows.count == 2)
    let store = RepositoryTabs()

    // Nothing is selected yet, so the open lands in the first window.
    let tabA = try openedTab(
        store.openInFrontmostWindow(path: repoA.url.path, windowStore: windowStore))
    #expect(windowStore.windows[0].tabIDs == [tabA.id])
    #expect(secondWindow.tabIDs.isEmpty)
    #expect(store.selectedTabID == tabA.id)

    // The user then moves to the second window -- which is what the
    // tab-bar binding committing a's tab into it looks like in the model
    // (#0080's wiring) -- and the next XPC open follows the user there.
    secondWindow.tabIDs = [tabA.id]
    windowStore.windows[0].tabIDs = []

    let tabB = try openedTab(
        store.openInFrontmostWindow(path: repoB.url.path, windowStore: windowStore))
    #expect(secondWindow.tabIDs == [tabA.id, tabB.id])
    #expect(windowStore.windows[0].tabIDs.isEmpty)
    #expect(store.selectedTabID == tabB.id)
    #expect(store.tabs.count == 2)
}

@MainActor
@Test("An XPC open for an already-open repository focuses it and touches no window")
func xpcOpenForOpenRepositoryFocusesWithoutTouchingWindows() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    let windowStore = WindowStore()
    let secondWindow = windowStore.addWindow()
    let store = RepositoryTabs()

    let tab = try openedTab(
        store.openInFrontmostWindow(path: repo.url.path, windowStore: windowStore))
    #expect(windowStore.windows[0].tabIDs == [tab.id])

    // The tab-bar binding has since moved the tab into the second window;
    // re-requesting the SAME repository must focus it, never duplicate it,
    // and never re-attach it anywhere.
    secondWindow.tabIDs = [tab.id]
    windowStore.windows[0].tabIDs = []

    let again = try focusedExisting(
        store.openInFrontmostWindow(path: repo.url.path, windowStore: windowStore))
    #expect(again === tab, "focus returns the same tab")
    #expect(store.tabs.count == 1, "focus, never a duplicate tab")
    #expect(secondWindow.tabIDs == [tab.id], "a focus touches no window's tab list")
    #expect(windowStore.windows[0].tabIDs.isEmpty)
    #expect(store.selectedTabID == tab.id)
}

@MainActor
@Test("An XPC open for a non-repository refuses and leaves every window untouched")
func xpcOpenForNonRepositoryRefusesAndTouchesNoWindow() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("not-a-repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let windowStore = WindowStore()
    let secondWindow = windowStore.addWindow()
    let store = RepositoryTabs()

    guard case .refused = store.openInFrontmostWindow(
        path: dir.path, windowStore: windowStore)
    else {
        throw WrongOutcome(outcome: store.open(path: dir.path))
    }

    #expect(store.tabs.isEmpty, "a refusal opens no tab")
    #expect(windowStore.windows[0].tabIDs.isEmpty)
    #expect(secondWindow.tabIDs.isEmpty)
    #expect(store.selectedTabID == nil)
}
