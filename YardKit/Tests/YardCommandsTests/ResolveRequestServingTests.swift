// ResolveRequestServingTests.swift — the app-side resolve body against REAL
// fixture repositories (#0057)
//
// `runResolveRequest` is exercised exactly as the app's `AppService` runs it:
// over a real anonymous XPC listener whose `performResolve` forwards to the
// real body, and whose `perform` runs the real engine composition
// (`runEngineCommand ?? runYard`) — so the arm's post-reply conflicts
// re-check reads the REAL conflicted index, not a canned envelope. No
// assertion reads a clock: waits are bounded polls.

import Foundation
import Testing
@testable import YardCommands
@testable import YardKit
import YardGit

// MARK: - The fake app (real serving body, real engine composition)

/// Lock-protected box for what `onPending` delivered — `@unchecked Sendable`
/// so the serving body's closure can capture it without capturing the
/// non-Sendable service.
private final class ResolveDeliveryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value:
        (request: ResolveRequest, context: WorktreeContext,
         details: [ResolveConflictDetail], error: String?)?
    var value: (request: ResolveRequest, context: WorktreeContext,
                details: [ResolveConflictDetail], error: String?)? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

private final class ResolveServingFakeAppService: NSObject, AppServiceProtocol {

    let store: PendingResolveStore
    let delivery = ResolveDeliveryBox()
    private let lock = NSLock()
    private var _replyCaptured = false

    init(store: PendingResolveStore) {
        self.store = store
        super.init()
    }

    var replyCaptured: Bool {
        lock.withLock { _replyCaptured }
    }

    func appPing(reply: @escaping @Sendable (String) -> Void) {
        reply("pong")
    }

    func perform(
        arguments: [String],
        workingDirectory: String,
        reply: @escaping @Sendable (Data, Int32) -> Void
    ) {
        // The composition `yard-engine`'s main.swift runs and
        // `EngineCommands` documents as the app's — reproduced here so the
        // arm's `["conflicts"]` re-check hits the real engine.
        if let engine = runEngineCommand(arguments: arguments, workingDirectory: workingDirectory) {
            reply(Data(engine.stdout.utf8), Int32(engine.exitCode.rawValue))
            return
        }
        let result = runYard(arguments: arguments)
        reply(Data(result.stdout.utf8), Int32(result.exitCode.rawValue))
    }

    func performReferenceTransactionHook(
        state: String,
        environment: [String: String],
        standardInput: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Int32) -> Void
    ) {
        reply(0)
    }

    func performReview(
        request: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Data) -> Void
    ) {
        reply(Data())
    }

    func performAsk(
        request: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Data) -> Void
    ) {
        reply(Data())
    }

    func performResolve(
        request: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Data) -> Void
    ) {
        lock.withLock { _replyCaptured = true }
        let store = store
        let delivery = delivery
        Task {
            let outcomeData = await runResolveRequest(
                requestData: request,
                workingDirectory: workingDirectory,
                store: store,
                onPending: { request, context, details, error in
                    delivery.value = (request, context, details, error)
                })
            reply(outcomeData)
        }
    }
}

private final class ResolveServingListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: ResolveServingFakeAppService

    init(service: ResolveServingFakeAppService) {
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = XPCInterfaces.appService
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private final class ResolveServingFakeAppListener: @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let service: ResolveServingFakeAppService
    private let delegate: ResolveServingListenerDelegate

    init(store: PendingResolveStore) {
        self.service = ResolveServingFakeAppService(store: store)
        self.delegate = ResolveServingListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
    }

    func connect() -> AppConnection {
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = XPCInterfaces.appService
        connection.resume()
        return AppConnection(connection: connection)
    }

    func invalidate() {
        listener.invalidate()
    }
}

// MARK: - Tests

@Suite("resolve request serving")
struct ResolveRequestServingTests {

