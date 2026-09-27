// RepositoryWindowTabbingTests.swift
//
// #0417: repository tabs are native window tabs. What can be asserted
// headless is the model half of File ▸ New Tab. That the windows merge into
// one tab group is visible only in a running app: the VM test
// Spike0417RepositoryTabsUITests covers it.
//
// Deliberately NO test constructs an `NSWindow` to check
// `RepositoryWindowTabbing.configure`: measured 2026-09-26, one `NSWindow`
// created in this test process made AbandonedSheetTests'
// `theReaperStillEndsAnAbandonedReview` time out (WaitTimeout after ~224 s,
// every run; green in 9 s with that test disabled).

import Foundation
import Testing
import YardGit
import YardUI

@MainActor
@Test("New Tab adds an empty window, presents it, and the next open lands in it")
func newTabAddsAnEmptyWindowThatTheNextOpenFills() throws {
    let repoA = try FixtureRepository.linear()
    let repoB = try FixtureRepository.linear()
    defer { repoA.destroy(); repoB.destroy() }
    let windowStore = WindowStore()
    let tabs = RepositoryTabs()
    let presenter = WindowPresenter()
    var shown: [WindowID] = []
    presenter.show = { shown.append($0) }

    _ = tabs.openInWindow(path: repoA.url.path, windowStore: windowStore, presenter: presenter)
    windowStore.activeWindowID = windowStore.windows[0].id

    let newTab = RepositoryOpener.openNewTab(windowStore: windowStore, presenter: presenter)

    #expect(windowStore.windows.count == 2)
    #expect(windowStore.windows[1].id == newTab)
    #expect(windowStore.windows[1].tabIDs.isEmpty, "a new tab starts empty")
    #expect(shown.last == newTab, "the new tab is presented")

    // The new tab becomes the active window when it appears; an open then
    // fills it instead of adding a third window.
    windowStore.activeWindowID = newTab
    _ = tabs.openInWindow(path: repoB.url.path, windowStore: windowStore, presenter: presenter)
    #expect(windowStore.windows.count == 2)
    #expect(windowStore.windows[1].tabIDs.count == 1)
}

@MainActor
@Test("A window opened with no value is the launch window until it is shown, then a new empty one")
func windowWithoutValueIsLaunchWindowThenANewOne() {
    let windowStore = WindowStore()
    let launch = windowStore.initialWindowID

    #expect(windowStore.idForWindowWithoutValue() == launch)
    #expect(windowStore.idForWindowWithoutValue() == launch, "asking twice before it shows adds nothing")
    #expect(windowStore.windows.count == 1)

    windowStore.noteShown(launch)
    let plus = windowStore.idForWindowWithoutValue()

    #expect(plus != launch, "the tab bar's + must not reuse the launch window")
    #expect(windowStore.windows.count == 2)
    #expect(windowStore.windowState(for: plus)?.tabIDs.isEmpty == true, "the new tab starts empty")
}
