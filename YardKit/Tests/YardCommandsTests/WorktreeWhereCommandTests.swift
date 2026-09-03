// WorktreeWhereCommandTests.swift — the `wt where` arm in `runEngineCommand` (#0228)

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

@Suite("wt where engine arm")
struct WorktreeWhereCommandTests {

    // MARK: - The not-a-repository gate

    /// `WorktreeContext.resolve` throws on its own outside a repository, and
    /// the arm turns every failure into `EnvelopeFail(code: .repositoryError)`
    /// with exit 6. Kills mutation 1 (break the not-a-repository path so it
    /// returns success): a success envelope has `ok == true` and exit 0.
    @Test func nonRepositoryPathReturnsRepositoryErrorAtExitSix() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-wt-where-non-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let result = try #require(
            runEngineCommand(arguments: ["wt", "where"], workingDirectory: empty.path))

        #expect(result.exitCode == .repositoryError)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "repository_error")
    }

    // MARK: - Fixture-determined values

    /// `FixtureRepository.linear` builds a repository on branch `main`;
    /// `addWorktree(named:branch:)` creates a linked worktree at
    /// `<parent>/<repoName>-wt-side` on a new branch `side`. Running
    /// `wt where` **from that linked worktree** must report that directory
    /// basename as the worktree name (git names worktrees by their
    /// directory under `$GIT_COMMON_DIR/worktrees/` — the branch "side"
    /// only appears in the suffix), its own path, and the fixture
    /// repository as the main worktree — all values the fixture
    /// determines. Running it again from the **main** worktree must omit
    /// `worktreeName` entirely (nil in the main worktree; the synthesized
    /// encoder drops nil optionals, so absent means absent).
    @Test func linearFixtureWhereReportsTheLinkedWorktreesContext() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let linkedPath = try repo.addWorktree(named: "side", branch: "side")

        let linked = try #require(
            runEngineCommand(arguments: ["wt", "where"], workingDirectory: linkedPath.path))

        #expect(linked.exitCode == .success)
        #expect(linked.stderr.isEmpty)

        let linkedObject = try jsonObject(linked.stdout)
        #expect(linkedObject["ok"] as? Bool == true)
        #expect(linkedObject["schemaVersion"] as? Int == 1)

        let result = try #require(linkedObject["result"] as? [String: Any],
                                  "result must be a single object, not an array")
        #expect(result["worktreeName"] as? String == linkedPath.lastPathComponent,
                "git names a worktree by its directory basename — the branch \"side\" rides the \"-wt-side\" suffix, not the name")
        #expect(result["path"] as? String == linkedPath.path,
                "the reported path is the linked worktree's own path")
        #expect(result["mainWorktreePath"] as? String == repo.url.path,
                "the main worktree is the fixture repository itself")
        let gitDir = try #require(result["gitDir"] as? String, "gitDir must be present")
        #expect(!gitDir.isEmpty, "gitDir is always non-empty in a linked worktree")
        let commonDir = try #require(result["commonDir"] as? String, "commonDir must be present")
        #expect(!commonDir.isEmpty, "commonDir is always non-empty in a linked worktree")

        let main = try #require(
            runEngineCommand(arguments: ["wt", "where"], workingDirectory: repo.url.path))
        #expect(main.exitCode == .success)
        let mainObject = try jsonObject(main.stdout)
        let mainResult = try #require(mainObject["result"] as? [String: Any],
                                      "result must be a single object, not an array")
        #expect(mainResult["worktreeName"] == nil,
                "the main worktree has no worktree name — absent means absent, got \(mainResult["worktreeName"] ?? "present")")
        #expect(mainResult["path"] as? String == repo.url.path)
        #expect(mainResult["mainWorktreePath"] as? String == repo.url.path)
    }

    // MARK: - The registry spec

    /// Kills mutation 3 (remove `wtWhereSpec` from `CommandRegistry.all`):
    /// the spec must be registered, with a non-empty summary, a non-empty
    /// schemaName, and exit codes 0 and 6 at least.
    @Test func wtWhereSpecIsRegisteredWithRequiredMetadata() throws {
        let spec = try #require(CommandRegistry.lookup(name: "wt where"),
                                "wt where must be in CommandRegistry.all")
        #expect(!spec.summary.isEmpty)
        #expect(spec.schemaName == "wt-where")
        let codes = Set(spec.exitCodes.map(\.code))
        #expect(codes.contains(0))
        #expect(codes.contains(6))
    }

    // MARK: - Schema binding (step 6)

    /// Binds the generated schema to the type, the way the `wt list` arm's
    /// test does for its array-valued result: the payload is a single object
    /// whose fields are flat strings/optionals, but #0228 follows the
    /// engine-command nil-payload precedent (`statusSpec`, `conflictsSpec`,
    /// `wtSpec`), so the schema carries the self-reference form naming
    /// `wt-where` — not a field list. A fully-populated `WorktreeWhere` then
    /// pins its own wire keys to exactly the five `CodingKeys` (the case name
    /// IS the wire key, per #0130), and one whose optionals are nil encodes
    /// without them — absent means absent. Kills mutation 2 (rename a
    /// CodingKeys case): the key set no longer matches.
    @Test func schemaResultIsTheSelfReferenceAndTheTypeEncodesOnlyItsFiveKeys() throws {
        let wtWhereSchemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardCommandsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit (package root)
            .appendingPathComponent("Schemas", isDirectory: true)
            .appendingPathComponent("wt-where.json")

        let data = try Data(contentsOf: wtWhereSchemaURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(object["envelope"] as? [String: Any])
        let success = try #require(envelope["success"] as? [String: Any])
        let result = try #require(success["result"] as? [String: Any])
        #expect(result["schema"] as? String == "wt-where",
                "wt-where.json must carry the self-reference form while the payload stays nil")
        #expect(result["fields"] == nil,
                "a field list appeared — bind it to the encoded keys like WhereAmIWireTests does")

        let whereResult = WorktreeWhere(
            worktreeName: "side",
            path: "/repo/wt-with\nnewline",
            gitDir: "/repo/.git/worktrees/wt-with-newline",
            commonDir: "/repo/.git",
            mainWorktreePath: "/repo")

        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        let json = String(decoding: try encoder.encode(Envelope(result: EncodableResult(whereResult))),
                          as: UTF8.self)
        let encoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let encodedResult = try #require(encoded["result"] as? [String: Any],
                                         "a single-object result encodes as a JSON object")
        #expect(
            Set(encodedResult.keys)
                == ["worktreeName", "path", "gitDir", "commonDir", "mainWorktreePath"],
            "a fully-populated WorktreeWhere encodes exactly its five wire keys; got \(encodedResult.keys.sorted())")
        #expect(encodedResult["path"] as? String == "/repo/wt-with\nnewline",
                "a worktree path may contain newlines and must ride the wire as-is")

        // Nil optionals are omitted, not encoded as null: from the main
        // worktree a result carries no `worktreeName`, `path`, or
        // `mainWorktreePath` — only the always-present git dirs.
        let bareDirs = WorktreeWhere(
            worktreeName: nil,
            path: nil,
            gitDir: "/r/.git",
            commonDir: "/r/.git",
            mainWorktreePath: nil)
        let bareJSON = String(
            decoding: try encoder.encode(Envelope(result: EncodableResult(bareDirs))),
            as: UTF8.self)
        let bareEncoded = try #require(
            try JSONSerialization.jsonObject(with: Data(bareJSON.utf8)) as? [String: Any])
        let bareResult = try #require(bareEncoded["result"] as? [String: Any],
                                      "a single-object result encodes as a JSON object")
        #expect(Set(bareResult.keys) == ["gitDir", "commonDir"],
                "a minimal WorktreeWhere omits every nil optional; got \(bareResult.keys.sorted())")
    }
}
