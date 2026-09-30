// JournalMenuRoutingTests.swift — Edit ▸ Undo reaches the journal unless text is being edited (#0448)

import AppKit
import Testing
@testable import YardUI

@MainActor
@Test func undoRoutesToTextOnlyWhileATextViewIsFirstResponder() {
    #expect(!JournalMenu.routesToText(NSTextView()))
    #expect(!JournalMenu.routesToText(NSTableView()))
    #expect(!JournalMenu.routesToText(NSWindow()))
    #expect(!JournalMenu.routesToText(nil))
}

@MainActor
@Test func textRoutesOnlyWhileItHasAStepToTake() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                          styleMask: [.titled], backing: .buffered, defer: true)
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    text.allowsUndo = true
    window.contentView!.addSubview(text)
    window.makeFirstResponder(text)
    #expect(!JournalMenu.routesToText(text))
    text.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))
    text.undoManager?.endUndoGrouping()
    #expect(JournalMenu.routesToText(text))
    #expect(!JournalMenu.routesToText(text, redo: true))
    text.string = ""                     // the commit's reset leaves the steps behind…
    #expect(JournalMenu.routesToText(text))
    text.undoManager?.removeAllActions() // …which #0570's clear removes
    #expect(!JournalMenu.routesToText(text))
}
