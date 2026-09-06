// WatchObservedBridgeTests.swift — the journal-observed event source (#0058)
//
// The bridge converts a real `JournalObserved.Metadata` (YardGit) into a
// `journal_observed` watch event (YardKit) carrying the metadata's own JSON
// as a nested object — the only code that sees both types, which is why it
// lives in this target.

import Foundation
import Testing
import YardCommands
import YardGit
import YardKit

@Suite("watch observed bridge")
struct WatchObservedBridgeTests {

    private func waitUntil(
        timeout: Duration = .seconds(120),
        _ fetch: @escaping @Sendable () -> Bool
    ) async throws {
        let reached = try await AppConnection.poll(timeout: timeout, interval: .milliseconds(10)) {
            fetch() ? true : nil
        }
        try #require(reached == true, "the awaited state was never reached")
    }

    /// A ref-updates metadata broadcasts as a `journal_observed` event whose
    /// payload IS the metadata's JSON — the shape `metadata.json` stores,
    /// embedded as a nested object, never escaped.
    @Test func observedMetadataBroadcastsAsAJournalObservedEvent() async throws {
        let store = WatchSessionStore()
        let collector = EventCollector()

        let sessionTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: nil, timeoutSeconds: nil),
                owner: PendingOwner(),
                push: { collector.append($0) })
        }
        try await waitUntil { store.activeSessions.count == 1 }

        let metadata = JournalObserved.Metadata(
            updates: [
                ReferenceTransaction.RefUpdate(
                    oldValue: "1111111",
                    newValue: "2222222",
                    refName: "refs/heads/main")
            ],
            timestamp: Date(timeIntervalSince1970: 0),
            worktree: .init(name: "main", path: "/repos/a"))
        try WatchObservedBridge.broadcast(metadata, store: store)

        #expect(store.endAll(reason: .detached) == 1)
        #expect(await sessionTask.value == .detached)

        let events = collector.events
        #expect(events.count == 1, "one record, one event; got \(events.count)")
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
        #expect(update["oldValue"] == .string("1111111"))
        #expect(update["newValue"] == .string("2222222"))
        #expect(update["refName"] == .string("refs/heads/main"))
        #expect(event.payload["timestamp"] == .string("1970-01-01T00:00:00Z"),
                "the timestamp is the metadata's own ISO8601 wire form")
    }
}

/// Gathers what one session's push closure received. Same shape as the
/// collector in `WatchSessionStoreTests`, local to this target.
private final class EventCollector: @unchecked Sendable {
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
