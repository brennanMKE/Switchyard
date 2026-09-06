// ReferenceTransactionHookTests.swift — the app-side hook body (#0154)

import Foundation
import Testing
import YardCommands
import YardGit
@testable import YardKit

@Suite("runReferenceTransactionHook: the app side of the hook wire")
struct ReferenceTransactionHookTests {

    /// The stdin bytes one committed ref update produces, against a fixture
    /// whose history is `a → b → c` on `main`.
    private func payload(newOid: String) -> Data {
        Data(String(repeating: "0", count: 40).appending(" \(newOid) refs/heads/main\n").utf8)
    }

    /// A foreign `committed` transaction is recorded as an observed entry
    /// and exits 0 — the whole point of the arm.
    @Test func foreignCommittedIsRecordedAndExitsZero() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let exitCode = runReferenceTransactionHook(
            state: "committed",
            environment: [:],
            standardInput: payload(newOid: repo.oids["c"]!),
            workingDirectory: repo.url.path)

        #expect(exitCode == 0)
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let entries = try JournalObserved.list(in: context)
        #expect(entries.count == 1, "exactly one observed entry for one ref update")
    }

    /// Switchyard's own transaction — the marker present and non-empty —
    /// records nothing. The app side re-derives this gate from the shipped
    /// environment; the CLI's gate only decided whether stdin was worth
    /// draining.
    @Test func ownCommittedRecordsNothingAndExitsZero() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let exitCode = runReferenceTransactionHook(
            state: "committed",
            environment: [GitProcess.markerVariable: "1"],
            standardInput: payload(newOid: repo.oids["c"]!),
            workingDirectory: repo.url.path)

        #expect(exitCode == 0)
        let context = try WorktreeContext.resolve(path: repo.url.path)
        #expect(try JournalObserved.list(in: context).isEmpty)
    }

    /// `prepared` and `aborted` record nothing, whatever stdin carried.
    @Test(arguments: ["prepared", "aborted", "frobnicated"])
    func nonCommittedStatesRecordNothing(state: String) throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let exitCode = runReferenceTransactionHook(
            state: state,
            environment: [:],
            standardInput: payload(newOid: repo.oids["c"]!),
            workingDirectory: repo.url.path)

        #expect(exitCode == 0)
        let context = try WorktreeContext.resolve(path: repo.url.path)
        #expect(try JournalObserved.list(in: context).isEmpty)
    }

    /// Garbage stdin on `committed` is counted and dropped, never thrown,
    /// never a non-zero exit. One token cannot parse as
    /// `<old> SP <new> SP <ref>`, so every line is malformed — a line with
    /// three space-separated tokens would parse as a (mangled but valid)
    /// update and be recorded, which is `parse`'s contract, not a defect.
    @Test func garbageStdinOnCommittedExitsZero() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let exitCode = runReferenceTransactionHook(
            state: "committed",
            environment: [:],
            standardInput: Data("garbage\n".utf8),
            workingDirectory: repo.url.path)

        #expect(exitCode == 0)
        let context = try WorktreeContext.resolve(path: repo.url.path)
        #expect(try JournalObserved.list(in: context).isEmpty)
    }

    /// A working directory that is not a repository must not be able to
    /// produce a non-zero exit: the transaction already happened wherever
    /// it happened.
    @Test func outsideARepositoryExitsZero() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-hook-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let exitCode = runReferenceTransactionHook(
            state: "committed",
            environment: [:],
            standardInput: payload(newOid: String(repeating: "a", count: 40)),
            workingDirectory: empty.path)

        #expect(exitCode == 0)
    }
}

// MARK: - The #0058 watch tap

/// Gathers what one watch session's push closure received. Same shape as the
/// collector in `WatchSessionStoreTests`, local to this target.
private final class HookEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [WatchEvent] = []

    func append(_ data: Data) {
        guard let event = try? JSONDecoder().decode(WatchEvent.self, from: data) else {
            return
        }
        lock.withLock { _events.append(event) }
    }

    var events: [WatchEvent] { lock.withLock { _events } }
}

extension ReferenceTransactionHookTests {

    private func waitUntil(
        timeout: Duration = .seconds(120),
        _ fetch: @escaping @Sendable () -> Bool
    ) async throws {
        let reached = try await AppConnection.poll(timeout: timeout, interval: .milliseconds(10)) {
            fetch() ? true : nil
        }
        try #require(reached == true, "the awaited state was never reached")
    }

