// WorktreeListCommandTests.swift — the `wt list` arm in `runEngineCommand` (#0227)

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

@Suite("wt list engine arm")
struct WorktreeListCommandTests {

    // MARK: - The not-a-repository gate

    /// `WorktreeContext.resolve` throws on its own outside a repository, and
    /// the arm turns every failure into `EnvelopeFail(code: .repositoryError)`
    /// with exit 6. Kills mutation 1 (break the not-a-repository path so it
    /// returns success): a success envelope has `ok == true` and exit 0.
    @Test func nonRepositoryPathReturnsRepositoryErrorAtExitSix() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-wt-list-non-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let result = try #require(
            runEngineCommand(arguments: ["wt", "list"], workingDirectory: empty.path))

        #expect(result.exitCode == .repositoryError)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "repository_error")
    }

    // MARK: - Fixture-determined values

    /// `FixtureRepository.linear` builds a repository on branch `main`;
    /// `addWorktree(named:branch:)` then creates a linked worktree at
    /// `<parent>/<repoName>-wt-side` on a new branch `side`. So the list is
    /// exactly two entries: the main worktree (path equal to the fixture's
    /// resolved `url.path`, `isMainWorktree` true) and the linked one
    /// (`branch` "side", a path that differs, unlocked, not bare). The values
    /// asserted are what the fixture determines.
    @Test func linearFixtureWithOneLinkedWorktreeListsExactlyTwoEntries() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let linkedPath = try repo.addWorktree(named: "side", branch: "side")

        let result = try #require(
            runEngineCommand(arguments: ["wt", "list"], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == true)
        #expect(object["schemaVersion"] as? Int == 1)

        let entries = try #require(object["result"] as? [[String: Any]],
                                   "result must be the worktree array itself")
        #expect(entries.count == 2, "main plus one linked worktree; got \(entries.count)")

        let main = try #require(
            entries.first(where: { $0["isMainWorktree"] as? Bool == true }),
            "exactly the main worktree must carry isMainWorktree == true")
        #expect(main["path"] as? String == repo.url.path,
                "the main worktree's path is the fixture's resolved repository path")

        let linked = try #require(
            entries.first(where: { $0["branch"] as? String == "side" }),
            "the linked worktree must report branch \"side\"; got \(entries.map { $0.keys.sorted() })")
        #expect(linked["isMainWorktree"] as? Bool == false)
        let path = try #require(linked["path"] as? String, "the linked entry must carry a path")
        #expect(!path.isEmpty, "the linked entry's path must be non-empty")
        #expect(path != repo.url.path, "the linked worktree lives outside the repository")
        #expect(path == linkedPath.path, "the linked entry's path is what addWorktree returned")
        #expect(linked["locked"] as? Bool == false)
        #expect(linked["bare"] as? Bool == false)
    }

    // MARK: - The registry spec

    /// Kills mutation 3 (remove `wtSpec` from `CommandRegistry.all`): the
    /// spec must be registered, with a non-empty summary, a non-empty
    /// schemaName, and exit codes 0 and 6 at least.
    @Test func wtSpecIsRegisteredWithRequiredMetadata() throws {
        let spec = try #require(CommandRegistry.lookup(name: "wt"),
                                "wt must be in CommandRegistry.all")
        #expect(!spec.summary.isEmpty)
        #expect(spec.schemaName == "wt-list")
        let codes = Set(spec.exitCodes.map(\.code))
        #expect(codes.contains(0))
        #expect(codes.contains(6))
    }

    // MARK: - Schema binding (step 6)

    /// Binds the generated schema to the type, the way #0226's
    /// `ConflictsCommandTests` does for its array-valued result: the payload
    /// is an array of objects with optional fields, which the flat-only
    /// `PayloadShape` cannot express (#0194), so the schema carries the
    /// self-reference form naming `wt-list` — not a field list. A
    /// fully-populated `WorktreeEntry` then pins its own wire keys to exactly
    /// the ten `CodingKeys` (the case name IS the wire key, per #0130), and
    /// an entry whose optional fields are nil encodes without them — absent
    /// means absent.
    @Test func schemaResultIsTheSelfReferenceAndTheTypeEncodesOnlyItsTenKeys() throws {
        let wtListSchemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardCommandsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit (package root)
            .appendingPathComponent("Schemas", isDirectory: true)
            .appendingPathComponent("wt-list.json")

        let data = try Data(contentsOf: wtListSchemaURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(object["envelope"] as? [String: Any])
        let success = try #require(envelope["success"] as? [String: Any])
        let result = try #require(success["result"] as? [String: Any])
        #expect(result["schema"] as? String == "wt-list",
                "wt-list.json must carry the self-reference form until payload shapes can express arrays")
        #expect(result["fields"] == nil,
                "a field list appeared — bind it to the encoded keys like WhereAmIWireTests does")

        let entry = WorktreeEntry(
            path: "/repo/wt-with\nnewline",
            head: "0123456789abcdef0123456789abcdef01234567",
            branch: "side",
            locked: true,
            lockReason: "agent session",
            bare: false,
            detached: false,
            prunable: true,
            prunableReason: "stale lockfile",
            isMainWorktree: false)

        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        let json = String(decoding: try encoder.encode(Envelope(result: EncodableResult([entry]))),
                          as: UTF8.self)
        let encoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let entries = try #require(encoded["result"] as? [[String: Any]],
                                   "an array result encodes as a JSON array")
        let encodedEntry = try #require(entries.first, "the encoded array must be non-empty")
        #expect(
            Set(encodedEntry.keys)
                == ["path", "head", "branch", "locked", "lockReason",
                    "bare", "detached", "prunable", "prunableReason", "isMainWorktree"],
            "a fully-populated WorktreeEntry encodes exactly its ten wire keys; got \(encodedEntry.keys.sorted())")
        #expect(encodedEntry["path"] as? String == "/repo/wt-with\nnewline",
                "an entry path may contain newlines and must ride the wire as-is")

        // Nil optionals are omitted, not encoded as null: an unlocked entry
        // carries no `lockReason` (nor `head`, `branch`, or `prunableReason`).
        let unlocked = WorktreeEntry(path: "/repo/main")
        let unlockedJSON = String(
            decoding: try encoder.encode(Envelope(result: EncodableResult([unlocked]))),
            as: UTF8.self)
        let unlockedEncoded = try #require(
            try JSONSerialization.jsonObject(with: Data(unlockedJSON.utf8)) as? [String: Any])
        let unlockedEntries = try #require(
            unlockedEncoded["result"] as? [[String: Any]],
            "an array result encodes as a JSON array")
        let unlockedEntry = try #require(unlockedEntries.first, "the encoded array must be non-empty")
        #expect(
            Set(unlockedEntry.keys)
                == ["path", "locked", "bare", "detached", "prunable", "isMainWorktree"],
            "a minimal WorktreeEntry omits every nil optional; got \(unlockedEntry.keys.sorted())")
    }
}
