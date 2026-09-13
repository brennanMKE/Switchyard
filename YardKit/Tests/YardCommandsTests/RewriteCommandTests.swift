// RewriteCommandTests.swift — the `reword`/`drop`/`reorder` arms in
// `runEngineCommand` (#0063)

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
        .appendingPathComponent("yard-rewrite-non-repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    return empty.path
}

/// `c1 → c2 → c3` on `main`, with disjoint changes so rewrites replay clean.
private func linearFixture() throws -> (repo: FixtureRepository, c1: String, c2: String, c3: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "a1\na2\na3\na4\na5\n"]),
        .init("c2", files: ["f.txt": "a1\na2\na3\na4\na5\n", "g.txt": "g1\ng2\n"]),
        .init("c3", files: ["f.txt": "a1\na2\nA3\na4\na5\n", "g.txt": "g1\ng2\n"]),
    ])
    return (repo, try #require(repo.oids["c1"]), try #require(repo.oids["c2"]),
            try #require(repo.oids["c3"]))
}

@Suite("reword/drop/reorder engine arms")
struct RewriteCommandTests {

    // MARK: - The not-a-repository gate

    /// The exit table for the three rewrites has no repository-error code:
    /// every failure the other codes do not name is request-failed, exit 4.
    @Test func nonRepositoryPathReturnsRequestFailedAtExitFour() throws {
        let empty = try nonRepository()
        defer { try? FileManager.default.removeItem(atPath: empty) }

        for arguments in [["reword", "HEAD", "--message", "m"],
                          ["drop", "HEAD"],
                          ["reorder", "HEAD", "--after", "HEAD~1"],
                          ["rebase-onto", "HEAD"],
                          ["set-tip", "HEAD"]] {
            let result = try #require(
                runEngineCommand(arguments: arguments, workingDirectory: empty),
                "the arm must claim \(arguments)")
            #expect(result.exitCode == .requestFailed, "arguments \(arguments)")
            let object = try #require(try payloadLines(result.stdout).first)
            #expect(object["ok"] as? Bool == false)
            let error = try #require(object["error"] as? [String: Any])
            #expect(error["code"] as? String == "request_failed")
        }
    }

    // MARK: - The usage refusals

    /// The grammar, per subcommand: reword requires <commit> and --message;
    /// drop takes <commit> and nothing else but signing; reorder requires
    /// <commit> <ref> and exactly one of --before/--after. Anything else —
    /// before any repository access, so it holds in a non-repository
    /// directory — is a usage refusal at exit 1.
    @Test func malformedArgumentsAreUsageFailuresAtExitOne() throws {
        let empty = try nonRepository()
        defer { try? FileManager.default.removeItem(atPath: empty) }

        let cases: [[String]] = [
            ["reword", "--bogus"],                                     // unknown flag
            ["reword"],                                                // no positional
            ["reword", "HEAD"],                                        // no --message
            ["reword", "--message", "m"],                              // no positional
            ["reword", "HEAD", "extra", "--message", "m"],             // two positionals
            ["reword", "HEAD", "--message", "a", "--message", "b"],    // duplicated --message
            ["reword", "HEAD", "--message"],                           // value missing
            ["reword", "HEAD", "--message", "m", "--after", "x"],      // reorder's flag
            ["drop", "--bogus"],                                       // unknown flag
            ["drop"],                                                  // no positional
            ["drop", "HEAD", "extra"],                                 // two positionals
            ["drop", "HEAD", "--message", "m"],                        // reword's flag
            ["drop", "HEAD", "--before", "x"],                         // reorder's flag
            ["drop", "HEAD", "--sign", "--no-sign"],                   // contradictory
            ["drop", "HEAD", "--sign", "--sign"],                      // duplicated --sign
            ["reorder", "--bogus"],                                    // unknown flag
            ["reorder"],                                               // no positional
            ["reorder", "HEAD"],                                       // no --before/--after
            ["reorder", "HEAD", "extra", "--after", "r"],              // two positionals
            ["reorder", "HEAD", "--before", "x", "--after", "y"],      // both position flags
            ["reorder", "HEAD", "--after"],                            // value missing
            ["reorder", "HEAD", "--before", "a", "--before", "b"],     // duplicated --before
            ["reorder", "HEAD", "--before", "r", "--message", "m"],    // reword's flag
            ["rebase-onto", "--bogus"],                                // unknown flag
            ["rebase-onto"],                                           // no positional
            ["rebase-onto", "HEAD", "extra"],                          // two positionals
            ["rebase-onto", "HEAD", "--message", "m"],                 // reword's flag
            ["rebase-onto", "HEAD", "--before", "x"],                  // reorder's flag
            ["rebase-onto", "HEAD", "--sign", "--no-sign"],            // contradictory
            ["set-tip", "--bogus"],                                    // unknown flag
            ["set-tip"],                                               // no positional
            ["set-tip", "HEAD", "extra"],                              // two positionals
            ["set-tip", "HEAD", "--sign"],                             // set-tip takes no flags
            ["set-tip", "HEAD", "--no-sign"],                          // set-tip takes no flags
            ["set-tip", "HEAD", "--before", "x"],                      // reorder's flag
            ["set-tip", "HEAD", "--message", "m"],                     // reword's flag
        ]
        for arguments in cases {
            let result = try #require(
                runEngineCommand(arguments: arguments, workingDirectory: empty),
                "the arm must claim every rewrite invocation, including \(arguments)")

            #expect(result.exitCode == .usage, "arguments \(arguments) are a usage failure")

            let object = try #require(try payloadLines(result.stdout).first)
            #expect(object["ok"] as? Bool == false, "arguments \(arguments) must not succeed")
            let error = try #require(object["error"] as? [String: Any])
            #expect(error["code"] as? String == "usage",
                    "arguments \(arguments) must report the usage code; got \(error["code"] as? String ?? "nil")")
        }

        let malformed = try #require(
            runEngineCommand(arguments: ["reword", "--bogus"], workingDirectory: empty))
        #expect(malformed.stderr.contains("[error] usage:"),
                "the human-readable usage line must reach stderr; got '\(malformed.stderr)'")
    }

    // MARK: - The happy paths through the arm

    @Test func rewordThroughTheArmExitsZeroWithTheNewHead() throws {
        let (repo, _, c2, _) = try linearFixture()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["reword", c2, "--message", "rewritten"],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)
        let lines = try payloadLines(result.stdout)
        #expect(lines.count == 1, "one summary line carrying the new head oid")
        let summary = try #require(lines.first?["result"] as? [String: Any])
        let head = try #require(summary["head"] as? String)
        #expect(!head.isEmpty, "the payload carries the new head oid")
        #expect(try repo.revParse("refs/heads/main") == head)
        let subjects = try GitProcess().run(
            ["log", "--format=%s"], workingDirectory: repo.url.path).lines
        #expect(subjects.count == 3)
        #expect(try #require(subjects.dropFirst().first) == "rewritten")
    }

    @Test func dropThroughTheArmExitsZeroWithTheNewHead() throws {
        let (repo, _, c2, _) = try linearFixture()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["drop", c2], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        let summary = try #require(try payloadLines(result.stdout).first?["result"] as? [String: Any])
        let head = try #require(summary["head"] as? String)
        #expect(try repo.revParse("refs/heads/main") == head)
        let count = try GitProcess().run(
            ["rev-list", "--count", "main"], workingDirectory: repo.url.path).lines[0]
        #expect(count == "2", "the commit is gone from the branch")
    }

    @Test func reorderThroughTheArmExitsZeroWithTheNewHead() throws {
        let (repo, _, c2, c3) = try linearFixture()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["reorder", c3, "--before", c2],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        let summary = try #require(try payloadLines(result.stdout).first?["result"] as? [String: Any])
        let head = try #require(summary["head"] as? String)
        #expect(try repo.revParse("refs/heads/main") == head)
        let subjects = try GitProcess().run(
            ["log", "--format=%s"], workingDirectory: repo.url.path).lines
        #expect(subjects.first == "c2", "the reference commit is the new tip")
        #expect(subjects.dropFirst().first == "c3", "the moved commit sits before it")
    }

    /// `main` = `c1 → c2` plus a parallel line `b1` off `c1` — the base a
    /// rebase-onto replays the branch onto.
    private func rebaseFixture() throws -> (repo: FixtureRepository, base: String) {
        var repo = try FixtureRepository()
        try repo.build([
            .init("c1", files: ["f.txt": "a1\na2\na3\na4\na5\n"]),
            .init("b1", parents: ["c1"], files: ["f.txt": "B1\na2\na3\na4\na5\n"]),
            .init("c2", parents: ["c1"], files: [
                "f.txt": "a1\na2\na3\na4\na5\n", "g.txt": "g1\ng2\n",
            ]),
        ])
        try repo.branch("main", at: "c2")
        try repo.checkout("main")
        return (repo, try #require(repo.oids["b1"]))
    }

    @Test func rebaseOntoThroughTheArmExitsZeroWithTheNewHead() throws {
        let (repo, base) = try rebaseFixture()

        let result = try #require(
            runEngineCommand(arguments: ["rebase-onto", base],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        let summary = try #require(try payloadLines(result.stdout).first?["result"] as? [String: Any])
        let head = try #require(summary["head"] as? String)
        #expect(try repo.revParse("refs/heads/main") == head)
        let subjects = try GitProcess().run(
            ["log", "--format=%s"], workingDirectory: repo.url.path).lines
        #expect(subjects.count == 3, "c1, the base's pick, and the replayed c2")
        #expect(subjects.first == "c2", "the replayed tip is the new head")
        #expect(try repo.revParse("main~1") == base, "the pick sits on the base")
    }

    @Test func setTipThroughTheArmExitsZeroWithTheNewHead() throws {
        let (repo, c1, _, _) = try linearFixture()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["set-tip", c1], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        let summary = try #require(try payloadLines(result.stdout).first?["result"] as? [String: Any])
        let head = try #require(summary["head"] as? String)
        #expect(head == c1)
        #expect(try repo.revParse("refs/heads/main") == c1)
        #expect(try repo.revParse("HEAD") == c1, "the attached HEAD follows the moved branch")
    }

    // MARK: - Refusals through the arm exit 4

    @Test func unknownCommitExitsFourWithRequestFailed() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["drop", "no-such-revision"],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .requestFailed)
        let object = try #require(try payloadLines(result.stdout).first)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "request_failed")
        let message = try #require(error["message"] as? String)
        #expect(message.contains("no-such-revision"), "the refusal names the revision")
    }

    @Test func aConflictedReplayThroughTheArmExitsEightAndStaysResumable() throws {
        var repo = try FixtureRepository()
        try repo.build([
            .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"]),
            .init("c2", files: ["f.txt": "l1\nl2\nT3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"]),
            .init("c3", files: ["f.txt": "l1\nl2\nZ3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"]),
        ])
        defer { repo.destroy() }
        let c2 = try #require(repo.oids["c2"])

        let result = try #require(
            runEngineCommand(arguments: ["drop", c2], workingDirectory: repo.url.path))

        #expect(result.exitCode == .blockedOnConflicts)
        let object = try #require(try payloadLines(result.stdout).first)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "blocked_on_conflicts")
        let message = try #require(error["message"] as? String)
        #expect(message.contains("f.txt"), "the conflicted path is named")
        #expect(message.contains("resumable"), "the envelope names the resumable state")

        _ = try? GitProcess().run(
            ["cherry-pick", "--abort"], workingDirectory: repo.url.path)
    }

    // MARK: - The registry spec

    @Test func rewriteSpecsAreRegisteredWithRequiredMetadata() throws {
        let expected: [(name: String, schema: String, flags: [String], codes: Set<Int32>)] = [
            ("reword", "reword", ["message", "sign", "no-sign"], [0, 1, 4, 8]),
            ("drop", "drop", ["sign", "no-sign"], [0, 1, 4, 8]),
            ("reorder", "reorder", ["before", "after", "sign", "no-sign"], [0, 1, 4, 8]),
            ("rebase-onto", "rebase-onto", ["sign", "no-sign"], [0, 1, 4, 8]),
            ("set-tip", "set-tip", [], [0, 1, 4]),
        ]
        for (name, schema, flags, codes) in expected {
            let spec = try #require(CommandRegistry.lookup(name: name),
                                    "\(name) must be in CommandRegistry.all")
            #expect(!spec.summary.isEmpty, "\(name) must carry a summary")
            #expect(spec.schemaName == schema)
            let documented = Set(spec.exitCodes.map(\.code))
            #expect(documented == codes,
                    "\(name)'s documented exit codes are exactly \(codes.sorted()); got \(documented.sorted())")
            #expect(spec.flags.map(\.long) == flags,
                    "\(name)'s flags must be \(flags); got \(spec.flags.map(\.long))")
        }
    }

    // MARK: - Schema binding

    /// The payload is a single object with one oid field; the flat-only
    /// `PayloadShape` carries it as the self-reference form naming the
    /// command's schema, and a fully-populated `Rewrite.Result` pins its
    /// wire key to exactly its one `CodingKey`.
    @Test func rewriteSchemasAreTheSelfReferenceAndTheResultEncodesOnlyItsWireKey() throws {
        let schemasDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardCommandsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit (package root)
            .appendingPathComponent("Schemas", isDirectory: true)

        for schemaName in ["reword", "drop", "reorder", "rebase-onto", "set-tip"] {
            let data = try Data(contentsOf: schemasDirectory
                .appendingPathComponent("\(schemaName).json"))
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let envelope = try #require(object["envelope"] as? [String: Any])
            let success = try #require(envelope["success"] as? [String: Any])
            let result = try #require(success["result"] as? [String: Any])
            #expect(result["schema"] as? String == schemaName,
                    "\(schemaName).json must carry the self-reference form")
            #expect(result["fields"] == nil,
                    "a field list appeared — bind it to the encoded keys")
        }

        let resultValue = Rewrite.Result(
            head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        let json = String(decoding: try encoder.encode(Envelope(result: EncodableResult(resultValue))),
                          as: UTF8.self)
        let encoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let result_ = try #require(encoded["result"] as? [String: Any])
        #expect(Set(result_.keys) == ["head"],
                "Rewrite.Result encodes exactly its one wire key; got \(result_.keys.sorted())")
    }
}