    /// Bounded wait for a store state. The bound is generous (ReviewArmTests'
    /// appDeath precedent): under full-suite load the registration path's git
    /// subprocesses can stall for tens of seconds, and lateness is not
    /// failure — the reply lands as soon as the state is reached. No
    /// assertion reads a clock.
    private func waitUntil(
        timeout: Duration = .seconds(120),
        _ fetch: @escaping @Sendable () -> Bool
    ) async throws {
        let reached = try await AppConnection.poll(timeout: timeout, interval: .milliseconds(10)) {
            fetch() ? true : nil
        }
        try #require(reached == true, "the awaited state was never reached")
    }

    /// The `conflicted` fixture shape, parameterised over the file contents.
    private func conflictedFixture(
        base: [String: String],
        ours: [String: String],
        theirs: [String: String]
    ) throws -> FixtureRepository {
        var repo = try FixtureRepository()
        try repo.build([
            .init("base", files: base),
            .init("ours", parents: ["base"], files: ours),
            .init("theirs", parents: ["base"], files: theirs),
        ])
        try repo.checkoutDetached(try #require(repo.oids["ours"]))
        let theirsOID = try #require(repo.oids["theirs"])
        _ = try? GitProcess().run(
            ["merge", "--no-commit", theirsOID],
            workingDirectory: repo.url.path)
        return repo
    }

    // MARK: - The details the pane renders from

    /// A lock-protected box for what `onPending` delivered, readable from
    /// whatever task the serving body runs on.
    private final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private var _value:
            (request: ResolveRequest, context: WorktreeContext,
             details: [ResolveConflictDetail], error: String?)?
        var value: (request: ResolveRequest, context: WorktreeContext,
                    details: [ResolveConflictDetail], error: String?)? {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    @Test func servingDeliversPerPathStageTextsAndTheWorkingSeed() async throws {
        let repo = try conflictedFixture(
            base: ["f.txt": "original\n"],
            ours: ["f.txt": "ours\n"],
            theirs: ["f.txt": "theirs\n"])
        defer { repo.destroy() }
        let repoPath = repo.url.path
        let store = PendingResolveStore()
        let delivery = Delivery()

        let requestData = try JSONEncoder().encode(
            ResolveRequest(commonDir: "", timeoutSeconds: 60))
        async let outcome = runResolveRequest(
            requestData: requestData,
            workingDirectory: repoPath,
            store: store,
            onPending: { request, context, details, error in
                delivery.value = (request, context, details, error)
            })
        try await waitUntil { !store.pendingResolves.isEmpty }

        let delivered = try #require(delivery.value,
                                     "onPending must have delivered the resolved request and details")
        #expect(delivered.request.commonDir != "", "the resolved common dir is filled in")
        let detail = try #require(delivered.details.first)
        #expect(detail.file.path == "f.txt")
        #expect(detail.file.kind == .bothModified)
        #expect(detail.baseText == "original\n")
        #expect(detail.oursText == "ours\n")
        #expect(detail.theirsText == "theirs\n")
        #expect(detail.workingText?.contains("<<<<<<<") == true,
                "the editor seed is the working file's conflict-marked content")
        #expect(delivered.error == nil)

        #expect(store.resolve(commonDir: delivered.request.commonDir, answer: .cancelled))
        let bytes = await outcome
        let decoded = try JSONDecoder().decode(ResolveOutcome.self, from: bytes)
        #expect(decoded == .decided(.cancelled))
    }

