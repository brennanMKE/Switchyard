// TrackingSummaryTests.swift — the header's tracking status line (#0369)
//
// Imports YardUI WITHOUT `@testable`, same idiom as RefChipsTests:
// `TrackingSummary` is public, so everything asserted here is reachable at
// exactly the access level the app target sees. Every pinned string is a
// #0369 measurement or one of the cases the issue's Expected behavior names:
// measured `ahead: 12` → "On branch main · 12 ahead of origin/main"; detached
// with `headOID` `abcdef0` → "Detached HEAD at abcdef0".

import Testing
import YardGit
import YardUI

@Suite("TrackingSummary")
struct TrackingSummaryTests {

    /// The all-defaults `WhereAmI`: on `main`, up to date with
    /// `origin/main`, no operation in progress. Each test overrides only the
    /// fields its case needs.
    private func state(
        branch: String? = "main",
        upstream: String? = "origin/main",
        ahead: Int? = 0,
        behind: Int? = 0,
        isMidRebase: Bool = false,
        isMidMerge: Bool = false,
        isMidCherryPick: Bool = false,
        isMidRevert: Bool = false,
        hasConflicts: Bool = false,
        headOID: String = "a1b2c3d"
    ) -> WhereAmI {
        WhereAmI(
            branch: branch,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            isMidRebase: isMidRebase,
            isMidMerge: isMidMerge,
            isMidCherryPick: isMidCherryPick,
            isMidRevert: isMidRevert,
            stashCount: 0,
            untrackedCount: 0,
            unstagedCount: 0,
            stagedCount: 0,
            hasConflicts: hasConflicts,
            conflictCount: hasConflicts ? 1 : 0,
            headOID: headOID,
            rawHead: headOID
        )
    }

    // MARK: - Measured strings (#0369)

    @Test func aheadTwelveSpeaksTheMeasuredString() {
        #expect(TrackingSummary.text(for: state(ahead: 12))
                == "On branch main · 12 ahead of origin/main")
    }

    @Test func detachedHeadSpeaksTheMeasuredString() {
        #expect(TrackingSummary.text(for: state(
                    branch: nil, upstream: nil, ahead: nil, behind: nil,
                    headOID: "abcdef0"))
                == "Detached HEAD at abcdef0")
    }

    // MARK: - The other Expected-behavior cases

    @Test func upToDateStatesItExplicitly() {
        #expect(TrackingSummary.text(for: state())
                == "On branch main · up to date with origin/main")
    }

    @Test func behindOnlyCountsBehind() {
        #expect(TrackingSummary.text(for: state(ahead: 0, behind: 3))
                == "On branch main · 3 behind origin/main")
    }

    @Test func divergedStatesAheadThenBehind() {
        #expect(TrackingSummary.text(for: state(ahead: 2, behind: 5))
                == "On branch main · 2 ahead, 5 behind origin/main")
    }

    @Test func noUpstreamSaysSo() {
        #expect(TrackingSummary.text(for: state(upstream: nil, ahead: nil, behind: nil))
                == "On branch main · no upstream")
    }

    @Test func noCommitsYetOnAnEmptyRepository() {
        #expect(TrackingSummary.text(for: state(
                    branch: nil, upstream: nil, ahead: nil, behind: nil,
                    headOID: ""))
                == "No commits yet")
    }

    // MARK: - operationInProgress

    @Test func cleanStateNamesNoOperation() {
        #expect(TrackingSummary.operationInProgress(for: state()) == nil)
    }

    @Test func eachMidOperationSpeaksItsOwnSentence() {
        let cases: [(String, WhereAmI)] = [
            ("A rebase is in progress", state(isMidRebase: true)),
            ("A merge is in progress", state(isMidMerge: true)),
            ("A cherry-pick is in progress", state(isMidCherryPick: true)),
            ("A revert is in progress", state(isMidRevert: true)),
            ("There are unresolved conflicts", state(hasConflicts: true)),
        ]
        #expect(cases.count == 5)
        for (sentence, whereAmI) in cases {
            #expect(TrackingSummary.operationInProgress(for: whereAmI) == sentence)
        }
    }

    @Test func rebaseWinsOverConflictsWhenBothHold() {
        // Both a rebase and conflicts can hold at once (a conflicted rebase
        // left in progress); the operation names the rebase, which is the
        // thing blocking history changes.
        #expect(TrackingSummary.operationInProgress(for: state(isMidRebase: true, hasConflicts: true))
                == "A rebase is in progress")
    }
}
