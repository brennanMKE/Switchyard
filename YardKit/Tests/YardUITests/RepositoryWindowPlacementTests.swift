// RepositoryWindowPlacementTests.swift
//
// #0416: every entry point's open lands in a window -- one repository per
// window. Tested through YardUI's public API (no `@testable`), against real
// `FixtureRepository` repositories through the default resolver, because
// what decides "same repository" is what git says.
//
// A spy `WindowPresenter` records the ids presented; the real one's `show`
// (SwiftUI's `openWindow`) is installed only by a live `ContentView`.

import Foundation
import Testing
import YardGit
import YardKit
import YardUI

private struct WrongOutcome: Error, CustomStringConvertible {
    let outcome: RepositoryTabs.Outcome
    var description: String { "unexpected outcome: \(outcome)" }
}

@MainActor
private func tab(of outcome: RepositoryTabs.Outcome) throws -> RepositoryTab {
    switch outcome {
    case .opened(let tab), .focusedExisting(let tab, _):
        return tab
    case .refused:
        throw WrongOutcome(outcome: outcome)
    }
}

/// A presenter that records every id it was asked to show.
@MainActor
private func spyPresenter() -> (WindowPresenter, () -> [WindowID]) {
    let presenter = WindowPresenter()
    var shown: [WindowID] = []
    presenter.show = { shown.append($0) }
    return (presenter, { shown })
}

@MainActor
@Test("The first open lands in the empty current window and presents it")
func firstOpenFillsTheEmptyCurrentWindow() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let windowStore = WindowStore()
    let tabs = RepositoryTabs()
    let (presenter, shown) = spyPresenter()

    let opened = try tab(of: tabs.openInWindow(
        path: repo.url.path, windowStore: windowStore, presenter: presenter))

    #expect(windowStore.windows.count == 1, "an empty current window is reused, not duplicated")
    #expect(windowStore.windows[0].tabIDs == [opened.id])
    #expect(shown() == [windowStore.windows[0].id])
}

@MainActor
@Test("Opening a second repository while the current window shows one opens a new window")
func secondRepositoryOpensANewWindow() throws {
    let repoA = try FixtureRepository.linear()
    let repoB = try FixtureRepository.linear()
    defer { repoA.destroy(); repoB.destroy() }
    let windowStore = WindowStore()
    let tabs = RepositoryTabs()
    let (presenter, shown) = spyPresenter()

    let tabA = try tab(of: tabs.openInWindow(
        path: repoA.url.path, windowStore: windowStore, presenter: presenter))
    windowStore.activeWindowID = windowStore.windows[0].id
    let tabB = try tab(of: tabs.openInWindow(
        path: repoB.url.path, windowStore: windowStore, presenter: presenter))

    #expect(windowStore.windows.count == 2)
    #expect(windowStore.windows[0].tabIDs == [tabA.id], "the current window keeps its repository")
    #expect(windowStore.windows[1].tabIDs == [tabB.id], "one repository per window")
    #expect(shown() == [windowStore.windows[0].id, windowStore.windows[1].id])
}

@MainActor
@Test("Reopening an open repository, by any spelling, presents its window and adds none")
func reopeningFocusesTheRepositorysWindow() throws {
    let repoA = try FixtureRepository.linear()
    let repoB = try FixtureRepository.linear()
    defer { repoA.destroy(); repoB.destroy() }
    let windowStore = WindowStore()
    let tabs = RepositoryTabs()
    let (presenter, shown) = spyPresenter()

    let tabA = try tab(of: tabs.openInWindow(
        path: repoA.url.path, windowStore: windowStore, presenter: presenter))
    _ = try tab(of: tabs.openInWindow(
        path: repoB.url.path, windowStore: windowStore, presenter: presenter))
    let windowA = try #require(windowStore.window(showing: tabA.id))
    // The user is in B's window now; reopening A must still go to A's.
    windowStore.activeWindowID = windowStore.windows[1].id

    let subdirectory = repoA.url.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
    let again = try tab(of: tabs.openInWindow(
        path: subdirectory.path, windowStore: windowStore, presenter: presenter))

    #expect(again === tabA, "same $GIT_COMMON_DIR, same tab")
    #expect(windowStore.windows.count == 2, "a reopen never adds a window")
    #expect(shown().last == windowA.id, "the repository's own window is the one presented")
}

