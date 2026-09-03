// HunksCommandTests.swift — the `hunks` arm in `runEngineCommand` (#0345)

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

@Suite("hunks engine arm")
struct HunksCommandTests {

    // MARK: - The not-a-repository gate

    /// `WorktreeContext.resolve` throws on its own outside a repository, and
    /// the arm turns every failure into `EnvelopeFail(code: .repositoryError)`
    /// with exit 6. Kills mutation 1 (break the not-a-repository path so it
    /// returns success): a success envelope has `ok == true` and exit 0.
    @Test func nonRepositoryPathReturnsRepositoryErrorAtExitSix() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-hunks-non-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let result = try #require(
            runEngineCommand(arguments: ["hunks", "--staged"], workingDirectory: empty.path))

        #expect(result.exitCode == .repositoryError)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "repository_error")
    }

    // MARK: - The required area flag

    /// `area` is required with no default: exactly one of `--staged` or
    /// `--unstaged`. A missing flag, an unparseable one, and an unknown
    /// extra flag are each refused the way `runYard`'s unknown-subcommand
    /// path refuses — `EnvelopeFail(code: .usage, …)` on stdout, the
    /// human-readable line on stderr, exit 1 — never a default guess and
    /// never a silently ignored argument. The refusal happens before any
    /// repository access, so it holds even in a directory that is not a
    /// repository at all.
    @Test func missingBadAndExtraAreaFlagsAreUsageFailuresAtExitOne() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-hunks-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        for arguments in [["hunks"], ["hunks", "--bogus"], ["hunks", "--staged", "--extra"]] {
            let result = try #require(
                runEngineCommand(arguments: arguments, workingDirectory: empty.path),
                "the arm must claim every hunks invocation, including \(arguments)")

            #expect(result.exitCode == .usage, "arguments \(arguments) are a usage failure")

            let object = try jsonObject(result.stdout)
            #expect(object["ok"] as? Bool == false, "arguments \(arguments) must not succeed")
            let error = try #require(object["error"] as? [String: Any])
            #expect(error["code"] as? String == "usage",
                    "arguments \(arguments) must report the usage error code; got \(error["code"] as? String ?? "nil")")
        }

        let missing = try #require(
            runEngineCommand(arguments: ["hunks"], workingDirectory: empty.path))
        #expect(missing.stderr.contains("[error] usage:"),
                "the human-readable usage line must reach stderr; got '\(missing.stderr)'")
    }

    // MARK: - Fixture-determined values, --unstaged

    /// `FixtureRepository.linear` commits a.txt ("a\n"), b.txt, and c.txt.
    /// Overwriting a.txt with "changed\n" makes it the only changed file, so
    /// `--unstaged` lists exactly one FileDiff whose single hunk removes
    /// "a" and adds "changed" — the values the fixture determines.
    @Test func modifiedTrackedFileListsOneHunkUnderUnstaged() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try "changed\n".write(to: repo.url.appendingPathComponent("a.txt"), atomically: true,
                              encoding: .utf8)

        let result = try #require(
            runEngineCommand(arguments: ["hunks", "--unstaged"], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == true)
        #expect(object["schemaVersion"] as? Int == 1)

        let diffs = try #require(object["result"] as? [[String: Any]],
                                 "result must be the FileDiff array itself")
        #expect(diffs.count == 1, "only a.txt changed; got \(diffs.count) diffs")

        let diff = try #require(diffs.first, "the diff array must be non-empty")
        #expect(diff["path"] as? String == "a.txt")
        #expect(diff["isBinary"] as? Bool == false)

        let hunks = try #require(diff["hunks"] as? [[String: Any]],
                                 "a modified text file must carry hunks")
        #expect(hunks.count == 1, "one replaced line is one hunk; got \(hunks.count)")

        let hunk = try #require(hunks.first, "the hunk array must be non-empty")
        #expect(hunk["header"] as? String == "@@ -1 +1 @@")
        let body = try #require(hunk["body"] as? [String], "a hunk must carry its body lines")
        #expect(body == ["-a", "+changed"],
                "the hunk body must remove 'a' and add 'changed'; got \(body)")

        let id = try #require(hunk["id"] as? String, "a hunk must carry its id")
        #expect(!id.isEmpty, "hunk ids are non-empty")
    }

    // MARK: - Fixture-determined values, --staged

    /// Staging the same modification moves it between the areas the two
    /// flags describe: `--staged` now reports the hunk (HEAD vs index) and
    /// `--unstaged` reports an empty array (index vs worktree). Both
    /// assertions are what kill a flag swapped in the arm.
    @Test func stagedModificationMovesBetweenTheTwoAreas() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try "changed\n".write(to: repo.url.appendingPathComponent("a.txt"), atomically: true,
                              encoding: .utf8)
        _ = try GitProcess().run(["add", "a.txt"], workingDirectory: repo.url.path)

        let staged = try #require(
            runEngineCommand(arguments: ["hunks", "--staged"], workingDirectory: repo.url.path))
        #expect(staged.exitCode == .success)

        let stagedObject = try jsonObject(staged.stdout)
        #expect(stagedObject["ok"] as? Bool == true)
        let stagedDiffs = try #require(stagedObject["result"] as? [[String: Any]],
                                       "result must be the FileDiff array itself")
        #expect(stagedDiffs.count == 1, "the staged change is one diff; got \(stagedDiffs.count)")

        let stagedDiff = try #require(stagedDiffs.first, "the staged diff array must be non-empty")
        #expect(stagedDiff["path"] as? String == "a.txt")
        let stagedHunks = try #require(stagedDiff["hunks"] as? [[String: Any]],
                                       "a modified text file must carry hunks")
        let stagedHunk = try #require(stagedHunks.first, "the staged hunk array must be non-empty")
        let stagedBody = try #require(stagedHunk["body"] as? [String],
                                      "a hunk must carry its body lines")
        #expect(stagedBody == ["-a", "+changed"], "the staged hunk carries the same change; got \(stagedBody)")

        let unstaged = try #require(
            runEngineCommand(arguments: ["hunks", "--unstaged"], workingDirectory: repo.url.path))
        #expect(unstaged.exitCode == .success)

        let unstagedObject = try jsonObject(unstaged.stdout)
        #expect(unstagedObject["ok"] as? Bool == true)
        let unstagedDiffs = try #require(unstagedObject["result"] as? [[String: Any]],
                                         "result must be the FileDiff array itself")
        #expect(unstagedDiffs.isEmpty, "after staging, the unstaged diff is empty; got \(unstagedDiffs)")
    }

    // MARK: - The registry spec

    /// Kills mutation 3 (remove `hunksSpec` from `CommandRegistry.all`):
    /// the spec must be registered, with a non-empty summary, schemaName
    /// "hunks", and exit codes 0, 1 (usage), and 6.
    @Test func hunksSpecIsRegisteredWithRequiredMetadata() throws {
        let spec = try #require(CommandRegistry.lookup(name: "hunks"),
                                "hunks must be in CommandRegistry.all")
        #expect(!spec.summary.isEmpty)
        #expect(spec.schemaName == "hunks")
        let codes = Set(spec.exitCodes.map(\.code))
        #expect(codes.contains(0))
        #expect(codes.contains(1))
        #expect(codes.contains(6))
    }

    // MARK: - Schema binding (step 6)

    /// Binds the generated schema to the type, the way #0226's
    /// `ConflictsCommandTests` and #0227's `WorktreeListCommandTests` do for
    /// their array-valued results: the payload is an array of objects with
    /// optional fields and nested hunk arrays, which the flat-only
    /// `PayloadShape` cannot express (#0194), so the schema carries the
    /// self-reference form naming `hunks` — not a field list. A
    /// fully-populated `FileDiff` then pins its own wire keys to exactly its
    /// six `CodingKeys` (the case name IS the wire key, per #0130), and a
    /// fully-populated `Hunk` pins its eight the same way.
    @Test func schemaResultIsTheSelfReferenceAndTheTypesEncodeOnlyTheirCodingKeys() throws {
        let hunksSchemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardCommandsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit (package root)
            .appendingPathComponent("Schemas", isDirectory: true)
            .appendingPathComponent("hunks.json")

        let data = try Data(contentsOf: hunksSchemaURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(object["envelope"] as? [String: Any])
        let success = try #require(envelope["success"] as? [String: Any])
        let result = try #require(success["result"] as? [String: Any])
        #expect(result["schema"] as? String == "hunks",
                "hunks.json must carry the self-reference form until payload shapes can express arrays")
        #expect(result["fields"] == nil,
                "a field list appeared — bind it to the encoded keys like WhereAmIWireTests does")

        let hunk = Hunk(id: "0123456789ab", path: "a.txt",
                        oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
                        header: "@@ -1 +1 @@", body: ["-a", "+changed"])
        let diff = FileDiff(path: "a.txt", oldMode: "100644", newMode: "100644",
                            isBinary: false,
                            headerText: "diff --git a/a.txt b/a.txt\n",
                            hunks: [hunk])

        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        let json = String(decoding: try encoder.encode(Envelope(result: EncodableResult([diff]))),
                          as: UTF8.self)
        let encoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let diffs = try #require(encoded["result"] as? [[String: Any]],
                                 "an array result encodes as a JSON array")
        let encodedDiff = try #require(diffs.first, "the encoded array must be non-empty")
        #expect(
            Set(encodedDiff.keys)
                == ["path", "oldMode", "newMode", "isBinary", "headerText", "hunks"],
            "a fully-populated FileDiff encodes exactly its six wire keys; got \(encodedDiff.keys.sorted())")

        let encodedHunks = try #require(encodedDiff["hunks"] as? [[String: Any]],
                                        "the encoded diff must carry its hunks array")
        let encodedHunk = try #require(encodedHunks.first, "the encoded hunks array must be non-empty")
        #expect(
            Set(encodedHunk.keys)
                == ["id", "path", "oldStart", "oldCount", "newStart", "newCount", "header", "body"],
            "a fully-populated Hunk encodes exactly its eight wire keys; got \(encodedHunk.keys.sorted())")
    }
}
