// CommitDraftStoreTests.swift — the draft kept per repository (#0564)

import Foundation
import Testing
@testable import YardUI

/// A defaults suite of its own, removed afterwards.
private func withStore(_ body: (CommitDraftStore) -> Void) {
    let suite = "CommitDraftStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    body(CommitDraftStore(defaults: defaults))
}

@Test func eachRepositoryKeepsItsOwnDraft() {
    withStore { store in
        #expect(store.load(for: "/r/a") == nil)
        store.save("Fix the parser\n\nIt dropped the last line.", for: "/r/a")
        store.save("Other repo", for: "/r/b")
        #expect(store.load(for: "/r/a") == "Fix the parser\n\nIt dropped the last line.")
        #expect(store.load(for: "/r/b") == "Other repo")
    }
}

@Test func aBlankDraftRemovesTheEntry() {
    withStore { store in
        store.save("half-written", for: "/r/a")
        store.save(" \n", for: "/r/a")
        #expect(store.load(for: "/r/a") == nil)
    }
}

@Test func whileAmendingTheSetAsideDraftIsWhatIsSaved() {
    var draft = CommitDraft(message: "my draft")
    #expect(draft.savedText == "my draft")
    draft.setAmending(true, headMessage: "HEAD's message")
    #expect(draft.savedText == "my draft")
    draft.setAmending(false, headMessage: "")
    draft.message = "edited"
    #expect(draft.savedText == "edited")
}
