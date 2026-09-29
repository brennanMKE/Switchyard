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

// MARK: - #0488: a changed line that opens with a combining mark

/// `"+\u{301}B".first` is the one `Character` `"+\u{301}"`, never `"+"`, so
/// a Character read of the marker made these lines unselectable. Measured on
/// `main` at `b00ddbeb`: `isSelectable` was `[]` for this hunk, and a click
/// on line 1 left the selection empty.
@Test func aChangedLineOpeningWithACombiningMarkIsSelectable() {
    let marked = Hunk(
        id: "h3", path: "f", oldStart: 1, oldCount: 2, newStart: 1, newCount: 2,
        header: "@@ -1,2 +1,2 @@", body: ["-\u{301}b", "+\u{301}B", " \u{301}c"])
    #expect((0..<3).filter { DiffLineSelection.isSelectable($0, in: marked) } == [0, 1])
    var selection = DiffLineSelection()
    selection.click(1, in: marked)
    #expect(selection.selectedLines(in: marked) == [1])
}

/// The diff pane tints a line by `DiffLineView.marker(of:)`. With the
/// `line.first` read on `main` at `b00ddbeb`, `"+\u{301}B"` and
/// `"-\u{301}b"` had no `+`/`-` marker and were drawn untinted.
@Test func theDiffPaneReadsTheMarkerOfALineOpeningWithACombiningMark() {
    #expect(DiffLineView.marker(of: "+\u{301}B") == "+")
    #expect(DiffLineView.marker(of: "-\u{301}b") == "-")
    #expect(DiffLineView.marker(of: " \u{301}c") == " ")
    #expect(DiffLineView.marker(of: "") == nil)
}

/// The Split sheet previews a hunk's first three changed lines. With the
/// `hasPrefix("+")` filter on `main` at `b00ddbeb`, the two marked lines
/// were skipped and the preview was `[3]`.
@Test func theSplitPreviewKeepsALineOpeningWithACombiningMark() {
    let marked = Hunk(
        id: "h4", path: "f", oldStart: 1, oldCount: 2, newStart: 1, newCount: 3,
        header: "@@ -1,2 +1,3 @@", body: [" a", "-\u{301}b", "+\u{301}B", "+X", "+Y"])
    #expect(SplitCommitSheet.previewLines(of: marked).map(\.offset) == [1, 2, 3])
}
