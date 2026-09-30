// DiffLineWordsTests.swift — a diff line drawn with its changed words (#0537)

import SwiftUI
import Testing
@testable import YardUI

/// The text of each run carrying a background color.
private func tinted(_ text: AttributedString) -> [String] {
    text.runs.filter { $0.backgroundColor != nil }.map { String(text[$0.range].characters) }
}

@Test
func aDrawnLineKeepsEveryCharacterAndTintsOnlyTheChangedWords() {
    let body = ["-let x = foo(1)", "+let x = foo(10)"]
    let changes = IntralineDiff.changes(in: body)

    let removed = DiffLineView.attributed(body[0], changes: changes[0] ?? [], tint: .red)
    let added = DiffLineView.attributed(body[1], changes: changes[1] ?? [], tint: .green)

    #expect(String(removed.characters) == body[0], "the accessibility text is the line itself")
    #expect(String(added.characters) == body[1])
    #expect(tinted(removed) == ["1"])
    #expect(tinted(added) == ["10"])
    #expect(added.runs.first { $0.backgroundColor != nil }?.backgroundColor == .green)
}

@Test
func aLineWithNoChangesIsDrawnUntinted() {
    let line = "+unpaired"
    let text = DiffLineView.attributed(line, changes: [], tint: .green)
    #expect(String(text.characters) == line)
    #expect(tinted(text).isEmpty)
}
