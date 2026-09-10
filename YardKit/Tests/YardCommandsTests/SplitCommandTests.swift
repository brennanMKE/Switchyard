// SplitCommandTests.swift — the `split` arm in `runEngineCommand` (#0062)

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

/// Splits a newline-delimited payload into its JSON objects, failing loudly
/// when a line does not decode — Rule 7: an extractor that silently dropped
/// lines would make every following assertion pass vacuously.
private func payloadLines(_ stdout: String) throws -> [[String: Any]] {
    var raw = stdout.split(separator: "\n", omittingEmptySubsequences: false)
    if raw.last == "" { raw = raw.dropLast() }
    #expect(!raw.isEmpty, "the payload must carry at least one JSON line")
    return try raw.map { line in
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try #require(object as? [String: Any],
                            "payload line must decode as a JSON object: \(line)")
    }
}

/// A fresh empty directory that is not a repository — where every usage
/// refusal must hold, because the refusal precedes any repository access.
private func nonRepository() throws -> String {
    let empty = FileManager.default.temporaryDirectory
        .appendingPathComponent("yard-split-non-repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    return empty.path
}

@Suite("split engine arm")
struct SplitCommandTests {

    // MARK: - The not-a-repository gate

    /// The issue's exit table for split has no repository-error code: every
    /// failure the other codes do not name is request-failed, exit 4.
    @Test func nonRepositoryPathReturnsRequestFailedAtExitFour() throws {
        let empty = try nonRepository()
        defer { try? FileManager.default.removeItem(atPath: empty) }

        let result = try #require(
            runEngineCommand(arguments: ["split", "HEAD", "0123456789ab"],
                             workingDirectory: empty))

        #expect(result.exitCode == .requestFailed)
        let object = try #require(try payloadLines(result.stdout).first)
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "request_failed")
    }

    // MARK: - The usage refusals

    /// The grammar: exactly two positionals, at most one of each flag, and
    /// `--sign`/`--no-sign` never together. Anything else — before any
    /// repository access, so it holds in a non-repository directory — is a
    /// usage refusal at exit 1.
    @Test func malformedArgumentsAreUsageFailuresAtExitOne() throws {
        let empty = try nonRepository()
        defer { try? FileManager.default.removeItem(atPath: empty) }

        let cases: [[String]] = [
            ["split", "--bogus"],                                   // unknown flag
            ["split", "HEAD"],                                      // one positional only
            ["split", "HEAD", "id", "extra"],                       // three positionals
            ["split"],                                              // no positionals
            ["split", "HEAD", "--first"],                           // --first without a value
            ["split", "HEAD", "id", "--first", "a", "--first", "b"], // duplicated --first
            ["split", "HEAD", "id", "--second", "a", "--second", "b"], // duplicated --second
            ["split", "HEAD", "id", "--sign", "--no-sign"],         // contradictory
            ["split", "HEAD", "id", "--sign", "--sign"],            // duplicated --sign
            ["split", "HEAD", "id", "extra", "--first", "m"],       // extra positional
        ]
        for arguments in cases {
            let result = try #require(
                runEngineCommand(arguments: arguments, workingDirectory: empty),
                "the arm must claim every split invocation, including \(arguments)")

            #expect(result.exitCode == .usage, "arguments \(arguments) are a usage failure")

            let object = try #require(try payloadLines(result.stdout).first)
            #expect(object["ok"] as? Bool == false, "arguments \(arguments) must not succeed")
            let error = try #require(object["error"] as? [String: Any])
            #expect(error["code"] as? String == "usage",
                    "arguments \(arguments) must report the usage code; got \(error["code"] as? String ?? "nil")")
        }

        let malformed = try #require(
            runEngineCommand(arguments: ["split", "--bogus"], workingDirectory: empty))
        #expect(malformed.stderr.contains("[error] usage:"),
                "the human-readable usage line must reach stderr; got '\(malformed.stderr)'")
    }

    // MARK: - The happy path through the arm

    @Test func splitThroughTheArmExitsZeroWithBothOids() throws {
        var repo = try FixtureRepository()
        try repo.build([
            .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n"]),
            .init("c2", files: ["f.txt": "l1\nl2\nT3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nT12\nl13\nl14\n"]),
        ])
        defer { repo.destroy() }
        let c2 = try #require(repo.oids["c2"])
        let hunk = try #require(
            try commitDiff(at: repo.url.path, revision: c2).flatMap(\.hunks)
                .first { $0.body.contains("+T3") })

        let result = try #require(
            runEngineCommand(arguments: ["split", c2, hunk.id,
                                          "--first", "first half", "--second", "second half"],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)
        let lines = try payloadLines(result.stdout)
        #expect(lines.count == 1, "one summary line carrying both oids")
        let summary = try #require(lines.first?["result"] as? [String: Any])
        let first = try #require(summary["first"] as? String)
        let second = try #require(summary["second"] as? String)
        #expect(!first.isEmpty && !second.isEmpty, "both oids are present")
        let originalTree = try repo.revParse("\(c2)^{tree}")
        #expect(try repo.revParse("\(second)^{tree}") == originalTree,
                "the payload's second half rebuilds the original tree")
        #expect(try repo.revParse("\(second)^") == first)
        #expect(try repo.revParse("refs/heads/main") == second)
        let subjects = try GitProcess().run(
            ["log", "--format=%s"], workingDirectory: repo.url.path).lines
        #expect(subjects.first == "second half")
        #expect(subjects.dropFirst().first == "first half")
    }

    // MARK: - Unknown hunk id exits 4

    @Test func unknownHunkIDExitsFourWithRequestFailed() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["split", "HEAD", "0123456789ab"],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .requestFailed)
        let object = try #require(try payloadLines(result.stdout).first)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "request_failed")
        let message = try #require(error["message"] as? String)
        #expect(message.contains("0123456789ab"), "the refusal names the id")
    }

    // MARK: - The registry spec

    @Test func splitSpecIsRegisteredWithRequiredMetadata() throws {
        let spec = try #require(CommandRegistry.lookup(name: "split"),
                                "split must be in CommandRegistry.all")
        #expect(!spec.summary.isEmpty)
        #expect(spec.schemaName == "split")
        let codes = Set(spec.exitCodes.map(\.code))
        #expect(codes == Set([0, 1, 4, 8]),
                "split's documented exit codes are exactly 0, 1, 4, and 8; got \(codes.sorted())")
        let flags = spec.flags.map(\.long)
        #expect(flags == ["first", "second", "sign", "no-sign"])
    }

    // MARK: - Schema binding

    /// The payload is a single object with two oid fields; the flat-only
    /// `PayloadShape` carries it as the self-reference form naming `split`
    /// (#0194), and a fully-populated `Split.Result` pins its wire keys to
    /// exactly its two `CodingKeys`.
    @Test func schemaResultIsTheSelfReferenceAndTheResultEncodesOnlyItsWireKeys() throws {
        let splitSchemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardCommandsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit (package root)
            .appendingPathComponent("Schemas", isDirectory: true)
            .appendingPathComponent("split.json")

        let data = try Data(contentsOf: splitSchemaURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(object["envelope"] as? [String: Any])
        let success = try #require(envelope["success"] as? [String: Any])
        let result = try #require(success["result"] as? [String: Any])
        #expect(result["schema"] as? String == "split",
                "split.json must carry the self-reference form until payload shapes can express objects")
        #expect(result["fields"] == nil,
                "a field list appeared — bind it to the encoded keys")

        let resultValue = Split.Result(
            first: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            second: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        let json = String(decoding: try encoder.encode(Envelope(result: EncodableResult(resultValue))),
                          as: UTF8.self)
        let encoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let result_ = try #require(encoded["result"] as? [String: Any])
        #expect(Set(result_.keys) == ["first", "second"],
                "Split.Result encodes exactly its two wire keys; got \(result_.keys.sorted())")
    }
}
