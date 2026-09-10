// RerereServingTests.swift — the `rerere status` arm in `runEngineCommand` (#0065)

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

/// Builds a repository with rerere enabled and one recorded resolution:
/// `base → (ours, side)` diverging on `f.txt`, merged, resolved to `a/R/c`,
/// committed. The rr-cache then holds `preimage` + `postimage` for the one
/// conflict id, with no conflict live.
private func recordedFixture() throws -> FixtureRepository {
    let git = GitProcess()
    var repo = try FixtureRepository()
    try repo.build([
        .init("base", files: ["f.txt": "a\nb\nc\n"]),
        .init("side", parents: ["base"], files: ["f.txt": "a\nB\nc\n"]),
        .init("ours", parents: ["base"], files: ["f.txt": "a\nX\nc\n"]),
    ])
    try git.run(["config", "rerere.enabled", "true"], workingDirectory: repo.url.path)
    let side = try #require(repo.oids["side"])
    _ = try git.capture(
        ["merge", "--no-commit", side], workingDirectory: repo.url.path)
    try "a\nR\nc\n".write(
        to: repo.url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    try git.run(["add", "f.txt"], workingDirectory: repo.url.path)
    try git.run(["commit", "-q", "-m", "resolved"], workingDirectory: repo.url.path)
    return repo
}

@Suite("rerere engine arm")
struct RerereServingTests {

    // MARK: - The recorded shape over the wire

    /// `switchyard rerere status` with no flag: the default output IS the
    /// JSON envelope payload, carrying `enabled` and one entry per recorded
    /// resolution with its conflict id and state.
    @Test func rerereStatusServesTheJSONPayloadByDefault() throws {
        let repo = try recordedFixture()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["rerere", "status"], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == true)
        #expect(object["schemaVersion"] as? Int == 1)

        let payload = try #require(object["result"] as? [String: Any],
                                   "result must be the status payload")
        #expect(payload["enabled"] as? Bool == true)
        let entries = try #require(payload["entries"] as? [[String: Any]],
                                   "entries must be an array of entry objects")
        #expect(entries.count == 1, "one recorded conflict; got \(entries.count)")

        let entry = try #require(entries.first, "the entries array must be non-empty")
        let conflictID = try #require(entry["conflictID"] as? String)
        #expect(conflictID.count >= 40, "a conflict id is a full object id; got \(conflictID)")
        #expect(conflictID.allSatisfy { $0.isHexDigit })
        #expect(entry["state"] as? String == "recorded",
                "a committed resolution is recorded, not merely known")
        #expect(entry["paths"] as? [String] == [],
                "no conflict is live after the resolve, so no path is attributed")
        #expect(entry["replayedPaths"] as? [String] == [])
    }

    /// `--json` is accepted and documented: it produces byte-identical
    /// output, because the default output is already the JSON payload.
    @Test func theJSONFlagProducesByteIdenticalOutput() throws {
        let repo = try recordedFixture()
        defer { repo.destroy() }

        let plain = try #require(
            runEngineCommand(arguments: ["rerere", "status"], workingDirectory: repo.url.path))
        let flagged = try #require(
            runEngineCommand(
                arguments: ["rerere", "status", "--json"], workingDirectory: repo.url.path))

        #expect(plain.stdout == flagged.stdout)
        #expect(plain.stderr == flagged.stderr)
        #expect(plain.exitCode == flagged.exitCode)
        #expect(plain.exitCode == .success)
    }

    /// The disabled shape: rerere unset, no rr-cache — `enabled` false and
    /// no entries, a completed command at exit 0, never a refusal.
    @Test func disabledRerereIsACompletedCommandWithTheDisabledShape() throws {
        let repo = try FixtureRepository()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["rerere", "status"], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        let payload = try #require(
            (try jsonObject(result.stdout))["result"] as? [String: Any])
        #expect(payload["enabled"] as? Bool == false)
        let entries = try #require(payload["entries"] as? [[String: Any]])
        #expect(entries.isEmpty)
    }

    // MARK: - The strict grammar: usage at exit 1

    /// A mutating `git rerere` subcommand is USAGE at this surface, before
    /// any repository access — the arm never invokes rerere in any spelling,
    /// mutating ones least of all.
    @Test func unknownSubcommandIsUsageAtExitOne() throws {
        let result = try #require(
            runEngineCommand(
                arguments: ["rerere", "forget", "f.txt"], workingDirectory: "/"))

        #expect(result.exitCode == .usage)
        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "usage")
        #expect(result.stderr.hasPrefix("[error]"), "the human-readable line rides stderr")
    }

    @Test func unknownFlagIsUsageAtExitOne() throws {
        let result = try #require(
            runEngineCommand(
                arguments: ["rerere", "status", "--all"], workingDirectory: "/"))

        #expect(result.exitCode == .usage)
        let error = try #require((try jsonObject(result.stdout))["error"] as? [String: Any])
        #expect(error["code"] as? String == "usage")
    }

    @Test func bareRerereIsUsageAtExitOne() throws {
        let result = try #require(
            runEngineCommand(arguments: ["rerere"], workingDirectory: "/"))

        #expect(result.exitCode == .usage)
        let error = try #require((try jsonObject(result.stdout))["error"] as? [String: Any])
        #expect(error["code"] as? String == "usage")
    }

    @Test func duplicatedJSONFlagIsUsageAtExitOne() throws {
        let result = try #require(
            runEngineCommand(
                arguments: ["rerere", "status", "--json", "--json"], workingDirectory: "/"))

        #expect(result.exitCode == .usage)
        let error = try #require((try jsonObject(result.stdout))["error"] as? [String: Any])
        #expect(error["code"] as? String == "usage")
    }

    // MARK: - The request-failed arm

    /// A working directory outside a repository is request-failed at exit 4 —
    /// the rerere surface's outcomes map is 0/1/4, not the conflicts
    /// command's 0/6.
    @Test func nonRepositoryPathIsRequestFailedAtExitFour() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-rerere-non-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let result = try #require(
            runEngineCommand(arguments: ["rerere", "status"], workingDirectory: empty.path))

        #expect(result.exitCode == .requestFailed)
        let error = try #require((try jsonObject(result.stdout))["error"] as? [String: Any])
        #expect(error["code"] as? String == "request_failed")
    }

    // MARK: - The registry spec

    /// The spec must be registered, with a non-empty summary, the
    /// `rerere-status` schema name, and the 0/1/4 outcomes map.
    @Test func rerereSpecIsRegisteredWithRequiredMetadata() throws {
        let spec = try #require(CommandRegistry.lookup(name: "rerere"),
                                "rerere must be in CommandRegistry.all")
        #expect(!spec.summary.isEmpty)
        #expect(spec.schemaName == "rerere-status")
        let codes = Set(spec.exitCodes.map(\.code))
        #expect(codes == [0, 1, 4], "the outcomes map is 0/1/4; got \(codes.sorted())")
        #expect(spec.flags.contains { $0.long == "json" },
                "--json is documented on the spec")
    }
}
