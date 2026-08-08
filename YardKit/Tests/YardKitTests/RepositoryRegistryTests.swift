// RepositoryRegistryTests.swift
//
// Deliberately NOT @testable: the registry is called by the app and the M3
// wiring as a public caller, so a member silently dropping to internal must
// fail here at compile time (the #0116 failure class).

import Foundation
import Testing
import YardKit

struct RepositoryRegistryTests {

    /// A unique directory that does not exist yet, under the resolved
    /// temporary directory. The registry must create it itself.
    private func scratchDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-registry-\(UUID().uuidString)", isDirectory: true)
    }

    /// Whole seconds on purpose: the wire format is ISO 8601, which drops
    /// sub-second precision, and these must round-trip exactly.
    private let t1 = Date(timeIntervalSince1970: 1_754_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_754_000_100)

    // MARK: - Directory

    @Test func registerCreatesTheDirectoryOwnerOnly() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = RepositoryRegistry(directory: dir)
        try registry.register(
            identity: "id-a", commonDir: "/repos/a/.git", workingTree: "/repos/a", now: t1)
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.path)
        let permissions = try #require(attributes[.posixPermissions] as? Int)
        #expect(permissions == 0o700)
    }

    // MARK: - Registration

    @Test func registerWritesUnderTheInjectedDirectoryOnly() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = RepositoryRegistry(directory: dir)
        let outcome = try registry.register(
            identity: "id-a", commonDir: "/repos/a/.git", workingTree: "/repos/a", now: t1)
        #expect(outcome == .added)
        // The file must appear at the injected location. If the implementation
        // resolved a path of its own — the injection bypass this test pins —
        // this assertion goes red.
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(RepositoryRegistry.fileName).path))
        let entries = try registry.entries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.identity == "id-a")
        #expect(entry.commonDir == "/repos/a/.git")
        #expect(entry.workingTree == "/repos/a")
        #expect(entry.firstRegistered == t1)
        #expect(entry.lastSeen == t1)
    }

    @Test func movedRepositoryUpdatesItsOneEntryAndReportsThePreviousPath() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = RepositoryRegistry(directory: dir)
        try registry.register(
            identity: "id-a", commonDir: "/old/a/.git", workingTree: "/old/a", now: t1)
        let outcome = try registry.register(
            identity: "id-a", commonDir: "/new/a/.git", workingTree: "/new/a", now: t2)
        // A move is reported, never silently absorbed and never a second entry.
        #expect(outcome == .updated(previousCommonDir: "/old/a/.git"))
        let entries = try registry.entries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.commonDir == "/new/a/.git")
        #expect(entry.workingTree == "/new/a")
        #expect(entry.firstRegistered == t1)
        #expect(entry.lastSeen == t2)
    }

    @Test func distinctIdentitiesKeepDistinctEntries() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = RepositoryRegistry(directory: dir)
        try registry.register(
            identity: "id-a", commonDir: "/repos/a/.git", workingTree: "/repos/a", now: t1)
        try registry.register(
            identity: "id-b", commonDir: "/repos/b/.git", workingTree: nil, now: t2)
        let entries = try registry.entries()
        #expect(entries.map(\.identity) == ["id-a", "id-b"])
        let bare = try #require(entries.last)
        #expect(bare.workingTree == nil)
    }

    @Test func aSecondInstanceReadsWhatTheFirstWrote() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RepositoryRegistry(directory: dir).register(
            identity: "id-a", commonDir: "/repos/a/.git", workingTree: "/repos/a", now: t1)
        let second = RepositoryRegistry(directory: dir)
        #expect(try second.entries().map(\.identity) == ["id-a"])
    }

    // MARK: - Reading edge cases

    @Test func missingFileReadsAsEmpty() throws {
        let registry = RepositoryRegistry(directory: scratchDirectory())
        #expect(try registry.entries().isEmpty)
    }

    @Test func corruptFileThrowsUnreadable() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let registry = RepositoryRegistry(directory: dir)
        try Data("not a registry".utf8).write(to: registry.fileURL)
        let error = try #require(throws: RepositoryRegistry.Error.self) {
            _ = try registry.entries()
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
        let registry = RepositoryRegistry(directory: dir)
        try Data(#"{"schemaVersion": 2, "repositories": []}"#.utf8).write(to: registry.fileURL)
        let error = try #require(throws: RepositoryRegistry.Error.self) {
            _ = try registry.entries()
        }
        #expect(error == .unsupportedSchema(version: 2, path: registry.fileURL.path))
    }

    // MARK: - Removal

    @Test func removeDeletesTheEntryAndReportsWhetherItExisted() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = RepositoryRegistry(directory: dir)
        try registry.register(
            identity: "id-a", commonDir: "/repos/a/.git", workingTree: "/repos/a", now: t1)
        #expect(try registry.remove(identity: "id-a") == true)
        #expect(try registry.entries().isEmpty)
        #expect(try registry.remove(identity: "id-a") == false)
    }
}
