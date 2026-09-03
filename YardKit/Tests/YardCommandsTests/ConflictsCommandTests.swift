// ConflictsCommandTests.swift — the `conflicts` arm in `runEngineCommand` (#0226)

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

@Suite("conflicts engine arm")
struct ConflictsCommandTests {

    // MARK: - The not-a-repository gate

    /// `WorktreeContext.resolve` throws on its own outside a repository, and
    /// the arm turns every failure into `EnvelopeFail(code: .repositoryError)`
    /// with exit 6. Kills mutation 1 (break the not-a-repository path so it
    /// returns success): a success envelope has `ok == true` and exit 0.
    @Test func nonRepositoryPathReturnsRepositoryErrorAtExitSix() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-conflicts-non-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let result = try #require(
            runEngineCommand(arguments: ["conflicts"], workingDirectory: empty.path))

        #expect(result.exitCode == .repositoryError)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "repository_error")
    }

    // MARK: - Fixture-determined values

    /// `FixtureRepository.conflicted` diverges both sides on `f.txt` and
    /// merges `--no-commit`: exactly one conflicted path, kind `UU`, and all
    /// three stages present (base, ours, theirs) because neither side is an
    /// add or a delete. The values asserted are what the fixture determines.
    @Test func conflictedFixtureReportsOneUUPathWithAllThreeStages() throws {
        let repo = try FixtureRepository.conflicted()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["conflicts"], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == true)
        #expect(object["schemaVersion"] as? Int == 1)

        let files = try #require(object["result"] as? [[String: Any]],
                                 "result must be the conflicts array itself")
        #expect(files.count == 1, "the fixture conflicts exactly one path; got \(files.count)")

        let file = try #require(files.first, "the array must be non-empty")
        #expect(file["path"] as? String == "f.txt")
        #expect(file["kind"] as? String == "UU")

        for stage in ["base", "ours", "theirs"] {
            let entry = try #require(file[stage] as? [String: Any],
                                     "\(stage) stage must exist for a both-modified conflict")
            let oid = try #require(entry["oid"] as? String)
            #expect(!oid.isEmpty, "\(stage) oid must be non-empty")
            #expect(entry["mode"] as? String == "100644")
        }
    }

    // MARK: - The registry spec

    /// Kills mutation 3 (remove `conflictsSpec` from `CommandRegistry.all`):
    /// the spec must be registered, with a non-empty summary, a non-empty
    /// schemaName, and exit codes 0 and 6 at least.
    @Test func conflictsSpecIsRegisteredWithRequiredMetadata() throws {
        let spec = try #require(CommandRegistry.lookup(name: "conflicts"),
                                "conflicts must be in CommandRegistry.all")
        #expect(!spec.summary.isEmpty)
        #expect(spec.schemaName == "conflicts")
        let codes = Set(spec.exitCodes.map(\.code))
        #expect(codes.contains(0))
        #expect(codes.contains(6))
    }

    // MARK: - Schema binding (step 6)

    /// Binds the generated schema to the type, the way
    /// `WhereAmIWireTests.schemaFieldNamesMatchTheEncodedKeysExactly` does —
    /// adapted the way #0225 did for its array-valued result: the payload is
    /// an array of objects with nested stage entries, which the flat-only
    /// `PayloadShape` cannot express, so the schema carries the self-reference
    /// form naming `conflicts` — not a field list. A fully-populated
    /// `ConflictedFile` then pins its own wire keys to exactly
    /// `path, kind, base, ours, theirs` (`pathBytes` never rides the wire,
    /// #0129 Decision 6), and each stage to exactly `oid, mode`.
    @Test func schemaResultIsTheSelfReferenceAndTheTypeEncodesOnlyItsFiveKeys() throws {
        let conflictsSchemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardCommandsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit (package root)
            .appendingPathComponent("Schemas", isDirectory: true)
            .appendingPathComponent("conflicts.json")

        let data = try Data(contentsOf: conflictsSchemaURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(object["envelope"] as? [String: Any])
        let success = try #require(envelope["success"] as? [String: Any])
        let result = try #require(success["result"] as? [String: Any])
        #expect(result["schema"] as? String == "conflicts",
                "conflicts.json must carry the self-reference form until payload shapes can express arrays")
        #expect(result["fields"] == nil,
                "a field list appeared — bind it to the encoded keys like WhereAmIWireTests does")

        let file = ConflictedFile(
            path: "f.txt",
            pathBytes: Array("f.txt".utf8),
            kind: .bothModified,
            base: ConflictedFile.StageEntry(
                oid: "0123456789abcdef0123456789abcdef01234567", mode: "100644"),
            ours: ConflictedFile.StageEntry(
                oid: "89abcdef0123456789abcdef0123456789abcdef", mode: "100644"),
            theirs: ConflictedFile.StageEntry(
                oid: "fedcba9876543210fedcba9876543210fedcba98", mode: "100755"))

        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        let json = String(decoding: try encoder.encode(Envelope(result: EncodableResult([file]))),
                          as: UTF8.self)
        let encoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let files = try #require(encoded["result"] as? [[String: Any]],
                                 "an array result encodes as a JSON array")
        let encodedFile = try #require(files.first, "the encoded array must be non-empty")
        #expect(Set(encodedFile.keys) == ["path", "kind", "base", "ours", "theirs"],
                "a fully-populated ConflictedFile encodes exactly its five wire keys; got \(encodedFile.keys.sorted())")
        #expect(encodedFile["pathBytes"] == nil, "raw path bytes never ride the wire")

        let base = try #require(encodedFile["base"] as? [String: Any])
        #expect(Set(base.keys) == ["oid", "mode"],
                "a stage encodes exactly oid and mode; got \(base.keys.sorted())")
    }
}
