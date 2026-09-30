// IntralineDiffTests.swift — word-level highlights in a hunk (#0536)

import Testing
@testable import YardGit
@testable import YardUI

/// `body` with each changed range bracketed, one string per line.
private func marked(_ body: [String]) -> [String] {
    let changes = IntralineDiff.changes(in: body)
    return body.indices.map { index in
        IntralineDiff.segments(of: body[index], changes: changes[index] ?? [])
            .map { $0.isChanged ? "[\($0.text)]" : String($0.text) }
            .joined()
    }
}

@Test
func aPairedLineMarksOnlyTheWordsThatChanged() {
    #expect(marked([" ctx", "-let x = foo(1)", "-let y = 2", "+let x = foo(10)", "+let y = 2 // two"]) == [
        " ctx", "-let x = foo([1])", "-let y = 2", "+let x = foo([10])", "+let y = 2[ // two]",
    ])
}

@Test
func whitespaceIsAToken() {
    #expect(marked(["-bar(a,b);", "+bar(a, b);"]) == ["-bar(a,b);", "+bar(a,[ ]b);"])
}

@Test
func runsOfDifferentLengthsAreNotPaired() {
    #expect(IntralineDiff.changes(in: ["-a = 1", "-b = 2", "+a = 3"]).isEmpty)
    #expect(IntralineDiff.changes(in: ["-a = 1", " ctx", "+a = 3"]).isEmpty,
            "a context line between them ends the run")
}

@Test
func aRewrittenLineIsNotStriped() {
    #expect(IntralineDiff.changes(in: ["-completely different text here", "+nothing alike at all whatsoever"])
        .isEmpty)
}

@Test
func anOverlongLineIsNotCompared() {
    let long = String(repeating: "word ", count: 120)
    #expect(IntralineDiff.changes(in: ["-" + long + "a", "+" + long + "b"]).isEmpty)
    #expect(IntralineDiff.changes(in: ["-" + "short a", "+" + "short b"]).count == 2)
}

@Test
func theMarkerIsNeverPartOfAChange() {
    // A line opening with a combining mark fuses with its marker into one
    // Character (#0488); the mark is still content.
    #expect(marked(["-\u{301}x y", "+\u{301}x z"]) == ["-\u{301}x [y]", "+\u{301}x [z]"])
}

@Test
func segmentsCoverTheWholeLine() {
    let line = "+let x = foo(10)"
    let changes = IntralineDiff.changes(in: ["-let x = foo(1)", line])[1] ?? []
    #expect(IntralineDiff.segments(of: line, changes: changes).map(\.text).joined() == line)
    #expect(IntralineDiff.segments(of: line, changes: []) == [.init(text: line[...], isChanged: false)])
}

@Test
func aCombinedHunkHasNoHighlights() {
    let body = ["- ours x", "++ours y"]
    let combined = Hunk(id: "c", path: "f", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
                        header: "@@@ -1,1 -1,1 +1,1 @@@", body: body)
    let plain = Hunk(id: "p", path: "f", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
                     header: "@@ -1 +1 @@", body: ["-let a = 1", "+let a = 2"])
    #expect(IntralineDiff.changes(in: combined).isEmpty)
    #expect(IntralineDiff.changes(in: plain).count == 2)
}
