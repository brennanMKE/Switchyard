// AskRequestServingTests.swift — `runAskRequest`, the app-side body of
// `performAsk` (#0056)
//
// The body resolves the repository engine-side (the one piece of engine
// work an ask needs — one `WorktreeContext.resolve`, no diff work) and
// registers into the pending ask store. The CLI cannot do this itself: it
// does not link the engine, which is why the request arrives with
// `commonDir` empty.

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

@Suite("runAskRequest (app-side body)")
struct AskRequestServingTests {

    @Test func registersUnderTheResolvedCommonDirAndDeliversTheDecision() async throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("base")])

        let context = try await WorktreeContext.resolve(path: repo.url.path)
        let repoPath = repo.url.path
        let store = PendingAskStore()

        // Exactly what the CLI sends: commonDir empty, resolved app-side.
        let request = AskRequest(
            commonDir: "", question: "Deploy now?", options: ["yes", "no"], timeoutSeconds: 60)
        let requestData = try JSONEncoder().encode(request)

        async let outcomeData = runAskRequest(
            requestData: requestData,
            workingDirectory: repoPath,
            store: store)

        let registered = try await AppConnection.poll(
            timeout: .seconds(60), interval: .milliseconds(10)) {
            store.pendingAsks.isEmpty ? nil : store.pendingAsks
        }
        let pending = try #require(registered, "the request must be registered")
        let head = try #require(pending.first, "the pending list must not be empty")
        #expect(head.request.commonDir == context.commonDir,
                "the request must be registered under the resolved common dir, got \(head.request.commonDir)")
        #expect(head.request.commonDir != "",
                "the CLI's empty placeholder must not survive into the store")
        #expect(head.request.question == "Deploy now?")
        #expect(head.request.options == ["yes", "no"])

        let reply = AskReply.chosen(index: 0, text: "yes")
        #expect(store.resolve(id: head.id, answer: reply))

        let outcomeBytes = await outcomeData
        let outcome = try #require(
            try? JSONDecoder().decode(AskOutcome.self, from: outcomeBytes),
            "the body must reply an outcome, not a failure envelope: \(String(decoding: outcomeBytes, as: UTF8.self))")
        #expect(outcome == .decided(reply))
        #expect(store.pendingAsks.isEmpty)
    }

    /// A working directory that is not a repository is never registered: the
    /// CLI receives the repository-error envelope (exit 6), not a pending
    /// ask keyed on a fabricated value, and not a decision.
    @Test func unresolvableWorkingDirectoryIsNeverRegistered() async throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-ask-non-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let store = PendingAskStore()
        let requestData = try JSONEncoder().encode(
            AskRequest(commonDir: "", question: "Q?", options: ["a"], timeoutSeconds: 1))

        let data = await runAskRequest(
            requestData: requestData,
            workingDirectory: empty.path,
            store: store)

        let failure = try #require(
            try? JSONDecoder().decode(EnvelopeFail.self, from: data),
            "an unresolvable repository must reply a failure envelope")
        #expect(failure.error.code == .repositoryError)
        #expect(store.pendingAsks.isEmpty)
    }

    // MARK: - The bridge delivery (tab routing seam)

    /// Delivers `onPending`'s capture across its @Sendable boundary into a
    /// bounded poll, so no test reads a clock.
    private final class Registration: @unchecked Sendable {
        private let lock = NSLock()
        private var item: (AskRequest, WorktreeContext)?
        func record(_ value: (AskRequest, WorktreeContext)) {
            lock.withLock { item = value }
        }
        var value: (AskRequest, WorktreeContext)? {
            lock.withLock { item }
        }
    }

    @Test func deliveredPendingCarriesTheResolvedRequestAndContext() async throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("base")])
        let repoPath = repo.url.path

        let context = try await WorktreeContext.resolve(path: repoPath)
        let store = PendingAskStore()
        let registration = Registration()
        let requestData = try JSONEncoder().encode(
            AskRequest(commonDir: "", question: "Ship?", options: ["a", "b"], timeoutSeconds: 60))

        async let outcomeData = runAskRequest(
            requestData: requestData,
            workingDirectory: repoPath,
            store: store,
            onPending: { request, resolvedContext in
                registration.record((request, resolvedContext))
            })

        let registered = try await AppConnection.poll(
            timeout: .seconds(60), interval: .milliseconds(10)) {
            registration.value
        }
        let (delivered, deliveredContext) = try #require(
            registered, "the resolved request and its context must reach the sheet bridge")
        #expect(delivered.commonDir == context.commonDir,
                "the delivery carries the resolved common dir, not the CLI's empty placeholder")
        #expect(deliveredContext.commonDir == context.commonDir)
        #expect(delivered.question == "Ship?")

        // The body still blocks on the store; resolve and check the outcome.
        let pendings = try await AppConnection.poll(
            timeout: .seconds(60), interval: .milliseconds(10)) {
            store.pendingAsks.isEmpty ? nil : store.pendingAsks
        }
        let head = try #require(pendings?.first, "the request must be registered")
        #expect(store.resolve(id: head.id, answer: AskReply.declined()))
        let outcome = try #require(try? JSONDecoder().decode(AskOutcome.self, from: await outcomeData))
        #expect(outcome == .decided(AskReply.declined()))
    }

    /// Two asks for the same repository through the serving body queue
    /// behind each other and resolve in order — the issue's own criterion,
    /// exercised end to end through the real body.
    @Test func twoAsksThroughTheBodyQueueAndResolveInOrder() async throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("base")])
        let repoPath = repo.url.path
        let context = try await WorktreeContext.resolve(path: repoPath)
        let store = PendingAskStore()

        let firstData = try JSONEncoder().encode(
            AskRequest(commonDir: "", question: "First?", options: ["a"], timeoutSeconds: 60))
        let secondData = try JSONEncoder().encode(
            AskRequest(commonDir: "", question: "Second?", options: ["b"], timeoutSeconds: 60))

        async let firstOutcomeData = runAskRequest(
            requestData: firstData, workingDirectory: repoPath, store: store)
        try await AppConnection.poll(timeout: .seconds(60), interval: .milliseconds(10)) {
            store.queue(for: context.commonDir).count == 1 ? true : nil
        }

        async let secondOutcomeData = runAskRequest(
            requestData: secondData, workingDirectory: repoPath, store: store)
        try await AppConnection.poll(timeout: .seconds(60), interval: .milliseconds(10)) {
            store.queue(for: context.commonDir).count == 2 ? true : nil
        }

        let queue = store.queue(for: context.commonDir)
        #expect(queue.count == 2, "the second ask must queue, not replace; got \(queue.count)")
        #expect(queue.map(\.request.question) == ["First?", "Second?"])

        #expect(store.resolve(commonDir: context.commonDir, answer: AskReply.chosen(index: 0, text: "a")))
        #expect(try #require(try? JSONDecoder().decode(AskOutcome.self, from: await firstOutcomeData))
            == .decided(AskReply.chosen(index: 0, text: "a")))
        #expect(store.resolve(commonDir: context.commonDir, answer: AskReply.declined()))
        #expect(try #require(try? JSONDecoder().decode(AskOutcome.self, from: await secondOutcomeData))
            == .decided(AskReply.declined()))
        #expect(store.pendingAsks.isEmpty)
    }
}
