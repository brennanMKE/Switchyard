// AbandonedSheetTests.swift — the abandoned state in the sheet models
// (#0349)
//
// This target imports YardUI WITHOUT `@testable`, so everything asserted
// here is reachable at exactly the access level the app target sees. The
// abandonment arrives through the real stores' change hooks, wired to the
// centres exactly as the app target wires them.
//
// No test reads a clock (Rule 7c): every wait is a bounded poll that
// returns the moment the state arrives. The bound is generous (180 s) —
// measured 2026-09-09: under the full 129-suite parallel run, the stores'
// own 1 s reaper timers have starved past 60 s (the #0351 class), so the
// deadline must be wide enough that lateness is not failure; the poll
// still returns in ~1 s in the common case.

import Foundation
import Testing
import YardKit
import YardUI

@MainActor
@Suite("Abandoned sheets (#0349)")
struct AbandonedSheetTests {

    private struct WaitTimeout: Error {}

    private func waitUntil(
        timeout: Duration = .seconds(180),
        _ fetch: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if fetch() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitTimeout()
    }

    // MARK: - Review

    /// The abandoned banner shows, decisions STAY enabled (the pending is
    /// orphaned, not answered), and a decision after abandonment still
    /// resolves — dismissing the sheet through the centre's decided path.
    @Test func abandonedReviewBannersButKeepsDecisionsEnabledAndStillResolves() async throws {
        let store = PendingReviewStore()
        let center = ReviewCenter(store: store)
        let owner = PendingOwner()
        let request = ReviewRequest(
            commonDir: "/repos/a/.git", selector: .staged, timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request, owner: owner)
        try await waitUntil { center.sheets.count == 1 }
        let model = try #require(center.sheets.first)
        #expect(model.decisionsEnabled, "a pending sheet is decidable")

        store.abandonAll(ownedBy: owner)
        try await waitUntil { model.isAbandoned }
        #expect(model.outcome == nil, "abandonment is not a terminal outcome")
        #expect(
            model.outcomeLabel ==
                "The asking agent went away — you can still decide; it will be recorded as a note.")
        #expect(model.decisionsEnabled,
                "the banner says the human may still decide — the buttons must agree")

        #expect(model.decide(.approve), "the decision after abandonment goes through")
        let reply = ReviewReply(decision: .approve, message: nil, comments: [], editedPatch: nil)
        #expect(await outcome == .decided(reply))
        try await waitUntil { center.sheets.isEmpty }
        #expect(center.sheets.isEmpty, "the decided sheet dismisses even after an abandonment")
    }

    /// The pending's own timer remains the reaper: a terminal outcome after
    /// abandonment still lands, disables the decisions, and names itself in
    /// the banner. SHORT real timeout (1 s).
    @Test func theReaperStillEndsAnAbandonedReview() async throws {
        let store = PendingReviewStore()
        let center = ReviewCenter(store: store)
        let owner = PendingOwner()
        let request = ReviewRequest(
            commonDir: "/repos/a/.git", selector: .staged, timeoutSeconds: 1)

        async let outcome = store.awaitDecision(for: request, owner: owner)
        try await waitUntil { center.sheets.count == 1 }
        let model = try #require(center.sheets.first)
        store.abandonAll(ownedBy: owner)
        try await waitUntil { model.isAbandoned }

        #expect(await outcome == .timedOut, "the abandoned pending's own timer reaps it")
        try await waitUntil { model.outcome == .timedOut }
        #expect(model.outcomeLabel == "This review timed out before a decision was made.",
                "the terminal outcome names itself in the banner")
        #expect(!model.decisionsEnabled, "the reaper ends the review")
    }

    // MARK: - Ask

    @Test func abandonedAskBannersButKeepsAnswersEnabledAndStillResolves() async throws {
        let store = PendingAskStore()
        let center = AskCenter(store: store)
        let owner = PendingOwner()
        let request = AskRequest(
            commonDir: "/repos/a/.git", question: "Deploy now?",
            options: ["yes", "no"], timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request, owner: owner)
        try await waitUntil { center.sheets.count == 1 }
        let model = try #require(center.sheets.first)

        store.abandonAll(ownedBy: owner)
        try await waitUntil { model.isAbandoned }
        #expect(model.outcome == nil)
        #expect(model.outcomeLabel == "The asking agent went away — you can still answer.")
        #expect(model.answersEnabled, "an abandoned ask is still answerable")

        #expect(model.answer(index: 0))
        let answer = AskReply.chosen(index: 0, text: "yes")
        #expect(await outcome == .decided(answer))
        try await waitUntil { center.sheets.isEmpty }
    }

    // MARK: - Resolve

    @Test func abandonedResolveBannersButKeepsDecisionsEnabledAndStillResolves() async throws {
        let store = PendingResolveStore()
        let center = ResolveCenter(store: store)
        let owner = PendingOwner()
        let request = ResolveRequest(commonDir: "/repos/a/.git", timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request, owner: owner)
        try await waitUntil { center.panes.count == 1 }
        let model = try #require(center.panes.first)

        store.abandonAll(ownedBy: owner)
        try await waitUntil { model.isAbandoned }
        #expect(model.outcome == nil)
        #expect(model.outcomeLabel == "The asking agent went away — you can still decide.")
        #expect(model.decisionsEnabled, "an abandoned resolve is still decidable")

        #expect(model.cancel(), "the human may still cancel — a decided reply, recorded")
        let reply = await outcome
        #expect(reply == ResolveOutcome.decided(ResolveReply.cancelled))
        try await waitUntil { center.panes.isEmpty }
    }
}
