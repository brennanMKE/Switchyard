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
