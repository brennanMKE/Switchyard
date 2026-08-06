// YardGitTests.swift

import Testing
@testable import YardGit

struct YardGitTests {

    @Test func libgit2LinksAndReportsAVersion() {
        let v = YardGit.libgit2Version
        // Proves the systemLibrary target actually linked, not just compiled.
        #expect(v.major >= 1, "expected libgit2 1.x or later, got \(v)")
    }

    @Test func initializeAndShutdownBalance() {
        let afterInit = YardGit.initialize()
        #expect(afterInit >= 1, "init should report at least one active reference")
        let afterShutdown = YardGit.shutdown()
        #expect(afterShutdown >= 0)
    }
}
