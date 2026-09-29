// DiffLineSelectionTests.swift — the Changes view's line selection (#0479)

import Testing
@testable import YardGit
@testable import YardUI

/// Body: 0 context, 1 `-`, 2 `+`, 3 `+`, 4 context, 5 `-`, 6 marker.
private let hunk = Hunk(
    id: "h1", path: "f", oldStart: 1, oldCount: 4, newStart: 1, newCount: 5,
    header: "@@ -1,4 +1,5 @@",
    body: [" a", "-b", "+B", "+X", " c", "-d", "\\ No newline at end of file"])
private let other = Hunk(
    id: "h2", path: "f", oldStart: 20, oldCount: 1, newStart: 21, newCount: 1,
    header: "@@ -20 +21 @@", body: ["-y", "+Y"])

@Test func onlyAddedAndRemovedLinesAreSelectable() {
    #expect((0..<8).filter { DiffLineSelection.isSelectable($0, in: hunk) } == [1, 2, 3, 5])
}

@Test func aClickSelectsOneLineAndASecondClickOnItClears() {
    var selection = DiffLineSelection()
    selection.click(2, in: hunk)
    #expect(selection.selectedLines(in: hunk) == [2])
    selection.click(3, in: hunk)
    #expect(selection.selectedLines(in: hunk) == [3])
    selection.click(3, in: hunk)
    #expect(selection == DiffLineSelection())
}

@Test func aClickOnContextClearsAndAModifiedClickOnContextDoesNothing() {
    var selection = DiffLineSelection()
    selection.click(2, in: hunk)
    selection.click(0, in: hunk, modifier: .shift)
    selection.click(6, in: hunk, modifier: .command)
    #expect(selection.selectedLines(in: hunk) == [2])
    selection.click(4, in: hunk)
    #expect(selection == DiffLineSelection())
}

@Test func shiftClickSelectsTheChangedLinesFromTheAnchor() {
    var selection = DiffLineSelection()
    selection.click(5, in: hunk)
    selection.click(1, in: hunk, modifier: .shift)
    #expect(selection.selectedLines(in: hunk) == [1, 2, 3, 5], "context line 4 is skipped")
    selection.click(3, in: hunk, modifier: .shift)
    #expect(selection.selectedLines(in: hunk) == [3, 5], "the anchor stays at 5")
}

@Test func commandClickTogglesLines() {
    var selection = DiffLineSelection()
    selection.click(1, in: hunk)
    selection.click(5, in: hunk, modifier: .command)
    #expect(selection.selectedLines(in: hunk) == [1, 5])
    selection.click(1, in: hunk, modifier: .command)
    #expect(selection.selectedLines(in: hunk) == [5])
    selection.click(5, in: hunk, modifier: .command)
    #expect(selection == DiffLineSelection())
}

@Test func aClickInAnotherHunkStartsANewSelection() {
    var selection = DiffLineSelection()
    selection.click(1, in: hunk)
    selection.click(1, in: other, modifier: .shift)
    #expect(selection.selectedLines(in: hunk) == [])
    #expect(selection.selectedLines(in: other) == [1])
    #expect(selection.isSelected(1, in: other))
    #expect(!selection.isSelected(1, in: hunk))
}

@Test func aDragSelectsTheChangedLinesItCrosses() {
    var selection = DiffLineSelection()
    selection.drag(from: 5, to: 2, in: hunk)
    #expect(selection.selectedLines(in: hunk) == [2, 3, 5])
    selection.click(1, in: hunk, modifier: .shift)
    #expect(selection.selectedLines(in: hunk) == [1, 2, 3, 5], "a drag sets the anchor to its start")
    selection.drag(from: 0, to: 0, in: hunk)
    #expect(selection.selectedLines(in: hunk) == [1, 2, 3, 5], "a drag over context changes nothing")
}
