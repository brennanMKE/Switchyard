// ReviewRequestServingTests.swift — `runReviewRequest`, the app-side body of
// `performReview` (#0055)
//
// The body resolves the repository engine-side (the one piece of engine work
// round 1 does — one `WorktreeContext.resolve`, not diff work) and registers
// into the pending store. The CLI cannot do this itself: it does not link the
// engine, which is why the request arrives with `commonDir` empty.

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

@Suite("runReviewRequest (app-side body)")
struct ReviewRequestServingTests {

    @Test func registersUnderTheResolvedCommonDirAndDeliversTheDecision() async throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("base")])

        let context = try await WorktreeContext.resolve(path: repo.url.path)
        let repoPath = repo.url.path
        let store = PendingReviewStore()

        // Exactly what the CLI sends: commonDir empty, resolved app-side.
        let request = ReviewRequest(commonDir: "", selector: .staged, timeoutSeconds: 60)
        let requestData = try JSONEncoder().encode(request)

        async let outcomeData = runReviewRequest(
            requestData: requestData,
            workingDirectory: repoPath,
            store: store)

        let registered = try await AppConnection.poll(
            timeout: .seconds(60), interval: .milliseconds(10)) {
            store.pendingReviews.isEmpty ? nil : store.pendingReviews
        }
        let pending = try #require(registered, "the request must be registered")
        let entry = try #require(pending.first, "the pending list must not be empty")
        #expect(entry.request.commonDir == context.commonDir,
                "the request must be registered under the resolved common dir, got \(entry.request.commonDir)")
        #expect(entry.request.commonDir != "",
                "the CLI's empty placeholder must not survive into the store")
        #expect(entry.request.selector == .staged)

        #expect(store.resolve(
            id: entry.id,
            decision: ReviewReply(decision: .approve, message: nil, comments: [], editedPatch: nil)))

        let outcomeBytes = await outcomeData
        let outcome = try #require(
            try? JSONDecoder().decode(ReviewOutcome.self, from: outcomeBytes),
            "the body must reply an outcome, not a failure envelope: \(String(decoding: outcomeBytes, as: UTF8.self))")
        #expect(outcome == .decided(ReviewReply(
            decision: .approve, message: nil, comments: [], editedPatch: nil)))
        #expect(store.pendingReviews.isEmpty)
    }

    /// A working directory that is not a repository is never registered: the
    /// CLI receives the repository-error envelope (exit 6), not a pending
    /// review keyed on a fabricated value, and not a decision.
    @Test func unresolvableWorkingDirectoryIsNeverRegistered() async throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-review-non-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let store = PendingReviewStore()
        let requestData = try JSONEncoder().encode(
            ReviewRequest(commonDir: "", selector: .staged, timeoutSeconds: 1))

        let data = await runReviewRequest(
            requestData: requestData,
            workingDirectory: empty.path,
            store: store)

        let failure = try #require(
            try? JSONDecoder().decode(EnvelopeFail.self, from: data),
            "an unresolvable repository must reply a failure envelope")
        #expect(failure.error.code == .repositoryError)
        #expect(store.pendingReviews.isEmpty)
    }

    // MARK: - Round 2: the diff resolution

    /// Delivers `onPending`'s capture across its @Sendable boundary into a
    /// bounded poll, so no test reads a clock.
    private final class Registration: @unchecked Sendable {
        private let lock = NSLock()
        private var item: (ReviewRequest, WorktreeContext, [FileDiff], String?)?
        func record(_ value: (ReviewRequest, WorktreeContext, [FileDiff], String?)) {
            lock.withLock { item = value }
        }
        var value: (ReviewRequest, WorktreeContext, [FileDiff], String?)? {
            lock.withLock { item }
        }
    }

    @Test func stagedRequestResolvesTheIndexDiffAndDeliversItToTheSheet() async throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        // A staged change is what `--staged` asks the human to review.
        try "changed\n".write(
            to: repo.url.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await GitProcess().run(["add", "a.txt"], workingDirectory: repo.url.path)
        let repoPath = repo.url.path

        let context = try await WorktreeContext.resolve(path: repo.url.path)
        let store = PendingReviewStore()
        let registration = Registration()
        let request = ReviewRequest(commonDir: "", selector: .staged, timeoutSeconds: 60)
        let requestData = try JSONEncoder().encode(request)

        async let outcomeData = runReviewRequest(
            requestData: requestData,
            workingDirectory: repoPath,
            store: store,
            onPending: { req, ctx, files, errorMessage in
                registration.record((req, ctx, files, errorMessage))
            })

        let registered = try await AppConnection.poll(
            timeout: .seconds(60), interval: .milliseconds(10)) {
            registration.value
        }
        let (delivered, deliveredContext, files, errorMessage) = try #require(
            registered, "the resolved request and its diff must reach the sheet bridge")
        #expect(delivered.commonDir == context.commonDir,
                "the delivery carries the resolved common dir, not the CLI's empty placeholder")
        #expect(deliveredContext.commonDir == context.commonDir)
        #expect(errorMessage == nil)
        let staged = try #require(files.first, "the staged change must resolve to one file's diff")
        #expect(staged.path == "a.txt")
        #expect(staged.hunks.count == 1)
        #expect(staged.hunks.first?.body.contains("+changed") == true,
                "the hunk body carries the staged line the human reviews")

        // The registration still blocks on the store exactly as round 1
        // left it, and the decided outcome still reaches the CLI.
        // The diff delivery precedes the store registration by design, so
        // the pending is polled for rather than assumed on the same tick.
        let pendings = try await AppConnection.poll(
            timeout: .seconds(60), interval: .milliseconds(10)) {
            store.pendingReviews.isEmpty ? nil : store.pendingReviews
        }
        let pending = try #require(pendings?.first, "the request must be registered")
        #expect(store.resolve(id: pending.id, decision: ReviewReply(decision: .approve)))
        let outcome = try #require(try? JSONDecoder().decode(ReviewOutcome.self, from: await outcomeData))
        #expect(outcome == .decided(ReviewReply(decision: .approve)))
    }

    @Test func rangeRequestResolvesTheCommitDiffAndDeliversItToTheSheet() async throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }
        try repo.build([
            FixtureRepository.Commit("base", files: ["base.txt": "base\n"]),
            FixtureRepository.Commit("tip", files: ["tip.txt": "tip\n"]),
        ])
        let repoPath = repo.url.path

        let store = PendingReviewStore()
        let registration = Registration()
        let request = ReviewRequest(commonDir: "", selector: .range("HEAD~1..HEAD"), timeoutSeconds: 60)
        let requestData = try JSONEncoder().encode(request)

        async let outcomeData = runReviewRequest(
            requestData: requestData,
            workingDirectory: repoPath,
            store: store,
            onPending: { req, ctx, files, errorMessage in
                registration.record((req, ctx, files, errorMessage))
            })

        let registered = try await AppConnection.poll(
            timeout: .seconds(60), interval: .milliseconds(10)) {
            registration.value
        }
        let (_, _, files, errorMessage) = try #require(registered)
        #expect(errorMessage == nil)
        #expect(files.map(\.path) == ["tip.txt"],
                "the range resolves to exactly the tip commit's diff")
        #expect(files.first?.hunks.first?.body.contains("+tip") == true)

        // The diff delivery precedes the store registration by design, so
        // the pending is polled for rather than assumed on the same tick.
        let pendings = try await AppConnection.poll(
            timeout: .seconds(60), interval: .milliseconds(10)) {
            store.pendingReviews.isEmpty ? nil : store.pendingReviews
        }
        let pending = try #require(pendings?.first, "the request must be registered")
        #expect(store.resolve(id: pending.id, decision: ReviewReply(decision: .approve)))
        let outcome = try #require(try? JSONDecoder().decode(ReviewOutcome.self, from: await outcomeData))
        #expect(outcome == .decided(ReviewReply(decision: .approve)))
    }
}
