// StatusCommandTests.swift — the `status` arm in `runEngineCommand` (#0225)

import Foundation
import Testing
import YardGit
import YardKit
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

@Suite("status engine arm")
struct StatusCommandTests {

    /// The not-a-repository gate. `gitStatus` throws on its own outside a
    /// repository (git exits non-zero), and the arm turns every failure into
    /// `EnvelopeFail(code: .repositoryError)` with exit 6.
    @Test func nonRepositoryPathReturnsRepositoryErrorAtExitSix() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-status-non-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let result = try #require(
            runEngineCommand(arguments: ["status"], workingDirectory: empty.path))

        #expect(result.exitCode == .repositoryError)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "repository_error")
    }

    /// A clean repository reports no entries at all. `FixtureRepository.linear`
    /// commits a→b→c and leaves nothing dirty, so `entries` must be present —
    /// `WorktreeStatus` always encodes its one key — and empty.
    @Test func cleanRepositoryReturnsAnEmptyEntriesList() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["status"], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == true)
        #expect(object["schemaVersion"] as? Int == 1)

        let payload = try #require(object["result"] as? [String: Any])
        let entries = try #require(payload["entries"] as? [[String: Any]],
                                   "result must carry an entries array, present even when empty")
        #expect(entries.isEmpty)
    }

    /// A modified tracked file and an untracked file are reported with the
    /// porcelain states the fixture determines: overwriting `a.txt` on disk is
    /// `worktree: "M"`, staged `.`; a new file is `worktree: "?"`, staged `.`.
    /// Exactly two entries — no more.
    @Test func modifiedAndUntrackedFilesAreReportedWithPorcelainStates() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        try "changed\n".write(to: repo.url.appendingPathComponent("a.txt"), atomically: true,
                              encoding: .utf8)
        try "new\n".write(to: repo.url.appendingPathComponent("untracked.txt"), atomically: true,
                          encoding: .utf8)

        let result = try #require(
            runEngineCommand(arguments: ["status"], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)

        let object = try jsonObject(result.stdout)
        let payload = try #require(object["result"] as? [String: Any])
        let entries = try #require(payload["entries"] as? [[String: Any]])
        #expect(entries.count == 2)

        let modified = try #require(entries.first { ($0["path"] as? String) == "a.txt" },
                                    "the modified tracked file must be reported")
        #expect(modified["staged"] as? String == ".")
        #expect(modified["worktree"] as? String == "M")

        let untracked = try #require(entries.first { ($0["path"] as? String) == "untracked.txt" },
                                     "the untracked file must be reported")
        #expect(untracked["staged"] as? String == ".")
        #expect(untracked["worktree"] as? String == "?")
    }

    // MARK: - The registry spec

    /// Kills mutation 3 (remove `statusSpec` from `CommandRegistry.all`):
    /// the spec must be registered, with a non-empty summary, a non-empty
    /// schemaName, and exit codes 0 and 6 at least.
    @Test func statusSpecIsRegisteredWithRequiredMetadata() throws {
        let spec = try #require(CommandRegistry.lookup(name: "status"),
                                "status must be in CommandRegistry.all")
        #expect(!spec.summary.isEmpty)
        #expect(!spec.schemaName.isEmpty)
        let codes = Set(spec.exitCodes.map(\.code))
        #expect(codes.contains(0))
        #expect(codes.contains(6))
    }

    /// Binds the generated schema to the type, the way
    /// `WhereAmIWireTests.schemaFieldNamesMatchTheEncodedKeysExactly` does —
    /// adapted to what status honestly declares (#0225): the payload is an
    /// array of objects, which `PayloadShape` is flat-only and cannot express,
    /// so the schema carries the self-reference form naming `status` — not a
    /// field list. The encoded result's top-level keys are pinned to exactly
    /// `entries`, which is what reddens if the wire key drifts.
    @Test func schemaResultIsTheSelfReferenceAndTheTypeEncodesOnlyEntries() throws {
        let statusSchemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardCommandsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit (package root)
            .appendingPathComponent("Schemas", isDirectory: true)
            .appendingPathComponent("status.json")

        let data = try Data(contentsOf: statusSchemaURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(object["envelope"] as? [String: Any])
        let success = try #require(envelope["success"] as? [String: Any])
        let result = try #require(success["result"] as? [String: Any])
        #expect(result["schema"] as? String == "status",
                "status.json must carry the self-reference form until payload shapes can express arrays")
        #expect(result["fields"] == nil,
                "a field list appeared — bind it to the encoded keys like WhereAmIWireTests does")

        var modified = WorktreeStatusEntry(path: "a.txt")
        modified.staged = .unmodified
        modified.worktree = .modified
        var renamed = WorktreeStatusEntry(path: "b.txt", pathBytes: Array("b.txt".utf8))
        renamed.originalPath = "old.txt"
        renamed.submodule = .clean
        let status = WorktreeStatus(entries: [modified, renamed])

        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        let json = String(decoding: try encoder.encode(Envelope(result: EncodableResult(status))),
                          as: UTF8.self)
        let encoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let encodedResult = try #require(encoded["result"] as? [String: Any])
        #expect(Set(encodedResult.keys) == ["entries"],
                "a fully-populated WorktreeStatus encodes exactly one top-level key; got \(encodedResult.keys.sorted())")
    }
}
