// AskSheetTests.swift — the ask sheet's model layer (#0056)
//
// This target imports YardUI WITHOUT `@testable`, so everything asserted
// here is reachable at exactly the access level the app target sees. The
// sheet is a pure function of `AskSheetModel`, so every state is asserted
// through the model — no test renders anything, touches AppKit, or reaches
// the XPC layer: the store below is the real `PendingAskStore`, wired to
// `AskCenter` exactly as the app target wires it.
//
// No test reads a clock (Rule 7c): registration and outcome waits are
// bounded polls with a 60 s ceiling that returns the moment the state
// arrives, and the timeout test arms the store's own one-second timeout
// rather than measuring elapsed time.

import Foundation
import Testing
import YardKit
import YardUI

@MainActor
@Suite("AskSheet")
struct AskSheetTests {

    private struct WaitTimeout: Error {}

    // MARK: - Fixtures

    private func pending(
        question: String = "Deploy now?",
        options: [String] = ["yes", "no"],
        commonDir: String = "/repos/a/.git",
        timeoutSeconds: Int = 3600
    ) -> PendingAskStore.Pending {
        PendingAskStore.Pending(
            id: UUID(),
            request: AskRequest(
                commonDir: commonDir,
                question: question,
                options: options,
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

    private func decidedReply(from outcome: AskOutcome) -> AskReply? {
        guard case .decided(let reply) = outcome else { return nil }
        return reply
    }

    // MARK: - Pending state

    @Test func pendingSheetShowsTheQuestionAndOptionsWithAnswersEnabled() {
        let model = AskSheetModel(pending: pending())
        #expect(model.outcome == nil, "a fresh sheet is pending")
        #expect(model.answersEnabled, "the option and decline buttons enable while pending")
        #expect(model.question == "Deploy now?")
        #expect(model.options == ["yes", "no"], "options are the render source, in order")
        #expect(model.outcomeLabel == nil, "a pending sheet shows no outcome banner")
    }

    // MARK: - The question-is-text rule

    /// The question comes from an agent and is untrusted input: the model
    /// carries it VERBATIM — markup-looking strings survive byte for byte,
    /// so nothing downstream can be tricked into rendering them.
    @Test func theModelCarriesTheQuestionVerbatim() {
        let hostile = #"Run <script>alert("x")</script>? [click](http://evil.example) **bold** #{heading}"#
        let model = AskSheetModel(pending: pending(question: hostile))
        #expect(model.question == hostile,
                "the question must survive byte for byte — never normalized, never parsed")
    }

    /// The view's rendering path: the question is rendered through
    /// `Text(verbatim:)` — literal text — and the view source contains no
    /// attributed-markdown initialiser anywhere, so no question content can
    /// ever reach a markdown parser.
    @Test func theViewRendersTheQuestionAsLiteralTextOnly() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit (package root)
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("YardUI", isDirectory: true)
            .appendingPathComponent("AskSheet.swift")
        let source = try #require(
            try? String(contentsOf: sourceURL, encoding: .utf8),
            "AskSheet.swift must exist beside the other YardUI sources")
        #expect(source.contains("Text(verbatim: model.question)"),
                "the question's render path must be Text(verbatim:) — literal text")
        #expect(!source.contains("AttributedString(markdown"),
                "no attributed-markdown initialiser may appear in the ask sheet")
        #expect(!source.contains(".markdown("),
                "no markdown rendering call may appear in the ask sheet")
    }

    // MARK: - The composed answer

    @Test func answerComposesTheChosenReplyWithTheMessage() throws {
        let model = AskSheetModel(pending: pending(options: ["yes", "no"]))
        var received: AskReply?
        model.onAnswer = { reply in
            received = reply
            return true
        }

        model.message = "staging only"
        #expect(model.answer(index: 1))
        let reply = try #require(received, "the composed reply must reach the store seam")
        #expect(reply.optionIndex == 1, "the reply carries the option's INDEX")
        #expect(reply.optionText == "no", "and its text")
        #expect(reply.message == "staging only")
        #expect(reply.declined == nil)
    }

    @Test func anAnswerWithoutAMessageSendsNoMessageKey() throws {
        let model = AskSheetModel(pending: pending())
        var received: AskReply?
        model.onAnswer = { reply in
            received = reply
            return true
        }

        #expect(model.answer(index: 0))
        let reply = try #require(received, "the composed reply must reach the store seam")
        #expect(reply.message == nil, "an empty message field is absent, not empty text")
    }

    @Test func declineComposesTheDeclinedReply() throws {
        let model = AskSheetModel(pending: pending())
        var received: AskReply?
        model.onAnswer = { reply in
            received = reply
            return true
        }

        model.message = "not my call"
        #expect(model.decline())
        let reply = try #require(received, "the composed decline must reach the store seam")
        #expect(reply.declined == true, "the decline is its own marker")
        #expect(reply.optionIndex == nil, "a decline names no option")
        #expect(reply.optionText == nil)
        #expect(reply.message == "not my call")
    }

    @Test func anOutOfOrderOrOutdatedAnswerRefuses() {
        let model = AskSheetModel(pending: pending(options: ["yes", "no"]))
        var received: AskReply?
        model.onAnswer = { reply in
            received = reply
            return true
        }

        #expect(!model.answer(index: -1), "a negative index is not an option")
        #expect(!model.answer(index: 2), "an index past the options is not an option")
        #expect(received == nil, "a refused answer must not reach the wire")

        // Nothing wired to resolve through: both actions refuse.
        let unwired = AskSheetModel(pending: pending())
        #expect(!unwired.answer(index: 0), "nothing wired to resolve through — refused")
        #expect(!unwired.decline(), "nothing wired to resolve through — refused")
    }

    @Test func aTypedOutcomeDisablesTheButtons() {
        let model = AskSheetModel(pending: pending())
        var received: AskReply?
        model.onAnswer = { reply in
            received = reply
            return true
        }

        model.recordOutcome(.timedOut)
        #expect(!model.answersEnabled)
        #expect(!model.answer(index: 0))
        #expect(!model.decline())
        #expect(received == nil)
        #expect(model.outcomeLabel != nil, "the timed-out sheet banners its outcome")
        #expect(model.outcome == .timedOut)
    }

    // MARK: - Round-trips through the store and centre

    @Test func answeringResolvesThroughTheStoreAndDismissesTheSheet() async throws {
        let store = PendingAskStore()
        let center = AskCenter(store: store)
        let request = AskRequest(
            commonDir: "/repos/a/.git", question: "Ship?", options: ["a", "b"], timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !center.sheets.isEmpty }
        let model = try #require(center.sheets.first, "registration must create the sheet")
        #expect(model.commonDir == request.commonDir)
        #expect(model.question == "Ship?")

        #expect(model.answer(index: 1))
        let reply = try #require(await decidedReply(from: outcome), "the reply must be a decision")
        #expect(reply.optionIndex == 1)
        #expect(reply.optionText == "b")
        try await waitUntil { center.sheets.isEmpty }
        #expect(center.sheets.isEmpty, "a decided sheet is dismissed by the centre")
    }

    @Test func thePresentedSheetIsTheHeadOfTheQueue() async throws {
        let store = PendingAskStore()
        let center = AskCenter(store: store)

        let first = AskRequest(
            commonDir: "/repos/a/.git", question: "First?", options: ["a"], timeoutSeconds: 60)
        let second = AskRequest(
            commonDir: "/repos/a/.git", question: "Second?", options: ["b"], timeoutSeconds: 60)
        let third = AskRequest(
            commonDir: "/repos/a/.git", question: "Third?", options: ["c"], timeoutSeconds: 60)

        async let firstOutcome = store.awaitDecision(for: first)
        try await waitUntil { center.sheets.count == 1 }
        async let secondOutcome = store.awaitDecision(for: second)
        try await waitUntil { center.sheets.count == 2 }
        async let thirdOutcome = store.awaitDecision(for: third)
        try await waitUntil { center.sheets.count == 3 }

        // The presented sheet is the HEAD — the first still-pending model.
        let presented = try #require(center.activeSheet(forRepositoryPath: "/repos/a/.git"))
        #expect(presented.question == "First?", "the head is presented; the queue waits")
        #expect(center.sheets.count == 3, "all three have models; only the head presents")

        // Answering the head presents the next — the queue's whole point.
        #expect(presented.answer(index: 0))
        #expect(await firstOutcome == .decided(AskReply.chosen(index: 0, text: "a")))
        try await waitUntil { center.sheets.count == 2 }
        let next = try #require(center.activeSheet(forRepositoryPath: "/repos/a/.git"))
        #expect(next.question == "Second?", "answering the head presents the next ask")

        #expect(next.decline())
        #expect(await secondOutcome == .decided(AskReply.declined()))
        try await waitUntil { center.sheets.count == 1 }
        let last = try #require(center.activeSheet(forRepositoryPath: "/repos/a/.git"))
        #expect(last.question == "Third?")

        #expect(last.answer(index: 0))
        #expect(await thirdOutcome == .decided(AskReply.chosen(index: 0, text: "c")))
        try await waitUntil { center.sheets.isEmpty }
    }

    @Test func asksForDifferentRepositoriesPresentIndependently() async throws {
        let store = PendingAskStore()
        let center = AskCenter(store: store)

        let a = AskRequest(
            commonDir: "/repos/a/.git", question: "A?", options: ["a"], timeoutSeconds: 60)
        let b = AskRequest(
            commonDir: "/repos/b/.git", question: "B?", options: ["b"], timeoutSeconds: 60)

        async let outcomeA = store.awaitDecision(for: a)
        try await waitUntil { center.sheets.count == 1 }
        async let outcomeB = store.awaitDecision(for: b)
        try await waitUntil { center.sheets.count == 2 }

        let presentedA = try #require(center.activeSheet(forRepositoryPath: "/repos/a/.git"))
        let presentedB = try #require(center.activeSheet(forRepositoryPath: "/repos/b/.git"))
        #expect(presentedA.question == "A?")
        #expect(presentedB.question == "B?", "each repository presents its own head")

        #expect(presentedA.answer(index: 0))
        #expect(await outcomeA == .decided(AskReply.chosen(index: 0, text: "a")))
        try await waitUntil { center.sheets.count == 1 }
        #expect(center.activeSheet(forRepositoryPath: "/repos/b/.git")?.question == "B?",
                "resolving a must not touch b's presentation")
        #expect(center.activeSheet(forRepositoryPath: "/repos/a/.git") == nil)

        #expect(presentedB.answer(index: 0))
        #expect(await outcomeB == .decided(AskReply.chosen(index: 0, text: "b")))
        try await waitUntil { center.sheets.isEmpty }
    }

    /// A SHORT real timeout (1 s) armed through the store: the timed-out
    /// sheet banners its outcome, keeps its buttons disabled, and stays
    /// until the human closes it — never a silent vanish.
    @Test func aTimedOutSheetBannersAndStaysUntilClosed() async throws {
        let store = PendingAskStore()
        let center = AskCenter(store: store)
        let request = AskRequest(
            commonDir: "/repos/a/.git", question: "Slow?", options: ["a"], timeoutSeconds: 1)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !center.sheets.isEmpty }

        #expect(await outcome == .timedOut)
        try await waitUntil { center.sheets.first?.outcome == .timedOut }

        let model = try #require(center.sheets.first)
        #expect(!model.answersEnabled, "a timed-out sheet must not compose a second reply")
        #expect(model.outcomeLabel != nil, "the banner names the outcome")
        #expect(center.activeSheet(forRepositoryPath: "/repos/a/.git") == nil,
                "a timed-out head is no longer presented — the queue moved on")

        model.close()
        #expect(center.sheets.isEmpty, "the banner's Close removes the model")
    }
}