@MainActor
@Test("A linked worktree of an open repository presents the parent repository's window")
func linkedWorktreePresentsTheParentsWindow() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let worktreeURL = try repo.addWorktree(named: "side", branch: "side")
    defer { try? FileManager.default.removeItem(at: worktreeURL) }
    let windowStore = WindowStore()
    let tabs = RepositoryTabs()
    let (presenter, shown) = spyPresenter()

    let parent = try tab(of: tabs.openInWindow(
        path: repo.url.path, windowStore: windowStore, presenter: presenter))
    windowStore.activeWindowID = windowStore.windows[0].id
    let fromWorktree = try tab(of: tabs.openInWindow(
        path: worktreeURL.path, windowStore: windowStore, presenter: presenter))

    #expect(fromWorktree === parent)
    #expect(windowStore.windows.count == 1)
    #expect(shown() == [windowStore.windows[0].id, windowStore.windows[0].id])
}

@MainActor
@Test("An open lands in the active window when it is empty, not in the first window")
func openFollowsTheActiveEmptyWindow() throws {
    let repoA = try FixtureRepository.linear()
    let repoB = try FixtureRepository.linear()
    defer { repoA.destroy(); repoB.destroy() }
    let windowStore = WindowStore()
    let tabs = RepositoryTabs()
    let (presenter, _) = spyPresenter()

    _ = try tab(of: tabs.openInWindow(
        path: repoA.url.path, windowStore: windowStore, presenter: presenter))
    let emptySecond = windowStore.addWindow()   // Cmd-N: an empty window
    windowStore.activeWindowID = emptySecond.id
    let tabB = try tab(of: tabs.openInWindow(
        path: repoB.url.path, windowStore: windowStore, presenter: presenter))

    #expect(windowStore.windows.count == 2, "the empty current window is used, not a third")
    #expect(emptySecond.tabIDs == [tabB.id])
}

@MainActor
@Test("A folder that is not a repository is refused: no window changes, nothing is presented")
func nonRepositoryIsRefusedWithoutAWindow() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("not-a-repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let windowStore = WindowStore()
    let tabs = RepositoryTabs()
    let (presenter, shown) = spyPresenter()

    let outcome = tabs.openInWindow(path: dir.path, windowStore: windowStore, presenter: presenter)

    guard case .refused = outcome else { throw WrongOutcome(outcome: outcome) }
    #expect(RepositoryOpener.refusalMessage(for: outcome)?.contains("is not a Git repository") == true)
    #expect(windowStore.windows.count == 1)
    #expect(windowStore.windows[0].tabIDs.isEmpty)
    #expect(shown().isEmpty)
}

@MainActor
@Test("A window shows the working tree of the tab its model holds, else the fallback")
func contentViewShowsTheWindowModelsRepository() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let windowStore = WindowStore()
    let tabs = RepositoryTabs()
    let (presenter, _) = spyPresenter()
    let window = windowStore.windows[0]

    #expect(ContentView.repositoryPath(window: window, tabs: tabs, fallback: nil) == nil)
    #expect(ContentView.repositoryPath(window: nil, tabs: tabs, fallback: "/fallback") == "/fallback")

    let opened = try tab(of: tabs.openInWindow(
        path: repo.url.path, windowStore: windowStore, presenter: presenter))
    let expected = try #require(opened.context.topLevel)
    #expect(ContentView.repositoryPath(window: window, tabs: tabs, fallback: "/fallback") == expected)
    #expect(ContentView.repositoryPath(window: windowStore.addWindow(), tabs: tabs, fallback: nil) == nil,
            "another window shows nothing until something is opened in it")
}
