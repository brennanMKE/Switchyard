// JournalMenuRoutingTests.swift — Edit ▸ Undo reaches the journal unless text is being edited (#0448)

import AppKit
import Testing
@testable import YardUI

@MainActor
@Test func undoRoutesToTextOnlyWhileATextViewIsFirstResponder() {
    #expect(JournalMenu.routesToText(NSTextView()))
    #expect(!JournalMenu.routesToText(NSTableView()))
    #expect(!JournalMenu.routesToText(NSWindow()))
    #expect(!JournalMenu.routesToText(nil))
}