    @Test func pathspecNarrowsTheDeliveredDetails() async throws {
        let repo = try conflictedFixture(
            base: ["f.txt": "original f\n", "g.txt": "original g\n"],
            ours: ["f.txt": "ours f\n", "g.txt": "ours g\n"],
            theirs: ["f.txt": "theirs f\n", "g.txt": "theirs g\n"])
        defer { repo.destroy() }
        let repoPath = repo.url.path
        let store = PendingResolveStore()
        let delivery = Delivery()

        let requestData = try JSONEncoder().encode(
            ResolveRequest(commonDir: "", pathspec: "g.txt", timeoutSeconds: 60))
        async let outcome = runResolveRequest(
            requestData: requestData,
            workingDirectory: repoPath,
            store: store,
            onPending: { request, context, details, error in
                delivery.value = (request, context, details, error)
            })
        try await waitUntil { !store.pendingResolves.isEmpty }

        let delivered = try #require(delivery.value)
        #expect(delivered.details.map(\.file.path) == ["g.txt"],
                "the pathspec scope keeps g.txt and drops f.txt; got \(delivered.details.map(\.file.path))")

        #expect(store.resolve(commonDir: delivered.request.commonDir, answer: .cancelled))
        _ = await outcome
    }

    // MARK: - Cancel touches nothing

    /// Cancel is the design's discard: nothing staged, nothing touched. The
    /// conflicted index is compared stage-oid by stage-oid across the wait,
    /// and the journal must gain no checkpoint. Kills mutation 1 (apply on
    /// cancel — any staging would empty the unmerged list or move the journal).
    @Test func cancelLeavesTheConflictedStateUntouched() async throws {
        let repo = try conflictedFixture(
            base: ["f.txt": "original\n"],
            ours: ["f.txt": "ours\n"],
            theirs: ["f.txt": "theirs\n"])
        defer { repo.destroy() }
        let repoPath = repo.url.path
        let before = try conflictedFiles(at: repo.url.path)
        #expect(!before.isEmpty, "precondition: the fixture starts conflicted")
        let context = try await WorktreeContext.resolve(path: repo.url.path)
        let journalBefore = try JournalAnchor.list(in: context).count

        let store = PendingResolveStore()
        let request = ResolveRequest(commonDir: "", timeoutSeconds: 60)
        let requestData = try JSONEncoder().encode(request)
        async let outcome = runResolveRequest(
            requestData: requestData,
            workingDirectory: repoPath,
            store: store)
        try await waitUntil { !store.pendingResolves.isEmpty }

        #expect(store.resolve(commonDir: try #require(store.pendingResolves.first).request.commonDir,
                              answer: .cancelled))
        let bytes = await outcome
        let decoded = try JSONDecoder().decode(ResolveOutcome.self, from: bytes)
        #expect(decoded == .decided(.cancelled))

        let after = try conflictedFiles(at: repo.url.path)
        #expect(after == before,
                "the conflicted index must be byte-identical after a cancel; before \(before.map(\.path)), after \(after.map(\.path))")
        let journalAfter = try JournalAnchor.list(in: context).count
        #expect(journalAfter == journalBefore, "a cancel writes no journal entry")

        let working = String(
            decoding: try Data(contentsOf: repo.url.appendingPathComponent("f.txt")), as: UTF8.self)
        #expect(working.contains("<<<<<<<"), "the working file is untouched too")
    }

    // MARK: - End to end through the arm, with the REAL conflicts re-check

    /// Reply with resolutions but nothing applied (round 1 has no pane to
    /// press the cards): the re-check reads the real conflicted index and
    /// the arm exits 8. Kills mutation 2 (map conflicts-remaining to 0).
    @Test func endToEndUnappliedReplyExitsEightWithConflictsRemaining() async throws {
        let repo = try conflictedFixture(
            base: ["f.txt": "original\n"],
            ours: ["f.txt": "ours\n"],
            theirs: ["f.txt": "theirs\n"])
        defer { repo.destroy() }
        let repoPath = repo.url.path
        let store = PendingResolveStore()
        let fake = ResolveServingFakeAppListener(store: store)
        defer { fake.invalidate() }

        let runner = Task {
            await ResolveArm.run(
                arguments: ["resolve", "--wait", "--timeout", "60"],
                workingDirectory: repoPath,
                connect: { fake.connect() })
        }
        try await waitUntil { !store.pendingResolves.isEmpty }
        let pending = try #require(await MainActor.run { store.pendingResolves.first })
        #expect(store.resolve(
            id: pending.id,
            answer: .resolutions([PathResolution(
                path: "f.txt", kind: .bothModified, choice: .useOurs)])))

        let result = await runner.value
        #expect(result.exitCode == .blockedOnConflicts,
                "conflicts remain (nothing was applied) — exit 8, got \(result.exitCode)")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
        let payload = try #require(object["result"] as? [String: Any])
        #expect(payload["resolutions"] != nil, "the reply rides the envelope at exit 8")
    }

    /// The full dress rehearsal of round 2's per-card flow: the human's
    /// resolution is applied engine-side per path (`ResolveApply`), THEN the
    /// pending is resolved — the re-check reads a clean index and the arm
    /// exits 0 with the reply as the payload.
    @Test func endToEndAppliedResolutionsExitZero() async throws {
        let repo = try conflictedFixture(
            base: ["f.txt": "original\n"],
            ours: ["f.txt": "ours\n"],
            theirs: ["f.txt": "theirs\n"])
        defer { repo.destroy() }
        let repoPath = repo.url.path
        let store = PendingResolveStore()
        let fake = ResolveServingFakeAppListener(store: store)
        defer { fake.invalidate() }

        let runner = Task {
            await ResolveArm.run(
                arguments: ["resolve", "--wait", "--timeout", "60"],
                workingDirectory: repoPath,
                connect: { fake.connect() })
        }
        try await waitUntil { !store.pendingResolves.isEmpty }
        let pending = try #require(await MainActor.run { store.pendingResolves.first })

        // What round 2's "Stage resolution" button does, one path per action.
        try ResolveApply.apply(resolution: .useOurs, path: "f.txt", at: repo.url.path)
        #expect(try conflictedFiles(at: repo.url.path).isEmpty,
                "precondition: the apply resolved the fixture's only conflict")

        #expect(store.resolve(
            id: pending.id,
            answer: .resolutions([PathResolution(
                path: "f.txt", kind: .bothModified, choice: .useOurs)])))

        let result = await runner.value
        #expect(result.exitCode == .success, "all conflicts resolved — exit 0, got \(result.exitCode)")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let payload = try #require(object["result"] as? [String: Any])
        let entries = try #require(payload["resolutions"] as? [[String: Any]])
        #expect(entries.first?["path"] as? String == "f.txt")
        #expect(entries.first?["choice"] as? String == "useOurs")
    }

    /// Cancel through the whole loop: exit 7, and the fixture's conflict is
    /// still there afterwards — the arm-side twin of the untouched-state
    /// test above.
    @Test func endToEndCancelExitsSevenAndResolvesNothing() async throws {
        let repo = try conflictedFixture(
            base: ["f.txt": "original\n"],
            ours: ["f.txt": "ours\n"],
            theirs: ["f.txt": "theirs\n"])
        defer { repo.destroy() }
        let repoPath = repo.url.path
        let store = PendingResolveStore()
        let fake = ResolveServingFakeAppListener(store: store)
        defer { fake.invalidate() }

        let runner = Task {
            await ResolveArm.run(
                arguments: ["resolve", "--wait", "--timeout", "60"],
                workingDirectory: repoPath,
                connect: { fake.connect() })
        }
        try await waitUntil { !store.pendingResolves.isEmpty }
        let pending = try #require(await MainActor.run { store.pendingResolves.first })
        #expect(store.resolve(id: pending.id, answer: .cancelled))

        let result = await runner.value
        #expect(result.exitCode == .humanDeclined, "cancel is exit 7, got \(result.exitCode)")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let payload = try #require(object["result"] as? [String: Any])
        #expect(payload["cancelled"] as? Bool == true)

        let after = try conflictedFiles(at: repo.url.path)
        #expect(after.map(\.path) == ["f.txt"], "the conflict is untouched after cancel")
    }
}
