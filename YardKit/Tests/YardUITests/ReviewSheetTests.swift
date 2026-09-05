// ReviewSheetTests.swift — the review sheet's model layer (#0055, rounds 2–3)
//
// This target imports YardUI WITHOUT `@testable`, so everything asserted
// here is reachable at exactly the access level the app target sees. The
// sheet is a pure function of `ReviewSheetModel`, so every state is asserted
// through the model — no test renders anything, touches AppKit, or reaches
// the XPC layer: the store below is the real `PendingReviewStore`, wired to
// `ReviewCenter` exactly as the app target wires it.
//
// No test reads a clock (Rule 7c): registration and outcome waits are
// bounded polls with a 60 s ceiling that returns the moment the state
// arrives, and the timeout test arms the store's own one-second timeout
// rather than measuring elapsed time.

import Foundation
import Testing
import YardGit
import YardKit
import YardUI

@MainActor
@Suite("ReviewSheet")
struct ReviewSheetTests {

    private struct WaitTimeout: Error {}
    private struct UnexpectedOutcome: Error {
        let outcome: RepositoryTabs.Outcome
    }

    // MARK: - Fixtures

    /// One file's diff, shaped like #0082's Detail-pane fixtures so the
    /// sheet's seeding source matches what `FileDiffView` renders.
    private func fixtureFile(path: String) -> FileDiff {
        FileDiff(
            path: path,
            oldMode: nil,
            newMode: nil,
            isBinary: false,
            headerText: "diff --git a/\(path) b/\(path)\n",
            hunks: [
                Hunk(
                    id: "hunk-\(path)",
                    path: path,
                    oldStart: 1, oldCount: 2, newStart: 1, newCount: 3,
                    header: "@@ -1,2 +1,3 @@",
                    body: [" line one", "+line two (added)", " line three"]
                ),
            ])
    }

    private func pending(
        commonDir: String,
        selector: ReviewSelector = .staged,
        timeoutSeconds: Int = 3600
    ) -> PendingReviewStore.Pending {
        PendingReviewStore.Pending(
            id: UUID(),
            request: ReviewRequest(
                commonDir: commonDir,
                selector: selector,
                timeoutSeconds: timeoutSeconds))
    }

    /// Bounded wait for a centre state, running ON the main actor so the
    /// fetch closure may read @MainActor state. Throws when the state never
    /// arrives, rather than hanging.
    private func waitUntil(
        timeout: Duration = .seconds(300),
        _ fetch: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if fetch() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitTimeout()
    }

    private func decidedReply(from outcome: ReviewOutcome) -> ReviewReply? {
        guard case .decided(let reply) = outcome else { return nil }
        return reply
    }

    private func openedTab(from outcome: RepositoryTabs.Outcome) throws -> RepositoryTab {
        guard case .opened(let tab) = outcome else { throw UnexpectedOutcome(outcome: outcome) }
        return tab
    }

    // MARK: - Pending state

    @Test func pendingSheetShowsTheDiffWithDecisionsEnabled() {
        let model = ReviewSheetModel(pending: pending(commonDir: "/repos/a/.git"))
        #expect(model.outcome == nil, "a fresh sheet is pending")
        #expect(model.decisionsEnabled, "the decision buttons enable while pending")
        #expect(model.selectorLabel == "Staged changes")
        #expect(model.files == nil, "no diff until the app side attaches one")

        model.attachDiff(originPath: "/repos/a", files: [fixtureFile(path: "Sources/A.swift")], errorMessage: nil)
        #expect(model.files?.count == 1, "the resolved diff is the render source")
        #expect(model.diffError == nil)
        #expect(model.decisionsEnabled)
        #expect(model.outcomeLabel == nil, "a pending sheet shows no outcome banner")
    }

    @Test func rangeSelectorLabelsItselfWithTheRange() {
        let model = ReviewSheetModel(
            pending: pending(commonDir: "/repos/a/.git", selector: .range("main..HEAD")))
        #expect(model.selectorLabel == "main..HEAD")
    }

    @Test func diffFailureIsDistinctFromAnEmptyDiff() {
        let model = ReviewSheetModel(pending: pending(commonDir: "/repos/a/.git"))
        model.attachDiff(originPath: "/repos/a", files: [], errorMessage: "git exited 128")
        #expect(model.diffError == "git exited 128", "the failure is what renders")
        #expect(model.files == nil, "a failed diff must not read as empty")

        // A later attach without an error resolves the sheet to a
        // legitimately empty diff.
        model.attachDiff(originPath: "/repos/a", files: [], errorMessage: nil)
        #expect(model.diffError == nil)
        #expect(model.files == [], "a genuinely empty diff is a legitimate surface")
    }

