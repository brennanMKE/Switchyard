// ContentViewPublicAPITests.swift
//
// This target imports YardUI **without** `@testable`, so it compiles at exactly
// the access level the app target sees. That is the whole point: `@testable`
// grants internal access, so a test using it cannot notice a `public` type whose
// members are not — which is the defect #0116 found in `YardGit`.
//
// **Any new public API in YardUI gets a line here**, the same way a new command
// gets its skill regenerated.

import Testing
import SwiftUI
import YardUI

@MainActor
@Test("ContentView is reachable and constructible at a caller's access level")
func contentViewIsPubliclyConstructible() async throws {
    // Both of these fail to COMPILE if the boundary breaks: the initialiser is
    // internal by default on a public struct, and `body` must be public too.
    let view = ContentView()
    _ = view.body

    // A falsifiable assertion, so the test is not merely a compile contract:
    // renaming the type breaks it, and the name is part of the public surface
    // the app depends on.
    #expect(String(describing: ContentView.self) == "ContentView")
}

@MainActor
@Test("ContentView's window title helpers are callable at a caller's access level (#0370)")
func windowTitleHelpersArePubliclyCallable() {
    // Both fail to COMPILE if the #0370 helpers drop to internal: the app
    // target reads the same strings the window title and subtitle show.
    #expect(ContentView.windowTitle(repositoryPath: "/tmp/repo") == "repo")
    #expect(ContentView.windowSubtitle(summary: nil) == "")
}
