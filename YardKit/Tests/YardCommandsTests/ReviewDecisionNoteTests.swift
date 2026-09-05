// ReviewDecisionNoteTests.swift — the app-side review flow records the
// decision as a git note (#0059), and a record failure never breaks the
// human's decision (#0160's invariant).

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

@Suite("Review decision notes (app-side flow, #0059)")
struct ReviewDecisionNoteTests {

    /// The encoder the test encodes its expected note body with —
    /// deliberately built here, not read from `reviewNoteBody`, so a change
    /// in the flow's encoding settings fails this comparison instead of
    /// copying itself.
    private static let expectedBodyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        return encoder
    }()

    private static func expectedBody(for reply: ReviewReply) throws -> String {
        String(decoding: try expectedBodyEncoder.encode(reply), as: UTF8.self)
    }

    @Test func stagedDecisionRecordsNoteOnHEADByteIdentical() async throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("base")])
        let repoPath = repo.url.path
        let store = PendingReviewStore()

        let request = ReviewRequest(commonDir: "", selector: .staged, timeoutSeconds: 600)
        let requestData = try JSONEncoder().encode(request)
        let reply = ReviewReply(
            decision: .approve,
            message: "café \"lgtm\"",
            comments: [ReviewComment(path: "base.txt", hunkID: "@@ -1 +1 @@", text: "ok")],
            editedPatch: nil)

        async let outcomeData = runReviewRequest(
            requestData: requestData, workingDirectory: repoPath, store: store)

        // 300 s: pool resumption under full-suite load reaches tens of seconds (#0351).
        let pendings = try await AppConnection.poll(
            timeout: .seconds(300), interval: .milliseconds(10)) {
            store.pendingReviews.isEmpty ? nil : store.pendingReviews
        }
        let pending = try #require(pendings?.first, "the request must be registered")
        #expect(store.resolve(id: pending.id, decision: reply))

        let outcome = try #require(
            try? JSONDecoder().decode(ReviewOutcome.self, from: await outcomeData),
            "the decision must reach the CLI as an outcome")
        #expect(outcome == .decided(reply))

        // By the time the outcome is in hand the note is recorded: the flow
        // awaits the record before returning the outcome bytes.
        let notes = try await ReviewNotes.list(at: repoPath)
        let head = try repo.revParse("HEAD")
        let note = try #require(notes.first(where: { $0.oid == head }),
                                "the decision must be recorded on HEAD (\(head)), got \(notes)")
        let expected = try Self.expectedBody(for: reply)
        #expect(note.body == expected,
                "the note body must be the reply's JSON, sortedKeys, byte-identical")
        let decoded = try #require(
            try? JSONDecoder().decode(ReviewReply.self, from: Data(note.body.utf8)),
            "the note must decode back into the reply — machine-readable")
        #expect(decoded == reply)
    }

    @Test func rangeDecisionRecordsNoteOnTheRangeTip() async throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }
        try repo.build([
            FixtureRepository.Commit("base", files: ["base.txt": "base\n"]),
            FixtureRepository.Commit("tip", files: ["tip.txt": "tip\n"]),
        ])
        let repoPath = repo.url.path
        let store = PendingReviewStore()

        let request = ReviewRequest(
            commonDir: "", selector: .range("HEAD~1..HEAD"), timeoutSeconds: 600)
        let requestData = try JSONEncoder().encode(request)
        let reply = ReviewReply(decision: .reject, message: "no")

        async let outcomeData = runReviewRequest(
            requestData: requestData, workingDirectory: repoPath, store: store)

        // 300 s: pool resumption under full-suite load reaches tens of seconds (#0351).
        let pendings = try await AppConnection.poll(
            timeout: .seconds(300), interval: .milliseconds(10)) {
            store.pendingReviews.isEmpty ? nil : store.pendingReviews
        }
        let pending = try #require(pendings?.first)
        #expect(store.resolve(id: pending.id, decision: reply))
        _ = try #require(
            try? JSONDecoder().decode(ReviewOutcome.self, from: await outcomeData))

        let notes = try await ReviewNotes.list(at: repoPath)
        let tip = try #require(repo.oids["tip"])
        let base = try #require(repo.oids["base"])
        let note = try #require(notes.first(where: { $0.oid == tip }),
                                "the decision must be recorded on the range tip, got \(notes.map(\.oid))")
        #expect(!notes.contains(where: { $0.oid == base }),
                "the base commit must not carry the tip's decision")
        let expectedTip = try Self.expectedBody(for: reply)
        #expect(note.body == expectedTip)
    }

    /// `.timedOut` is a typed non-decision (#0055) — no decision, no note.
    @Test func timedOutOutcomeRecordsNoNote() async throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("base")])
        let repoPath = repo.url.path
        let store = PendingReviewStore()

        let request = ReviewRequest(commonDir: "", selector: .staged, timeoutSeconds: 1)
        let requestData = try JSONEncoder().encode(request)

        let outcomeData = await runReviewRequest(
            requestData: requestData, workingDirectory: repoPath, store: store)
        let outcome = try #require(
            try? JSONDecoder().decode(ReviewOutcome.self, from: outcomeData))
        #expect(outcome == .timedOut)

        let notes = try await ReviewNotes.list(at: repoPath)
        #expect(notes.isEmpty, "a timeout is not a decision and records nothing")
    }

    /// #0160's invariant, one surface over: the repository disappears between
    /// registration and the decision — the record cannot possibly succeed —
    /// and the human's decision still reaches the CLI unchanged.
    @Test func persistenceFailureNeverBreaksTheDecision() async throws {
        var repo = try FixtureRepository()
        let repoPath = repo.url.path
        try repo.build([FixtureRepository.Commit("base")])
        let store = PendingReviewStore()

        let request = ReviewRequest(commonDir: "", selector: .staged, timeoutSeconds: 600)
        let requestData = try JSONEncoder().encode(request)
        let reply = ReviewReply(decision: .approve)

        async let outcomeData = runReviewRequest(
            requestData: requestData, workingDirectory: repoPath, store: store)

        // 300 s: pool resumption under full-suite load reaches tens of seconds (#0351).
        let pendings = try await AppConnection.poll(
            timeout: .seconds(300), interval: .milliseconds(10)) {
            store.pendingReviews.isEmpty ? nil : store.pendingReviews
        }
        let pending = try #require(pendings?.first)

        // The repository vanishes before the human decides. `destroy()` is
        // not `defer`red here on purpose — this test destroys its own fixture
        // at exactly this point.
        repo.destroy()

        #expect(store.resolve(id: pending.id, decision: reply))
        let outcome = try #require(
            try? JSONDecoder().decode(ReviewOutcome.self, from: await outcomeData),
            "the decision must still reach the CLI when the note cannot be recorded")
        #expect(outcome == .decided(reply))
    }
}