    // MARK: - Decisions round-trip through the store

    @Test func approveCarriesTheMessageAndNothingElse() async throws {
        let store = PendingReviewStore()
        let center = ReviewCenter(store: store)
        let request = ReviewRequest(commonDir: "/repos/a/.git", selector: .staged, timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !center.sheets.isEmpty }
        let model = try #require(center.sheets.first, "registration must create the sheet")
        #expect(model.commonDir == request.commonDir)

        model.message = "ship it"
        #expect(model.decide(.approve))

        let reply = try #require(await decidedReply(from: outcome), "the reply must be a decision")
        #expect(reply.decision == .approve)
        #expect(reply.message == "ship it")
        #expect(reply.comments.isEmpty)
        #expect(reply.editedPatch == nil)
        try await waitUntil { center.sheets.isEmpty }
        #expect(center.sheets.isEmpty, "a decided sheet is dismissed by the centre")
    }

    @Test func rejectCarriesAPerHunkComment() {
        let model = ReviewSheetModel(pending: pending(commonDir: "/repos/a/.git"))
        model.attachDiff(originPath: "/repos/a", files: [fixtureFile(path: "Sources/A.swift")], errorMessage: nil)

        model.addComment(path: "Sources/A.swift", hunkID: "hunk-1", text: "   ")
        #expect(model.comments.isEmpty, "an empty comment must not compose")

        let comment = ReviewComment(path: "Sources/A.swift", hunkID: "hunk-1", line: nil, text: "why here?")
        model.addComment(path: comment.path, hunkID: comment.hunkID, line: comment.line, text: comment.text)
        #expect(model.comments == [comment])

        model.removeComment(comment)
        #expect(model.comments.isEmpty, "the ✕ affordance removes a composed comment")
        model.addComment(path: comment.path, hunkID: comment.hunkID, line: comment.line, text: comment.text)

        let reply = model.composedReply(for: .reject)
        #expect(reply.decision == .reject)
        #expect(reply.message == nil, "an empty message is absent, never null")
        #expect(reply.comments == [comment])
        #expect(reply.editedPatch == nil, "a reject carries no patch")
    }

