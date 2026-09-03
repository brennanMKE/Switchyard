// RepositoryTabsTests.swift
//
// #0079's repository-tab store, tested through YardUI's public API -- this
// target imports YardUI WITHOUT `@testable`, so everything asserted here is
// reachable at exactly the access level the app target sees.
//
// Two families, kept apart on purpose:
//
// - **Identity cases** go through the DEFAULT resolver against real
//   `FixtureRepository` fixtures, because the thing under test is what git
//   says a path resolves to. Every spelling case the issue names is one
//   test: same path twice, symlink, trailing slash, subdirectory, /var vs
//   /private/var, and a linked worktree.
// - **Pure-store behaviour** (order, close, teardown, injected resolver)
//   uses a fake resolver built from pre-resolved fixture contexts, so no
//   test in this family shells out per call.
//
// NOT covered here, deliberately: the tab bar chrome (SwiftUI, not
// assertable headless) and the resource-release half of criterion 5 -- no
// file watchers exist yet (the sidebar/graph work, #0081, will introduce
// them). What IS asserted is the seam those watchers will hang from: a
// closed tab fires its `onTeardown` hook exactly once and the store drops
// its reference.

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

/// Extracts the tab and selected-worktree name from a `.focusedExisting`
/// outcome; fails the test otherwise.
@MainActor
private func focusedExisting(
    _ outcome: RepositoryTabs.Outcome
) throws -> (tab: RepositoryTab, selectedWorktreeName: String?) {
    guard case .focusedExisting(let tab, let worktree) = outcome else {
        throw WrongOutcome(outcome: outcome)
    }
    return (tab, worktree)
}

/// Extracts the path and detail from a `.refused` outcome; fails the test
/// otherwise.
@MainActor
private func refused(_ outcome: RepositoryTabs.Outcome) throws -> (path: String, detail: String) {
    guard case .refused(let path, let detail) = outcome else {
        throw WrongOutcome(outcome: outcome)
    }
    return (path, detail)
}

// MARK: - Identity: same repository, different spellings (default resolver)

@MainActor
@Test("Opening the same repository by its own path twice keeps one tab and focuses it")
func openingSameRepositoryTwiceKeepsOneTab() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    let store = RepositoryTabs()
    let tab = try openedTab(store.open(path: repo.url.path))
    #expect(store.tabs.count == 1)
    #expect(store.selectedTabID == tab.id)

    // A different repository joins it, so the focus-back is observable.
    let other = try FixtureRepository.linear()
    defer { other.destroy() }
    let otherTab = try openedTab(store.open(path: other.url.path))
    #expect(store.tabs.count == 2)
    #expect(store.selectedTabID == otherTab.id)

    let again = try focusedExisting(store.open(path: repo.url.path))
    #expect(again.tab === tab, "the same repository resolves to the same tab object")
    #expect(again.selectedWorktreeName == nil, "the main worktree path selects the main worktree")
    #expect(store.tabs.count == 2, "no third tab may appear for an open repository")
    #expect(store.selectedTabID == tab.id, "opening focuses the existing tab")
}

@MainActor
@Test("Opening by a symlink to the working tree focuses the same tab")
func openingBySymlinkFocusesSameTab() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    let linkURL = repo.url.deletingLastPathComponent()
        .appendingPathComponent("\(repo.url.lastPathComponent)-symlink")
    try FileManager.default.createSymbolicLink(
        atPath: linkURL.path, withDestinationPath: repo.url.path)
    defer { try? FileManager.default.removeItem(at: linkURL) }

    let store = RepositoryTabs()
    let tab = try openedTab(store.open(path: repo.url.path))

    let throughLink = try focusedExisting(store.open(path: linkURL.path))
    #expect(throughLink.tab === tab)
    #expect(store.tabs.count == 1)
}

@MainActor
@Test("Opening with a trailing slash focuses the same tab")
func openingWithTrailingSlashFocusesSameTab() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    let store = RepositoryTabs()
    let tab = try openedTab(store.open(path: repo.url.path))

    let withSlash = try focusedExisting(store.open(path: repo.url.path + "/"))
    #expect(withSlash.tab === tab)
    #expect(store.tabs.count == 1)
}

@MainActor
@Test("Opening by a subdirectory of the working tree focuses the same tab")
func openingBySubdirectoryFocusesSameTab() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    try FileManager.default.createDirectory(
        at: repo.url.appendingPathComponent("sub/inner"), withIntermediateDirectories: true)

    let store = RepositoryTabs()
    let tab = try openedTab(store.open(path: repo.url.path))

    let nested = try focusedExisting(
        store.open(path: repo.url.appendingPathComponent("sub/inner").path))
    #expect(nested.tab === tab)
    #expect(store.tabs.count == 1)
}

