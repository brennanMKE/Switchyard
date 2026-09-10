// AbsorbCommandTests.swift — the `absorb` arm in `runEngineCommand` (#0061)

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

/// Splits a newline-delimited payload into its JSON objects, failing loudly
/// when a line does not decode — Rule 7: an extractor that silently dropped
/// lines would make every following assertion pass vacuously.
private func payloadLines(_ stdout: String) throws -> [[String: Any]] {
    // The payload is newline-TERMINATED, so the split yields one trailing
    // empty element; drop exactly that one and nothing else.
    var raw = stdout.split(separator: "\n", omittingEmptySubsequences: false)
    if raw.last == "" { raw = raw.dropLast() }
    #expect(!raw.isEmpty, "the payload must carry at least one JSON line")
    return try raw.map { line in
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try #require(object as? [String: Any],
                            "payload line must decode as a JSON object: \(line)")
    }
}

@Suite("absorb engine arm")
struct AbsorbCommandTests {

    // MARK: - The not-a-repository gate

    /// The issue's exit table for absorb has no repository-error code: every
    /// failure the other codes do not name is request-failed, exit 4.
    @Test func nonRepositoryPathReturnsRequestFailedAtExitFour() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-absorb-non-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let result = try #require(
            runEngineCommand(arguments: ["absorb"], workingDirectory: empty.path))

        #expect(result.exitCode == .requestFailed)
        let object = try #require(try payloadLines(result.stdout).first)
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "request_failed")
    }

    // MARK: - The optional --dry-run flag

    /// The only accepted tails are `[]` and `["--dry-run"]`. Anything else —
    /// an unknown flag, a trailing token, a duplicated flag — is a usage
    /// refusal at exit 1, before any repository access, so it holds in a
    /// directory that is not a repository at all.
    @Test func unknownDuplicatedAndExtraFlagsAreUsageFailuresAtExitOne() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-absorb-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        // Bare ["absorb"] is a valid invocation — it is the non-repository
        // failure path above, not a usage one.
        for arguments in [["absorb", "--bogus"], ["absorb", "extra"],
                          ["absorb", "--dry-run", "--extra"],
                          ["absorb", "--dry-run", "--dry-run"]] {
            let result = try #require(
                runEngineCommand(arguments: arguments, workingDirectory: empty.path),
                "the arm must claim every absorb invocation, including \(arguments)")

            #expect(result.exitCode == .usage, "arguments \(arguments) are a usage failure")

            let object = try #require(try payloadLines(result.stdout).first)
            #expect(object["ok"] as? Bool == false, "arguments \(arguments) must not succeed")
            let error = try #require(object["error"] as? [String: Any])
            #expect(error["code"] as? String == "usage",
                    "arguments \(arguments) must report the usage code; got \(error["code"] as? String ?? "nil")")
        }

        let malformed = try #require(
            runEngineCommand(arguments: ["absorb", "--bogus"], workingDirectory: empty.path))
        #expect(malformed.stderr.contains("[error] usage:"),
                "the human-readable usage line must reach stderr; got '\(malformed.stderr)'")
    }

    // MARK: - Nothing staged: nothing-to-do at exit 0

    @Test func nothingStagedExitsZeroWithAnEmptyDistribution() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["absorb"], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)
        let lines = try payloadLines(result.stdout)
        #expect(lines.count == 1, "no hunks means no outcome lines, just the summary")
        let summary = try #require(lines.first?["result"] as? [String: Any])
        #expect(summary["absorbed"] as? Int == 0)
        #expect(summary["leftStaged"] as? Int == 0)
        #expect(summary["head"] == nil, "nothing was rewritten, so no head is reported")
    }

    // MARK: - --dry-run reports the plan without touching anything

    @Test func dryRunReportsTheDistributionAndChangesNothing() throws {
        var repo = try FixtureRepository()
        try repo.build([
            .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n"]),
            .init("c2", files: ["f.txt": "l1\nl2\nl3\nL4\nl5\nl6\nl7\nl8\n"]),
            .init("c3", files: ["f.txt": "l1\nl2\nl3\nL4\nl5\nl6\nl7\nL8\n"]),
        ])
        defer { repo.destroy() }
        let headBefore = try repo.revParse("HEAD")

        try "l1\nl2\nl3\nM4\nl5\nl6\nl7\nL8\n"
            .write(to: repo.url.appendingPathComponent("f.txt"), atomically: true,
                   encoding: .utf8)
        _ = try GitProcess().run(["add", "f.txt"], workingDirectory: repo.url.path)

        let result = try #require(
            runEngineCommand(arguments: ["absorb", "--dry-run"],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)

        let lines = try payloadLines(result.stdout)
        #expect(lines.count == 2, "one hunk outcome line plus the summary line")

        let firstObject = try #require(lines.first)
        let outcome = try #require(firstObject["result"] as? [String: Any])
        #expect(outcome["path"] as? String == "f.txt")
        #expect(outcome["leftStaged"] as? Bool == false)
        #expect(outcome["target"] as? String == (try repo.revParse("HEAD~1")),
                "line 4 was last touched by c2, the commit below HEAD")

        let lastObject = try #require(lines.last)
        let summary = try #require(lastObject["result"] as? [String: Any])
        #expect(summary["absorbed"] as? Int == 1)
        #expect(summary["leftStaged"] as? Int == 0)
        #expect(summary["head"] == nil, "a dry run reports no rewritten HEAD")

        #expect(try repo.revParse("HEAD") == headBefore, "a dry run must not move HEAD")
        #expect(!repo.isMidRebase)
    }

    // MARK: - Conflicts exit 8

    /// The unmerged-index refusal is the pre-flight conflict path — the same
    /// exit 8 a conflicted autosquash replay produces, before anything is
    /// touched.
    @Test func unmergedIndexExitsEightWithBlockedOnConflicts() throws {
        let repo = try FixtureRepository.conflicted()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["absorb"], workingDirectory: repo.url.path))

        #expect(result.exitCode == .blockedOnConflicts)
        let object = try #require(try payloadLines(result.stdout).first)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "blocked_on_conflicts")
        let message = try #require(error["message"] as? String)
        #expect(message.contains("f.txt"))
        #expect(!repo.isMidRebase, "the pre-flight refusal precedes any rebase")
    }

    // MARK: - The registry spec

    @Test func absorbSpecIsRegisteredWithRequiredMetadata() throws {
        let spec = try #require(CommandRegistry.lookup(name: "absorb"),
                                "absorb must be in CommandRegistry.all")
        #expect(!spec.summary.isEmpty)
        #expect(spec.schemaName == "absorb")
        let codes = Set(spec.exitCodes.map(\.code))
        #expect(codes == Set([0, 1, 4, 8]),
                "absorb's documented exit codes are exactly 0, 1, 4, and 8; got \(codes.sorted())")
        let flags = spec.flags.map(\.long)
        #expect(flags == ["dry-run"])
    }

    // MARK: - Schema binding

    /// The payload is per-hunk outcome objects with absent-when-nil
    /// optionals, which the flat-only `PayloadShape` cannot express (#0194),
    /// so the schema carries the self-reference form naming `absorb` — and a
    /// fully-populated `AbsorbHunkOutcome` pins its own wire keys to exactly
    /// its five `CodingKeys` (the case name IS the wire key, per #0130).
    @Test func schemaResultIsTheSelfReferenceAndTheOutcomeEncodesOnlyItsWireKeys() throws {
        let absorbSchemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardCommandsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit (package root)
            .appendingPathComponent("Schemas", isDirectory: true)
            .appendingPathComponent("absorb.json")

        let data = try Data(contentsOf: absorbSchemaURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(object["envelope"] as? [String: Any])
        let success = try #require(envelope["success"] as? [String: Any])
        let result = try #require(success["result"] as? [String: Any])
        #expect(result["schema"] as? String == "absorb",
                "absorb.json must carry the self-reference form until payload shapes can express objects")
        #expect(result["fields"] == nil,
                "a field list appeared — bind it to the encoded keys")

        let outcome = AbsorbHunkOutcome(
            hunkID: "0123456789ab", path: "f.txt", leftStaged: false,
            target: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", reason: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        let json = String(decoding: try encoder.encode(Envelope(result: EncodableResult(outcome))),
                          as: UTF8.self)
        let encoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let result_ = try #require(encoded["result"] as? [String: Any])
        #expect(Set(result_.keys) == ["hunkID", "path", "leftStaged", "target"],
                "a confident outcome encodes exactly its four present keys; got \(result_.keys.sorted())")
    }
}
