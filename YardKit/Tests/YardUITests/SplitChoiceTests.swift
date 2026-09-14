// SplitChoiceTests.swift — #0375: the Split sheet's pure state.
//
// Every case the planning pass measured on hand-built `FileDiff`/`Hunk`
// values, asserted exactly: the fewer-than-two-hunks refusal, the hunk
// listing, the stale-selection refusal, the unchanged-message-is-nil
// mapping, the edited messages, and the whitespace-only refusal. The ids
// are literals — `SplitChoice` resolves the selection against `hunks`
// only, so content-derived ids are unnecessary here.

import Testing
import YardGit
@testable import YardUI

/// One hunk with the id `id`, belonging to `path`.
private func hunk(_ id: String, path: String) -> Hunk {
    Hunk(
        id: id, path: path,
        oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
        header: "@@ -1,1 +1,1 @@",
        body: ["+changed"])
}

/// One file with no modes, not binary, and the given hunks.
private func file(_ path: String, hunks: [Hunk]) -> FileDiff {
    FileDiff(
        path: path, oldMode: nil, newMode: nil,
        isBinary: false, headerText: "diff --git a/\(path) b/\(path)\n", hunks: hunks)
}

/// The two-hunk, two-file state the later tests select from.
private func twoHunkChoice() -> SplitChoice {
    SplitChoice(
        commit: "c", message: "m",
        files: [
            file("a.txt", hunks: [hunk("h1", path: "a.txt")]),
            file("b.txt", hunks: [hunk("h2", path: "b.txt")]),
        ])
}

@Test func oneHunkRefusesWithNothingToSplit() {
    let choice = SplitChoice(
        commit: "c", message: "m",
        files: [file("a.txt", hunks: [hunk("h1", path: "a.txt")])])
    #expect(
        choice.unavailableReason == "This commit has only one change, so there’s nothing to split.")
    #expect(choice.arguments == nil)
}

@Test func emptyDiffRefusesWithNothingToSplit() {
    // A clean merge's `loadCommitDiff` returns an empty list (#0341) — the
    // sheet shows its nothing-to-split state there too.
    let choice = SplitChoice(commit: "c", message: "m", files: [])
    #expect(choice.unavailableReason != nil)
    #expect(choice.arguments == nil)
}

@Test func twoHunksListInFileOrderAndNeedASelection() {
    let choice = twoHunkChoice()
    #expect(choice.unavailableReason == nil)
    #expect(choice.hunks.map(\.id) == ["h1", "h2"])
    #expect(choice.arguments == nil)
}

@Test func staleSelectionYieldsNoArguments() {
    var choice = twoHunkChoice()
    choice.selectedHunkID = "stale"
    #expect(choice.arguments == nil)
}

@Test func selectingHunkWithUnchangedMessagesKeepsOriginalOnBothHalves() {
    var choice = twoHunkChoice()
    choice.selectedHunkID = "h2"
    #expect(
        choice.arguments
            == SplitArguments(
                commit: "c", hunkID: "h2", firstMessage: nil, secondMessage: nil))
}

@Test func editedFirstMessageRidesTheArgumentsVerbatim() {
    var choice = twoHunkChoice()
    choice.selectedHunkID = "h2"
    choice.firstMessage = "Just b\n"
    #expect(
        choice.arguments
            == SplitArguments(
                commit: "c", hunkID: "h2", firstMessage: "Just b\n", secondMessage: nil))
}

@Test func editedSecondMessageRidesTheArgumentsVerbatim() {
    var choice = twoHunkChoice()
    choice.selectedHunkID = "h1"
    choice.secondMessage = "The rest\n"
    #expect(
        choice.arguments
            == SplitArguments(
                commit: "c", hunkID: "h1", firstMessage: nil, secondMessage: "The rest\n"))
}

@Test func whitespaceOnlyMessageYieldsNoArguments() {
    var choice = twoHunkChoice()
    choice.selectedHunkID = "h2"
    choice.secondMessage = "   \n\t"
    #expect(choice.arguments == nil)
}