    /// A foreign `committed` transaction recorded WITH a watch store riding
    /// along broadcasts one `journal_observed` event whose payload IS the
    /// metadata's shape — the hook flow and the watch stream meet here.
    @Test func foreignCommittedBroadcastsAJournalObservedWatchEvent() async throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let store = WatchSessionStore()
        let collector = HookEventCollector()

        let sessionTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: nil, timeoutSeconds: nil),
                owner: PendingOwner(),
                push: { collector.append($0) })
        }
        try await waitUntil { store.activeSessions.count == 1 }

        let exitCode = runReferenceTransactionHook(
            state: "committed",
            environment: [:],
            standardInput: payload(newOid: repo.oids["c"]!),
            workingDirectory: repo.url.path,
            watchStore: store)

        #expect(exitCode == 0, "the tap must not disturb the hook's totality")
        #expect(store.endAll(reason: .detached) == 1)
        #expect(await sessionTask.value == .detached)

        let events = collector.events
        #expect(events.count == 1, "one recorded entry, one watch event; got \(events.count)")
        let event = try #require(events.first)
        #expect(event.sequence == 1)
        #expect(event.kind == .journalObserved)
        #expect(event.payload["kind"] == .string("ref_updates"))
        #expect(event.payload["schemaVersion"] == .int(JournalObserved.Metadata.currentSchemaVersion))
        let updates = try #require(event.payload["updates"])
        guard case .array(let entries) = updates, entries.count == 1 else {
            Issue.record("updates must arrive as the metadata's one-entry array: \(updates)")
            return
        }
        guard case .object(let update) = entries[0] else {
            Issue.record("each update must be an object: \(entries[0])")
            return
        }
        #expect(update["oldValue"] == .string(String(repeating: "0", count: 40)))
        #expect(update["newValue"] == .string(repo.oids["c"]!))
        #expect(update["refName"] == .string("refs/heads/main"))
    }

    /// Switchyard's own transaction records nothing, so the tap fires for
    /// nothing — no event, and the store still holds exactly the session.
    @Test func ownCommittedBroadcastsNothing() async throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let store = WatchSessionStore()
        let collector = HookEventCollector()

        let sessionTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: nil, timeoutSeconds: nil),
                owner: PendingOwner(),
                push: { collector.append($0) })
        }
        try await waitUntil { store.activeSessions.count == 1 }

        let exitCode = runReferenceTransactionHook(
            state: "committed",
            environment: [GitProcess.markerVariable: "1"],
            standardInput: payload(newOid: repo.oids["c"]!),
            workingDirectory: repo.url.path,
            watchStore: store)

        #expect(exitCode == 0)
        #expect(collector.events.isEmpty, "nothing recorded, nothing streamed")
        #expect(store.activeSessions.count == 1)
        #expect(store.endAll(reason: .detached) == 1)
        #expect(await sessionTask.value == .detached)
    }

    /// The event is scoped to the worktree the transaction happened in: a
    /// session watching that exact path receives it (as its first event);
    /// a session watching a different path receives nothing.
    @Test func observedEventIsScopedToTheWorktreesPath() async throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let repoPath = repo.url.path
        let store = WatchSessionStore()
        let watchingHere = HookEventCollector()
        let watchingElsewhere = HookEventCollector()

        let hereTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: repoPath, timeoutSeconds: nil),
                owner: PendingOwner(),
                push: { watchingHere.append($0) })
        }
        let elsewhereTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: "/repos/other", timeoutSeconds: nil),
                owner: PendingOwner(),
                push: { watchingElsewhere.append($0) })
        }
        try await waitUntil { store.activeSessions.count == 2 }

        let exitCode = runReferenceTransactionHook(
            state: "committed",
            environment: [:],
            standardInput: payload(newOid: repo.oids["c"]!),
            workingDirectory: repo.url.path,
            watchStore: store)

        #expect(exitCode == 0)
        #expect(store.endAll(reason: .detached) == 2)
        #expect(await hereTask.value == .detached)
        #expect(await elsewhereTask.value == .detached)

        let here = watchingHere.events
        #expect(here.count == 1, "the session watching this exact path saw the event")
        #expect(try #require(here.first).sequence == 1)
        #expect(watchingElsewhere.events.isEmpty, "a session on another path saw nothing")
    }
}