@MainActor
@Test("Opening by the unresolved /var spelling of a /private/var fixture focuses the same tab")
func openingByUnresolvedVarSpellingFocusesSameTab() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    // The fixture's URL is realpath(3)-resolved, so on macOS it starts
    // /private/var/folders/... -- require that shape so the rewrite below
    // can never silently produce a nonsense path and still pass.
    let resolved = repo.url.path
    try #require(
        resolved.hasPrefix("/private/"),
        "fixture URLs are expected to be /private/var/... on macOS, got \(resolved)")
    let unresolved = "/" + resolved.dropFirst("/private/".count)

    let store = RepositoryTabs()
    let tab = try openedTab(store.open(path: resolved))

    let byUnresolved = try focusedExisting(store.open(path: unresolved))
    #expect(byUnresolved.tab === tab)
    #expect(store.tabs.count == 1)
}

@MainActor
@Test("Opening a linked worktree of an open repository focuses the parent tab and selects the worktree")
func openingLinkedWorktreeFocusesParentTabAndSelectsWorktree() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let worktreeURL = try repo.addWorktree(named: "side", branch: "side")
    defer { try? FileManager.default.removeItem(at: worktreeURL) }

    let store = RepositoryTabs()
    let parentTab = try openedTab(store.open(path: repo.url.path))
    // Sanity on the fixture shape: the parent tab is the main worktree.
    #expect(parentTab.context.isLinkedWorktree == false)

    let fromWorktree = try focusedExisting(store.open(path: worktreeURL.path))
    #expect(fromWorktree.tab === parentTab, "a linked worktree resolves to the parent repository's tab")
    // git names a worktree after its directory's last path component, not
    // the fixture helper's `named:` parameter -- so assert against the
    // actual name the worktree got.
    #expect(fromWorktree.selectedWorktreeName == worktreeURL.lastPathComponent)
    #expect(parentTab.selectedWorktreeName == worktreeURL.lastPathComponent)
    #expect(store.tabs.count == 1, "the worktree must not open a second tab")
    #expect(store.selectedTabID == parentTab.id)
}

@MainActor
@Test("Reopening the main worktree path after a linked worktree reselects the main worktree")
func reopeningMainWorktreeReselectsMainWorktree() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let worktreeURL = try repo.addWorktree(named: "side", branch: "side")
    defer { try? FileManager.default.removeItem(at: worktreeURL) }

    let store = RepositoryTabs()
    let parentTab = try openedTab(store.open(path: repo.url.path))
    _ = try focusedExisting(store.open(path: worktreeURL.path))
    #expect(parentTab.selectedWorktreeName == worktreeURL.lastPathComponent)

    let backToMain = try focusedExisting(store.open(path: repo.url.path))
    #expect(backToMain.tab === parentTab)
    #expect(backToMain.selectedWorktreeName == nil)
    #expect(parentTab.selectedWorktreeName == nil)
}

// MARK: - Refusal

@MainActor
@Test("Opening a path that is not a repository refuses, reports detail, and opens no tab")
func openingNonRepositoryRefusesAndOpensNoTab() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("not-a-repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = RepositoryTabs()
    let outcome = store.open(path: dir.path)
    let (path, detail) = try refused(outcome)
    #expect(path == dir.path)
    #expect(!detail.isEmpty, "the refusal must carry the resolver's detail so it can be reported")
    #expect(store.tabs.isEmpty, "a refused path opens no tab")
    #expect(store.selectedTabID == nil)
}

// MARK: - Canonicalization property (the store itself calls no realpath)

@MainActor
@Test("A tab's commonDir is a realpath fixed point")
func commonDirIsCanonicalRealpathFixedPoint() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    let store = RepositoryTabs()
    let tab = try openedTab(store.open(path: repo.url.path))
    let commonDir = tab.context.commonDir
    // The view layer never canonicalizes; it holds that the resolver
    // already did. Assert the property: canonicalize(commonDir) == commonDir.
    let resolved = try #require(realpath(commonDir, nil))
    defer { free(resolved) }
    #expect(commonDir == String(cString: resolved))
    #expect(tab.context.isLinkedWorktree == false)
}

// MARK: - Pure-store behaviour (injected resolver, no git per call)

/// Builds an injected resolver from a table of pre-resolved contexts: a
/// lookup miss throws the same `notARepository` the default resolver would.
@MainActor
private func tableResolver(_ table: [String: WorktreeContext]) -> RepositoryTabs.Resolver {
    { path in
        guard let context = table[path] else {
            throw WorktreeContext.Error.notARepository(path: path, detail: "not in fixture table")
        }
        return context
    }
}

