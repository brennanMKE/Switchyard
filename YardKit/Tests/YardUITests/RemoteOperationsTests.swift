// RemoteOperationsTests.swift — the toolbar's Fetch, Pull and Push rules (#0456)
//
// Imports YardUI without `@testable`: everything asserted is public, the
// access level the app target sees. The stderr strings are git 2.54.0's,
// measured with LC_ALL=C (what GitProcess pins) against local bare remotes.

import Testing
import YardGit
import YardUI

@Suite("RemoteOperations")
struct RemoteOperationsTests {

    private func state(
        branch: String? = "main",
        upstream: String? = "origin/main",
        ahead: Int? = 1,
        isMidRebase: Bool = false,
        headOID: String = "a1b2c3d"
    ) -> WhereAmI {
        WhereAmI(
            branch: branch, upstream: upstream, ahead: ahead, behind: 0,
            isMidRebase: isMidRebase, isMidMerge: false, isMidCherryPick: false,
            isMidRevert: false, stashCount: 0, untrackedCount: 0, unstagedCount: 0,
            stagedCount: 0, hasConflicts: false, conflictCount: 0,
            headOID: headOID, rawHead: headOID)
    }

    @Test func everyOperationIsDisabledWithNoRemotes() {
        for operation in RemoteOperation.allCases {
            #expect(operation.disabledReason(for: state(), remotes: []) == "This repository has no remotes.")
        }
    }

    @Test func fetchIsEnabledWheneverThereIsARemoteEvenDetached() {
        #expect(RemoteOperation.fetch.disabledReason(
            for: state(branch: nil, upstream: nil), remotes: ["origin"]) == nil)
    }

    @Test func pullNeedsABranchWithAnUpstreamAndNoOperationInProgress() {
        let remotes = ["origin"]
        #expect(RemoteOperation.pull.disabledReason(for: state(), remotes: remotes) == nil)
        #expect(RemoteOperation.pull.disabledReason(
            for: state(branch: nil, upstream: nil), remotes: remotes) == "HEAD is detached.")
        #expect(RemoteOperation.pull.disabledReason(
            for: state(upstream: nil), remotes: remotes) == "This branch has no upstream to pull from.")
        #expect(RemoteOperation.pull.disabledReason(
            for: state(isMidRebase: true), remotes: remotes) == "A rebase is in progress.")
    }

    @Test func pushNeedsSomethingToPushButNotAnUpstream() {
        let remotes = ["origin"]
        #expect(RemoteOperation.push.disabledReason(for: state(), remotes: remotes) == nil)
        #expect(RemoteOperation.push.disabledReason(
            for: state(ahead: 0), remotes: remotes) == "Nothing to push.")
        // No upstream: the first push sets one, so it is enabled.
        #expect(RemoteOperation.push.disabledReason(
            for: state(upstream: nil, ahead: nil), remotes: remotes) == nil)
        #expect(RemoteOperation.push.disabledReason(
            for: state(branch: nil, upstream: nil), remotes: remotes) == "HEAD is detached.")
        #expect(RemoteOperation.push.disabledReason(
            for: state(upstream: nil, ahead: nil, headOID: ""), remotes: remotes)
            == "This branch has no commits yet.")
    }

    @Test func aCancellationPresentsNoAlert() {
        #expect(RemoteOperation.push.failure(for: CancellationError()) == nil)
    }

    @Test func aDivergedPullShowsGitsFatalLineWithoutHintsAndOurAdvice() throws {
        let stderr = """
            hint: Diverging branches can't be fast-forwarded, you need to either:
            hint:
            hint: \tgit merge --no-ff
            fatal: Not possible to fast-forward, aborting.

            """
        let failure = try #require(RemoteOperation.pull.failure(
            for: GitProcess.Failure.exited(code: 128, stderr: stderr, arguments: ["merge"])))
        #expect(failure.title == "Couldn’t Pull")
        #expect(failure.message.hasPrefix("fatal: Not possible to fast-forward, aborting.\n\n"))
        #expect(!failure.message.contains("hint:"))
        #expect(failure.message.contains("have diverged"))
    }

    @Test func aRejectedPushSaysPullFirstAndNeverForce() throws {
        let stderr = """
            To ../r.git
             ! [rejected]        main -> main (non-fast-forward)
            error: failed to push some refs to '../r.git'
            hint: Updates were rejected because the tip of your current branch is behind

            """
        let failure = try #require(RemoteOperation.push.failure(
            for: GitProcess.Failure.exited(code: 1, stderr: stderr, arguments: ["push"])))
        #expect(failure.title == "Couldn’t Push")
        #expect(failure.message.contains("[rejected]"))
        #expect(failure.message.contains("never force-pushes"))
        #expect(!failure.message.contains("hint:"))
    }

    @Test func aMissingCredentialSaysWhereToAddOne() throws {
        let stderr = "fatal: could not read Username for 'https://example.invalid': terminal prompts disabled\n"
        let failure = try #require(RemoteOperation.fetch.failure(
            for: GitProcess.Failure.exited(code: 128, stderr: stderr, arguments: ["fetch"])))
        #expect(failure.message.contains("terminal prompts disabled"))
        #expect(failure.message.contains("credential helper or ssh-agent"))
    }

    @Test func aRefusalShowsItsDescription() throws {
        let failure = try #require(RemoteOperation.pull.failure(for: RemoteSync.Refusal.detachedHead))
        #expect(failure == CommitActionFailure(
            title: "Couldn’t Pull", message: "HEAD is detached. Check out a branch first."))
    }
}

/// #0456: the Edit menu names a fetch and a pull entry.
@Suite("RemoteOperations titles")
struct RemoteOperationTitlesTests {
    @Test func fetchAndPullEntriesHaveUndoAndRedoTitles() {
        #expect(JournalMenuTitles.undo(operation: "fetch") == "Undo Fetch")
        #expect(JournalMenuTitles.redo(operation: "fetch") == "Redo Fetch")
        #expect(JournalMenuTitles.undo(operation: "pull") == "Undo Pull")
        #expect(JournalMenuTitles.redo(operation: "pull") == "Redo Pull")
    }
}
