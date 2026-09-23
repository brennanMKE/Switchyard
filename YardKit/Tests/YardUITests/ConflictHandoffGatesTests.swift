// ConflictHandoffGatesTests.swift — the header's Continue/Abort gates (#0394)
//
// Pure tests over hand-built `WhereAmI` values, beside TrackingSummaryTests:
// `ConflictHandoff` is public in YardGit, so everything asserted here is
// reachable at exactly the access level `RepositoryHeaderView` sees — no
// `@testable`. The gates read `WhereAmI` fields only, what #0369 shipped, so
// these decide the rendering rules without a repository.

import Foundation
import Testing
import YardGit

@Suite("ConflictHandoffGates")
struct ConflictHandoffGatesTests {

    /// The all-defaults `WhereAmI`: on `main`, no operation, no conflicts.
    /// Each test overrides only the fields its case needs.
    private func state(
        branch: String? = "main",
        isMidRebase: Bool = false,
        isMidMerge: Bool = false,
        isMidCherryPick: Bool = false,
        isMidRevert: Bool = false
    ) -> WhereAmI {
        WhereAmI(
            branch: branch,
            upstream: nil,
            ahead: nil,
            behind: nil,
            isMidRebase: isMidRebase,
            isMidMerge: isMidMerge,
            isMidCherryPick: isMidCherryPick,
            isMidRevert: isMidRevert,
            stashCount: 0,
            untrackedCount: 0,
            unstagedCount: 0,
            stagedCount: 0,
            hasConflicts: false,
            conflictCount: 0,
            headOID: "a1b2c3d",
            rawHead: "a1b2c3d"
        )
    }

    @Test func kindNamesSpellGitSownSubcommandWords() {
        let all = ConflictHandoff.Kind.allCases
        #expect(all.count == 4, "revert, cherry-pick, merge, rebase — a new kind must be named here")
        for kind in all {
            let name = ConflictHandoff.name(of: kind)
            #expect(!name.isEmpty)
            #expect(!name.contains(" "), "the name is one git word")
            #expect(name.first?.isUppercase == false, "the lowercase form is the dialog's noun")
        }
        #expect(ConflictHandoff.name(of: .revert) == "revert")
        #expect(ConflictHandoff.name(of: .cherryPick) == "cherry-pick")
        #expect(ConflictHandoff.name(of: .merge) == "merge")
        #expect(ConflictHandoff.name(of: .rebase) == "rebase")
    }

    @Test func inProgressKindFollowsTheTrackingSummaryPrecedence() {
        #expect(ConflictHandoff.inProgressKind(for: state()) == nil)
        let oneFlag: [(WhereAmI, ConflictHandoff.Kind)] = [
            (state(isMidRebase: true), .rebase),
            (state(isMidMerge: true), .merge),
            (state(isMidCherryPick: true), .cherryPick),
            (state(isMidRevert: true), .revert),
        ]
        #expect(oneFlag.count == ConflictHandoff.Kind.allCases.count,
                "every kind is reachable from exactly one flag")
        for (whereAmI, kind) in oneFlag {
            #expect(ConflictHandoff.inProgressKind(for: whereAmI) == kind)
        }
        // The precedence rebase > merge > cherry-pick > revert, read off the
        // same flags `TrackingSummary.operationInProgress` reads.
        #expect(ConflictHandoff.inProgressKind(for: state(
                    isMidRebase: true, isMidMerge: true,
                    isMidCherryPick: true, isMidRevert: true)) == .rebase)
        #expect(ConflictHandoff.inProgressKind(for: state(
                    isMidMerge: true, isMidCherryPick: true, isMidRevert: true)) == .merge)
        #expect(ConflictHandoff.inProgressKind(for: state(
                    isMidCherryPick: true, isMidRevert: true)) == .cherryPick)
    }

    @Test func continuableKindIsNilForTheDetachedReplayPick() {
        // The Rewrite family's detached replay: a pick in progress with HEAD
        // on no branch. Continuing would finish the picks with the branch
        // unmoved — the ref move lives in Rewrite.perform's memory.
        #expect(ConflictHandoff.continuableKind(
            for: state(branch: nil, isMidCherryPick: true)) == nil)
        #expect(ConflictHandoff.inProgressKind(
            for: state(branch: nil, isMidCherryPick: true)) == .cherryPick,
                "the same state still gets Abort")
    }

    @Test func continuableKindIsNotNilForAttachedPickMergeRebaseRevert() throws {
        let attachedPick = try #require(ConflictHandoff.continuableKind(
            for: state(isMidCherryPick: true)))
        #expect(attachedPick == .cherryPick)
        let merge = try #require(ConflictHandoff.continuableKind(for: state(isMidMerge: true)))
        #expect(merge == .merge)
        let rebase = try #require(ConflictHandoff.continuableKind(for: state(isMidRebase: true)))
        #expect(rebase == .rebase)
        let revert = try #require(ConflictHandoff.continuableKind(for: state(isMidRevert: true)))
        #expect(revert == .revert)
    }

    @Test func continuableKindNamesARebaseEvenOverADetachedPick() throws {
        // A rebase's own picks ride the rebase state; the rebase completes
        // itself with `rebase --continue` whatever the pick flags read.
        let kind = try #require(ConflictHandoff.continuableKind(
            for: state(branch: nil, isMidRebase: true, isMidCherryPick: true)))
        #expect(kind == .rebase)
    }
}