@MainActor
@Test("The injected resolver is used and tabs key on commonDir, not on the opened path")
func openUsesInjectedResolverAndKeysTabsOnCommonDir() throws {
    let repoA = try FixtureRepository.linear()
    defer { repoA.destroy() }
    let repoB = try FixtureRepository.linear()
    defer { repoB.destroy() }
    let contextA = try WorktreeContext.resolve(path: repoA.url.path)
    let contextB = try WorktreeContext.resolve(path: repoB.url.path)

    // Two different paths resolve to the SAME context -- a store keyed on
    // anything else (the path itself, topLevel of the opening call) would
    // open two tabs here.
    let table: [String: WorktreeContext] = [
        "alias-one": contextA,
        "alias-two": contextA,
        "alias-three": contextB,
    ]
    let store = RepositoryTabs(resolver: tableResolver(table))

    let first = try openedTab(store.open(path: "alias-one"))
    let viaOtherAlias = try focusedExisting(store.open(path: "alias-two"))
    #expect(viaOtherAlias.tab === first)
    let second = try openedTab(store.open(path: "alias-three"))
    #expect(first.context.commonDir != second.context.commonDir)
    #expect(store.tabs.count == 2)
    #expect(store.selectedTabID == second.id)
}

@MainActor
@Test("A resolver error of any kind refuses the open and leaves the tabs untouched")
func anyResolverErrorRefusesAndLeavesTabsUntouched() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let context = try WorktreeContext.resolve(path: repo.url.path)
    let store = RepositoryTabs(resolver: tableResolver([repo.url.path: context]))

    let tab = try openedTab(store.open(path: repo.url.path))

    let (path, detail) = try refused(store.open(path: "nowhere"))
    #expect(path == "nowhere")
    #expect(!detail.isEmpty)
    #expect(store.tabs.count == 1)
    #expect(store.tab(for: tab.id) === tab, "a refusal must not disturb existing tabs")
}

@MainActor
@Test("Closing a tab removes it and leaves the other tabs' order intact")
func closingATabRemovesItAndKeepsOrder() throws {
    let repos = (try (0..<3).map { _ in try FixtureRepository.linear() })
    defer { for repo in repos { repo.destroy() } }
    var table: [String: WorktreeContext] = [:]
    for repo in repos {
        table[repo.url.path] = try WorktreeContext.resolve(path: repo.url.path)
    }
    let store = RepositoryTabs(resolver: tableResolver(table))
    var ids: [UUID] = []
    for repo in repos {
        ids.append(try openedTab(store.open(path: repo.url.path)).id)
    }
    #expect(store.tabs.count == 3)

    // Close the middle tab.
    store.close(ids[1])
    #expect(store.tabs.count == 2)
    #expect(store.tab(for: ids[1]) == nil)
    // The survivors keep their order: the first is still first.
    #expect(store.tabs[0].id == ids[0])
    #expect(store.tabs[1].id == ids[2])
    // Selection was on the third tab; closing the first tab does not move it.
    #expect(store.selectedTabID == ids[2])
}

@MainActor
@Test("Closing the last tab empties the list and clears selection")
func closingLastTabEmptiesList() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let context = try WorktreeContext.resolve(path: repo.url.path)
    let store = RepositoryTabs(resolver: tableResolver([repo.url.path: context]))
    let tab = try openedTab(store.open(path: repo.url.path))

    // Documented behaviour (#0079): closing the last tab is allowed -- the
    // list may empty, because the never-empty guarantee is WindowStore's
    // (#0078), at the window level, not this store's.
    store.close(tab.id)
    #expect(store.tabs.isEmpty)
    #expect(store.selectedTabID == nil)
}

@MainActor
@Test("Closing fires the tab's teardown hook exactly once and drops the store's reference")
func closingFiresTeardownHookAndDropsReference() throws {
    let repos = (try (0..<2).map { _ in try FixtureRepository.linear() })
    defer { for repo in repos { repo.destroy() } }
    var table: [String: WorktreeContext] = [:]
    for repo in repos {
        table[repo.url.path] = try WorktreeContext.resolve(path: repo.url.path)
    }
    let store = RepositoryTabs(resolver: tableResolver(table))
    let firstTab = try openedTab(store.open(path: repos[0].url.path))
    let secondTab = try openedTab(store.open(path: repos[1].url.path))

    var teardownCount = 0
    firstTab.onTeardown = { teardownCount += 1 }

    store.close(firstTab.id)
    #expect(teardownCount == 1, "the teardown hook fires exactly once, at close")
    #expect(store.tab(for: firstTab.id) == nil, "the store drops its reference to the closed tab")
    // Closing again is a no-op and must not fire the hook a second time.
    store.close(firstTab.id)
    #expect(teardownCount == 1)
    #expect(store.tabs.count == 1)
    #expect(store.tab(for: secondTab.id) === secondTab)
}
