// WindowTitleTests.swift
//
// #0370: the window title names the open repository — its folder name, so
// two open windows are told apart in the Window menu, Mission Control and
// ⌘` cycling — with the current branch (or "detached HEAD") as the subtitle,
// and "Switchyard" as the title when nothing is open. The strings SwiftUI
// installs are derived by the public pure statics
// `ContentView.windowTitle(repositoryPath:)` and
// `ContentView.windowSubtitle(summary:)`, so they are asserted directly
// rather than through scene machinery.
//
// This target imports YardUI WITHOUT `@testable`, so the helpers are
// exercised at exactly the access level the app target sees.

import Testing
import YardGit
import YardUI

/// A minimal loaded summary: everything inert except the branch under test.
private func summary(branch: String?) -> RepositorySummary {
    RepositorySummary(
        whereAmI: WhereAmI(
            branch: branch,
            upstream: nil,
            ahead: nil,
            behind: nil,
            isMidRebase: false,
            isMidMerge: false,
            isMidCherryPick: false,
            stashCount: 0,
            untrackedCount: 0,
            unstagedCount: 0,
            stagedCount: 0,
            hasConflicts: false,
            conflictCount: 0,
            headOID: "a1b2c3d",
            rawHead: "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4"),
        status: WorktreeStatus(entries: []))
}

@MainActor
@Test("windowTitle is the open repository's folder name")
func windowTitleIsFolderName() {
    #expect(ContentView.windowTitle(repositoryPath: "/Users/me/Developer/Switchyard") == "Switchyard")
    #expect(ContentView.windowTitle(repositoryPath: "/Users/me/Developer/other-repo") == "other-repo")
    #expect(ContentView.windowTitle(repositoryPath: "/") == "/")
}

@MainActor
@Test("windowTitle falls back to Switchyard when nothing is open")
func windowTitleFallsBackToAppName() {
    #expect(ContentView.windowTitle(repositoryPath: nil) == "Switchyard")
}

@MainActor
@Test("windowSubtitle names the current branch")
func windowSubtitleNamesBranch() {
    #expect(ContentView.windowSubtitle(summary: summary(branch: "main")) == "main")
    #expect(ContentView.windowSubtitle(summary: summary(branch: "issue/0370")) == "issue/0370")
}

@MainActor
@Test("windowSubtitle reads detached HEAD when HEAD points at no branch")
func windowSubtitleReadsDetachedHead() {
    #expect(ContentView.windowSubtitle(summary: summary(branch: nil)) == "detached HEAD")
}

@MainActor
@Test("windowSubtitle is empty while no summary is loaded")
func windowSubtitleEmptyBeforeLoad() {
    #expect(ContentView.windowSubtitle(summary: nil) == "")
}
