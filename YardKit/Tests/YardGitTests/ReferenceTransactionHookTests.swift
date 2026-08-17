// ReferenceTransactionHookTests.swift — the hook composition (#0191)
//
// `ReferenceTransaction.decide` owns every invariant (exit 0 always; only
// `committed` reads stdin; the journal's own transactions are skipped via
// the marker). `JournalObserved.record` writes one entry. These tests pin
// the seam: that a committed foreign transaction is actually persisted end
// to end, and that a persistence failure never escapes as a non-zero exit.

import Foundation
import Testing
@testable import YardGit

private let zeros40 = String(repeating: "0", count: 40)

struct ReferenceTransactionHookTests {

    private struct DecodedRefUpdate: Decodable, Equatable {
        let oldValue: String
        let newValue: String
        let refName: String
    }

    private struct DecodedMetadata: Decodable {
        let schemaVersion: Int
        let updates: [DecodedRefUpdate]
    }

    private static func stdin(_ oidA: String, _ oidB: String) -> Data {
        Data("""
        \(zeros40) \(oidA) refs/heads/one
        \(oidA) \(oidB) refs/heads/two
        """.utf8)
    }

    @Test func aForeignCommittedTransactionIsRecordedAsOneObservedEntry() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let head = try repo.revParse("HEAD")

        let outcome = ReferenceTransaction.runHook(
            stateArgument: "committed",
            environment: [:],
            in: context,
            readStandardInput: { Self.stdin(head, zeros40) })

        #expect(outcome.exitCode == 0)
        let recorded = try #require(outcome.recorded)
        #expect(outcome.recordingFailure == nil)

        let listed = try JournalObserved.list(in: context)
        #expect(!listed.isEmpty)
        #expect(listed.map(\.id) == [recorded.id])

        let json = try GitProcess().run(
            ["cat-file", "blob",
             JournalObserved.refPrefix + recorded.id.string + ":" + JournalAnchor.metadataTreeEntryName],
            workingDirectory: context.topLevel ?? context.gitDir
        ).standardOutput
        #expect(!json.isEmpty)
        let decoded = try JSONDecoder().decode(DecodedMetadata.self, from: json)
        #expect(!decoded.updates.isEmpty)
        #expect(decoded.updates == [
            DecodedRefUpdate(oldValue: zeros40, newValue: head, refName: "refs/heads/one"),
            DecodedRefUpdate(oldValue: head, newValue: zeros40, refName: "refs/heads/two"),
        ])
    }

    @Test func theJournalsOwnTransactionsAreNotRecorded() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let head = try repo.revParse("HEAD")

        var read = false
        let outcome = ReferenceTransaction.runHook(
            stateArgument: "committed",
            environment: [GitProcess.markerVariable: "1"],
            in: context,
            readStandardInput: {
                read = true
                return Self.stdin(head, zeros40)
            })

        #expect(outcome.exitCode == 0)
        #expect(outcome.recorded == nil)
        #expect(!read, "our own transactions must not read stdin")

        let listed = try JournalObserved.list(in: context)
        #expect(listed.isEmpty)
    }

    @Test func aPreparedTransactionRecordsNothingAndReadsNoInput() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let head = try repo.revParse("HEAD")

        for state in ["prepared", "nonsense-future-state"] {
            var read = false
            let outcome = ReferenceTransaction.runHook(
                stateArgument: state,
                environment: [:],
                in: context,
                readStandardInput: {
                    read = true
                    return Self.stdin(head, zeros40)
                })

            #expect(outcome.exitCode == 0, "state \(state) must exit 0")
            #expect(outcome.recorded == nil, "state \(state) must record nothing")
            #expect(!read, "state \(state) must not read stdin")
        }

        let listed = try JournalObserved.list(in: context)
        #expect(listed.isEmpty)
    }

    @Test func aFailureToPersistStillExitsZero() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        // Resolve the context with a real git first -- /usr/bin/false fails
        // rev-parse too, so resolving with it throws WorktreeContext.Error
        // before the hook is ever reached.
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let head = try repo.revParse("HEAD")

        let failingGit = GitProcess(executablePath: "/usr/bin/false")
        let outcome = ReferenceTransaction.runHook(
            stateArgument: "committed",
            environment: [:],
            in: context,
            git: failingGit,
            readStandardInput: { Self.stdin(head, zeros40) })

        #expect(outcome.exitCode == 0)
        #expect(outcome.recorded == nil)
        #expect(outcome.recordingFailure != nil)
    }
}
