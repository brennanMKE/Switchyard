// RecentOperationsTests.swift
//
// Deliberately NOT @testable: the store is called by the app and the M3
// wiring as a public caller, so a member silently dropping to internal must
// fail here at compile time (the #0116 failure class).

import Foundation
import Testing
import YardKit

struct RecentOperationsTests {

    /// A unique directory that does not exist yet, under the resolved
    /// temporary directory. The store must create it itself.
    private func scratchDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-recent-ops-\(UUID().uuidString)", isDirectory: true)
    }

    /// Whole seconds on purpose: the wire format is ISO 8601, which drops
    /// sub-second precision, and these must round-trip exactly.
    private let t1 = Date(timeIntervalSince1970: 1_754_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_754_000_100)
    private let t3 = Date(timeIntervalSince1970: 1_754_000_200)

    private func makeRecord(
        identity: String = "id-a",
        entryID: String = "entry-1",
        operation: String = "commit",
        timestamp: Date,
        agentName: String? = "claude",
        agentSession: String? = "session-1"
    ) -> RecentOperations.Record {
        RecentOperations.Record(
            identity: identity,
            entryID: entryID,
            operation: operation,
            timestamp: timestamp,
            agentName: agentName,
            agentSession: agentSession
        )
    }

    // MARK: - 1. Missing file reads as empty

    @Test func missingFileReadsAsEmpty() throws {
        let store = RecentOperations(directory: scratchDirectory())
        #expect(try store.records().isEmpty)
    }

    // MARK: - 2. One record round-trips every field

    @Test func oneRecordRoundTripsEveryField() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentOperations(directory: dir)
        let written = makeRecord(
            identity: "id-a",
            entryID: "entry-1",
            operation: "commit",
            timestamp: t1,
            agentName: "claude",
            agentSession: "session-1"
        )
        try store.record(written)

        let second = RecentOperations(directory: dir)
        let records = try second.records()
        #expect(records.count == 1)
        let readBack = try #require(records.first)
        #expect(readBack.identity == "id-a")
        #expect(readBack.entryID == "entry-1")
        #expect(readBack.operation == "commit")
        #expect(readBack.timestamp == t1)
        #expect(readBack.agentName == "claude")
        #expect(readBack.agentSession == "session-1")
    }

    // MARK: - 3. Same-timestamp records keep insertion order, newest first

    @Test func sameTimestampRecordsComeBackInInsertionOrderNewestFirst() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentOperations(directory: dir)
        let first = makeRecord(entryID: "entry-1", timestamp: t1)
        let second = makeRecord(entryID: "entry-2", timestamp: t1)
        let third = makeRecord(entryID: "entry-3", timestamp: t1)
        try store.record(first)
        try store.record(second)
        try store.record(third)

        let records = try store.records()
        #expect(records.map(\.entryID) == ["entry-3", "entry-2", "entry-1"])
    }

    // MARK: - 4. Trim keeps the newest `limit`, oldest dropped

    @Test func exceedingLimitDropsTheOldestAndKeepsTheNewest() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentOperations(directory: dir)
        let limit = 10
        let total = limit + 5
        for index in 0..<total {
            let record = makeRecord(
                entryID: "entry-\(index)",
                timestamp: Date(timeIntervalSince1970: 1_754_000_000 + Double(index))
            )
            try store.record(record, limit: limit)
        }

        let records = try store.records()
        #expect(records.count == limit)
        // Newest is entry-(total - 1); the five oldest (entry-0 ... entry-4) are gone.
        #expect(records.first?.entryID == "entry-\(total - 1)")
        let entryIDs = Set(records.map(\.entryID))
        for index in 0..<5 {
            #expect(!entryIDs.contains("entry-\(index)"))
        }
        #expect(entryIDs.contains("entry-\(total - 1)"))
    }

    // MARK: - 5. records(identity:) filters, newest first

    @Test func recordsForIdentityFiltersAndReturnsNewestFirst() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentOperations(directory: dir)
        try store.record(makeRecord(identity: "id-a", entryID: "a-1", timestamp: t1))
        try store.record(makeRecord(identity: "id-b", entryID: "b-1", timestamp: t2))
        try store.record(makeRecord(identity: "id-a", entryID: "a-2", timestamp: t3))

        let filtered = try store.records(identity: "id-a")
        #expect(filtered.map(\.entryID) == ["a-2", "a-1"])
    }

    // MARK: - 6. A foreign or truncated file is a typed error, not a crash

    @Test func corruptFileThrowsUnreadable() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = RecentOperations(directory: dir)
        try Data("not a store".utf8).write(to: store.fileURL)
        let error = try #require(throws: RecentOperations.Error.self) {
            _ = try store.records()
        }
        guard case .unreadable = error else {
            Issue.record("expected .unreadable, got \(error)")
            return
        }
    }

    @Test func unsupportedSchemaVersionThrows() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = RecentOperations(directory: dir)
        try Data(#"{"schemaVersion": 2, "records": []}"#.utf8).write(to: store.fileURL)
        let error = try #require(throws: RecentOperations.Error.self) {
            _ = try store.records()
        }
        #expect(error == .unsupportedSchema(version: 2, path: store.fileURL.path))
    }

    // MARK: - 7. The directory is created 0o700 when absent

    @Test func recordCreatesTheDirectoryOwnerOnly() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentOperations(directory: dir)
        try store.record(makeRecord(timestamp: t1))
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.path)
        let permissions = try #require(attributes[.posixPermissions] as? Int)
        #expect(permissions == 0o700)
    }
}