    /// Amend now APPLIES the edited patch to the index (round 3) through the
    /// centre's real engine wiring (`stagePatch` at the request's resolved
    /// origin), so this test needs a real fixture repository: the patch the
    /// sheet seeds is the diff of a worktree change whose preimage is still
    /// what the index holds, so `git apply --cached` succeeds and the index
    /// demonstrably gains the change.
    @Test func amendAppliesTheEditedPatchToTheIndexAndRoundTripsIt() async throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("base", files: ["f.txt": "one\ntwo\nthree\n"])])
        // The change under review: in the worktree, NOT in the index — the
        // patch's preimage matches the index, so amend's `git apply --cached`
        // succeeds and the amended index gains the edit.
        try "one\ntwo\nthree\nfour\n".write(
            to: repo.url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let files = try await listHunks(at: repo.url.path, area: .unstaged)
        #expect(files.first?.hunks.first?.body.contains("+four") == true,
                "the fixture's change must be the unstaged diff under review")

        let store = PendingReviewStore()
        let center = ReviewCenter(store: store)
        let request = ReviewRequest(commonDir: repo.url.path, selector: .staged, timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !center.sheets.isEmpty }
        let model = try #require(center.sheets.first)

        model.attachDiff(originPath: repo.url.path, files: files, errorMessage: nil)
        let seed = model.editedPatch
        #expect(!seed.isEmpty, "the patch editor is seeded from the resolved diff")
        #expect(seed.contains("+four"), "the seed is the real patch text git apply will receive")

        #expect(model.decide(.amend))
        #expect(model.applyError == nil, "a successful apply is not a failure")

        let reply = try #require(await decidedReply(from: outcome))
        #expect(reply.decision == .amend)
        #expect(reply.editedPatch == seed, "the reply still carries the patch for the agent's record")
        #expect(reply.comments.isEmpty)
        try await waitUntil { center.sheets.isEmpty }

        // The amended index IS the reviewed state: the staged listing now
        // holds exactly what the patch applied.
        let staged = try await listHunks(at: repo.url.path, area: .staged)
        let stagedFile = try #require(staged.first, "the index must hold the applied patch")
        #expect(stagedFile.path == "f.txt")
        #expect(stagedFile.hunks.first?.body.contains("+four") == true,
                "the amended index gained the edited patch's line")
        #expect(model.composedReply(for: .approve).editedPatch == nil,
                "a non-amend decision never carries the patch")
    }

    /// A patch whose preimage the index does not hold fails `git apply
    /// --cached`; the failure is a typed outcome on the sheet and the pending
    /// stays receivable — never a crash, never a resolution, never a silent
    /// success.
    @Test func staleAmendPatchSurfacesAsATypedErrorAndLeavesThePendingIntact() async throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("base", files: ["f.txt": "one\n"])])

        let store = PendingReviewStore()
        let center = ReviewCenter(store: store)
        let request = ReviewRequest(commonDir: repo.url.path, selector: .staged, timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !center.sheets.isEmpty }
        let model = try #require(center.sheets.first)
        model.attachDiff(originPath: repo.url.path, files: [], errorMessage: nil)

        // The human hand-writes a patch whose context the index ("one\n")
        // does not hold — the stale-patch shape the apply path must refuse.
        model.editedPatch = """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -1 +1 @@
        -absent context line
        +edited line
        """
        #expect(!model.decide(.amend), "a failed apply must not resolve the review")
        #expect(model.applyError != nil, "the failure is typed to the sheet, not silent")
        #expect(model.decisionsEnabled, "the human can still retry or choose another decision")

        // The pending is intact: a later decision still resolves it, so the
        // failed amend never consumed the review.
        #expect(store.resolve(id: model.pendingID, decision: ReviewReply(decision: .approve)))
        #expect(await outcome == .decided(ReviewReply(decision: .approve)))
    }

    /// An empty patch is nothing to apply: amend resolves without an apply
    /// call (the centre's engine wiring is never invoked) and the reply
    /// carries no patch — "no patch" is absent, never null.
    @Test func amendWithAnEmptyPatchResolvesWithoutApplying() async throws {
        let store = PendingReviewStore()
        let center = ReviewCenter(store: store)
        let request = ReviewRequest(commonDir: "/repos/a/.git", selector: .staged, timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !center.sheets.isEmpty }
        let model = try #require(center.sheets.first)
        // No diff ever attaches, so the seed stays empty; the origin points
        // nowhere real, which is safe because an empty patch never applies.
        model.attachDiff(originPath: "/repos/none", files: [], errorMessage: nil)
        #expect(model.editedPatch.isEmpty)

        #expect(model.decide(.amend))
        #expect(model.applyError == nil, "nothing to apply is not a failure")
        let reply = try #require(await decidedReply(from: outcome))
        #expect(reply.decision == .amend)
        #expect(reply.editedPatch == nil, "an empty patch is absent on the wire, never null")
    }

    /// A model with a resolver but no apply path refuses a non-empty amend
    /// with a typed error — the "never a silent success" contract does not
    /// depend on the centre's wiring existing.
    @Test func amendWithoutAWiredApplyPathRefusesWithATypedError() {
        let model = ReviewSheetModel(pending: pending(commonDir: "/repos/a/.git"))
        model.onDecide = { _ in true }
        model.editedPatch = "diff --git a/f.txt b/f.txt\n"
        #expect(!model.decide(.amend), "an unwired apply must not resolve the review")
        #expect(model.applyError != nil, "the refusal is typed to the sheet")
    }

    // MARK: - Per-line comments (round 3's picker)

    /// The picker's data: context and added lines numbered from `newStart`;
    /// a deleted line occupies no new-side line and is not offered.
    @Test func lineChoicesListTheNewSideLinesOfTheHunkBody() {
        let hunk = Hunk(
            id: "h", path: "f.txt",
            oldStart: 2, oldCount: 4, newStart: 3, newCount: 4,
            header: "@@ -2,4 +3,4 @@",
            body: [" keep", "+added", "-removed", " tail"])
        let choices = ReviewSheetModel.lineChoices(for: hunk)
        #expect(choices.count == 3, "a deleted line has no new-side number and is not offered")
        #expect(choices.map(\.number) == [3, 4, 5])
        #expect(choices.map(\.label) == ["3  keep", "4  added", "5  tail"])
    }

    /// A comment composed with a picked line rides the wire on
    /// `ReviewComment.line` — the per-line affordance feeds the same
    /// structured data the issue pins.
    @Test func perLineCommentCarriesThePickedLineOnTheWire() throws {
        let model = ReviewSheetModel(pending: pending(commonDir: "/repos/a/.git"))
        let file = fixtureFile(path: "Sources/A.swift")
        model.attachDiff(originPath: "/repos/a", files: [file], errorMessage: nil)

        let hunk = try #require(file.hunks.first)
        let choices = ReviewSheetModel.lineChoices(for: hunk)
        #expect(!choices.isEmpty, "the fixture hunk must offer its new-side lines")
        let picked = try #require(choices.first { $0.number == 2 },
                                  "the fixture's added line is new-side line 2")
        #expect(picked.label == "2  line two (added)")

        model.addComment(path: file.path, hunkID: hunk.id, line: picked.number, text: "on the added line")
        let reply = model.composedReply(for: .reject)
        #expect(reply.comments.count == 1)
        #expect(reply.comments.first?.line == 2, "the picked line rides the wire")
        #expect(reply.comments.first?.hunkID == hunk.id)
        #expect(reply.comments.first?.text == "on the added line")
    }

    // MARK: - The store's typed outcomes, reflected by the sheet

    @Test func timedOutOutcomeShowsTheBannerAndDisablesDecisions() async throws {
        let store = PendingReviewStore()
        let center = ReviewCenter(store: store)
        let request = ReviewRequest(commonDir: "/repos/t/.git", selector: .staged, timeoutSeconds: 1)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !center.sheets.isEmpty }
        try await waitUntil { center.sheets.first?.outcome == .timedOut }
        #expect(await outcome == .timedOut)

        let model = try #require(center.sheets.first)
        #expect(!model.decisionsEnabled, "a timed-out sheet must not compose a reply")
        #expect(model.outcomeLabel != nil, "the banner names the store's outcome")
        #expect(center.sheets.count == 1, "a timed-out sheet stays until the human closes it")

        model.close()
        #expect(center.sheets.isEmpty, "the banner's Close dismisses the sheet")
    }

    @Test func supersededOutcomeReachesTheOlderSheetAndTheNewerStaysPending() async throws {
        let store = PendingReviewStore()
        let center = ReviewCenter(store: store)
        let dir = "/repos/s/.git"

        async let first = store.awaitDecision(
            for: ReviewRequest(commonDir: dir, selector: .staged, timeoutSeconds: 60))
        try await waitUntil { !center.sheets.isEmpty }
        let oldID = try #require(store.pendingReviews.first?.id)

        async let secondOutcome = store.awaitDecision(
            for: ReviewRequest(commonDir: dir, selector: .range("main..HEAD"), timeoutSeconds: 60))
        try await waitUntil { center.sheets.count == 2 }
        #expect(await first == .superseded)

        let oldModel = try #require(
            center.sheets.first { $0.pendingID == oldID },
            "the replaced sheet stays until the human closes its banner")
        #expect(oldModel.outcome == .superseded)
        #expect(oldModel.decisionsEnabled == false)
        #expect(oldModel.outcomeLabel != nil)

        let active = try #require(
            center.activeSheet(forRepositoryPath: dir),
            "the per-repository binding names the NEWER sheet")
        #expect(active.pendingID != oldModel.pendingID)
        #expect(active.outcome == nil)

        #expect(active.decide(.approve))
        #expect(await secondOutcome == .decided(ReviewReply(decision: .approve)))
    }

    // MARK: - Per-pending binding (two repositories, two sheets)

    @Test func twoPendingsBindToTheirOwnRepositoriesIndependently() async throws {
        let store = PendingReviewStore()
        let center = ReviewCenter(store: store)
        let dirA = "/repos/a/.git"
        let dirB = "/repos/b/.git"

        async let outcomeA = store.awaitDecision(
            for: ReviewRequest(commonDir: dirA, selector: .staged, timeoutSeconds: 60))
        async let outcomeB = store.awaitDecision(
            for: ReviewRequest(commonDir: dirB, selector: .staged, timeoutSeconds: 60))
        try await waitUntil { center.sheets.count == 2 }

        let fileA = fixtureFile(path: "Sources/A.swift")
        let fileB = fixtureFile(path: "Sources/B.swift")
        center.attachDiff(commonDir: dirA, originPath: "/repos/a", files: [fileA], errorMessage: nil)
        center.attachDiff(commonDir: dirB, originPath: "/repos/b", files: [fileB], errorMessage: nil)

        let sheetA = try #require(center.activeSheet(forRepositoryPath: dirA))
        let sheetB = try #require(center.activeSheet(forRepositoryPath: dirB))
        #expect(sheetA.pendingID != sheetB.pendingID, "each repository binds to its own sheet")
        #expect(sheetA.commonDir == dirA)
        #expect(sheetA.files == [fileA], "sheet A renders A's diff")
        #expect(sheetB.files == [fileB], "sheet B renders B's diff")
        #expect(center.activeSheet(forRepositoryPath: "/repos/a/sub/dir")?.pendingID == sheetA.pendingID,
                "a subdirectory of the repository binds to its sheet")

        #expect(sheetA.decide(.approve))
        try await waitUntil { center.sheets.count == 1 }
        #expect(center.sheets.first?.pendingID == sheetB.pendingID,
                "deciding one leaves the other pending")
        #expect(center.sheets.first?.decisionsEnabled == true)
        #expect(await outcomeA == .decided(ReviewReply(decision: .approve)))

        // Resolve B through the store directly so the test ends without
        // waiting out B's own timeout.
        #expect(store.resolve(commonDir: dirB, decision: ReviewReply(decision: .reject)))
        #expect(await outcomeB == .decided(ReviewReply(decision: .reject)))
    }

    // MARK: - Tab routing (#0084 focus-or-open)

    @Test func routeToTabFocusesAnOpenRepositoryAndOpensAMissingOne() async throws {
        let contextA = WorktreeContext(
            topLevel: "/repos/a", gitDir: "/repos/a/.git",
            commonDir: "/repos/a/.git", worktreeName: nil)
        let contextB = WorktreeContext(
            topLevel: "/repos/b", gitDir: "/repos/b/.git",
            commonDir: "/repos/b/.git", worktreeName: nil)
        let contexts = ["/repos/a": contextA, "/repos/b": contextB]
        let tabs = RepositoryTabs(resolver: { path in
            guard let context = contexts[path] else {
                throw WorktreeContext.Error.notARepository(path: path, detail: "fixture resolver")
            }
            return context
        })
        let windowStore = WindowStore()

        let store = PendingReviewStore()
        let center = ReviewCenter(store: store)
        async let outcome = store.awaitDecision(
            for: ReviewRequest(commonDir: contextA.commonDir, selector: .staged, timeoutSeconds: 60))
        try await waitUntil { !center.sheets.isEmpty }

        // No tab for this repository yet: focus-or-open OPENS one.
        let opened = center.routeToTab(for: contextA, tabs: tabs, windowStore: windowStore)
        let tabA = try openedTab(from: opened)
        #expect(tabs.tabs.count == 1)
        #expect(tabs.selectedTabID == tabA.id)
        #expect(windowStore.windows[0].tabIDs == [tabA.id],
                "a new tab attaches to the frontmost window")

        let model = try #require(center.sheets.first)
        try await waitUntil { model.tabID == tabA.id }
        #expect(center.activeSheet(forTabID: tabA.id)?.pendingID == model.pendingID,
                "the sheet binds to the tab it was routed to")

        // A second repository's review opens a second tab...
        _ = try openedTab(from: center.routeToTab(for: contextB, tabs: tabs, windowStore: windowStore))
        #expect(tabs.tabs.count == 2)

        // ...and routing the FIRST repository again focuses — never a
        // second tab for the same repository.
        let refocused = center.routeToTab(for: contextA, tabs: tabs, windowStore: windowStore)
        guard case .focusedExisting = refocused else { throw UnexpectedOutcome(outcome: refocused) }
        #expect(tabs.tabs.count == 2, "focus-or-open never duplicates a tab")
        #expect(tabs.selectedTabID == tabA.id)

        #expect(model.decide(.approve))
        #expect(await outcome == .decided(ReviewReply(decision: .approve)))
    }

    // MARK: - Dark mode

    /// The sheet renders semantic colours only — assert by construction,
    /// guardian-style: the source must not contain a single hardcoded
    /// colour literal.
    @Test func reviewSheetUsesSemanticColoursOnly() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit
            .appendingPathComponent("Sources/YardUI/ReviewSheet.swift")
        let source = try String(contentsOfFile: url.path, encoding: .utf8)
        #expect(!source.isEmpty, "the sheet's source must be readable from the checkout")
        for forbidden in ["Color(red:", "Color(hue:", "Color(.sRGB", "Color(.displayP3", "Color(white:"] {
            #expect(!source.contains(forbidden), "hardcoded colour \(forbidden) — semantic colours only")
        }
    }
}
