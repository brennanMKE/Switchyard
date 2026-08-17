// WhereAmICommandTests.swift — the `whereami` arm in `runEngineCommand` (#0124)

import Foundation
import Testing
import YardGit
@testable import YardCommands

/// Parses a command's stdout into its top-level JSON object, failing loudly
/// (rather than returning an empty dictionary) when it does not decode —
/// Rule 7: an extractor that silently returns empty would make every
/// following assertion pass unconditionally.
private func jsonObject(_ text: String) throws -> [String: Any] {
    let data = Data(text.utf8)
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any], "stdout must decode as a JSON object: \(text)")
}

@Suite("whereami engine arm")
struct WhereAmICommandTests {

    /// The not-a-repository gate. `whereAmI` itself does not throw outside a
    /// repository — it degrades to nil/0/"" — so this exercises the
    /// `WorktreeContext.resolve` call that has to run first. Kills mutation 1
    /// (drop the gate: exit becomes 0) and mutation 2 (gate present but wired
    /// to `.success` instead of `.repositoryError`).
    @Test func nonRepositoryPathReturnsRepositoryErrorAtExitSix() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-whereami-non-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let result = try #require(
            runEngineCommand(arguments: ["whereami"], workingDirectory: empty.path))

        #expect(result.exitCode == .repositoryError)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "repository_error")
    }

    /// Inside a real repository the command succeeds and returns the
    /// fixture-determined values: `FixtureRepository` inits with
    /// `--initial-branch=main`, so `branch` must be exactly "main", and
    /// `headOID` is the 7-character short form, not the 40-character full one.
    @Test func repositoryPathReturnsSuccessEnvelopeWithBranchAndShortOID() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["whereami"], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == true)
        #expect(object["schemaVersion"] as? Int == 1)

        let payload = try #require(object["result"] as? [String: Any])
        #expect(payload["branch"] as? String == "main")

        let headOID = try #require(payload["headOID"] as? String)
        #expect(headOID.count == 7, "headOID must be the short form; asserting 40 fails here")
    }

    /// `conflictCount` for a two-file conflict fixture, which is what tells
    /// apart "counts conflicted paths" from "counts stage entries" (three per
    /// path). Also exercises the arm end to end against a non-trivial repo
    /// state, not just a freshly initialized one.
    @Test func conflictedRepositoryReportsConflictCountTwo() throws {
        let repo = try FixtureRepository.conflictedTwo()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["whereami"], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)

        let object = try jsonObject(result.stdout)
        let payload = try #require(object["result"] as? [String: Any])
        #expect(payload["conflictCount"] as? Int == 2)
        #expect(payload["hasConflicts"] as? Bool == true)
    }

    /// `runEngineCommand` composes with `runYard`'s local commands by
    /// returning nil for anything it does not own — unrelated to `whereami`
    /// directly, but the contract the arm above must not break.
    @Test func unrelatedCommandsStillReturnNil() {
        #expect(runEngineCommand(arguments: ["noop"], workingDirectory: "/tmp") == nil)
        #expect(runEngineCommand(arguments: [], workingDirectory: "/tmp") == nil)
    }
}
