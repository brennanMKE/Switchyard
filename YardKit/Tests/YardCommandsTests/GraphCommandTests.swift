// GraphCommandTests.swift — the `graph` arm in `runEngineCommand` (#0347)

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

@Suite("graph engine arm")
struct GraphCommandTests {

    // MARK: - The not-a-repository gate

    /// `WorktreeContext.resolve` throws on its own outside a repository, and
    /// the arm turns every failure into `EnvelopeFail(code: .repositoryError)`
    /// with exit 6. Kills mutation 1 (break the not-a-repository path so it
    /// returns success): a success envelope has `ok == true` and exit 0.
    @Test func nonRepositoryPathReturnsRepositoryErrorAtExitSix() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-graph-non-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let result = try #require(
            runEngineCommand(arguments: ["graph"], workingDirectory: empty.path))

        #expect(result.exitCode == .repositoryError)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "repository_error")
    }

    // MARK: - The strict argument grammar

    /// `graph` accepts only `[]` and `["--limit", "<positive int>"]` (#0347):
    /// a missing value, a non-numeric/zero/negative value, the joined form
    /// `--limit=3`, a repeated flag, or any other token (e.g. `--all`, whose
    /// revision surface belongs to the app's graph view) is a usage failure —
    /// `EnvelopeFail(code: .usage, …)` on stdout, the human-readable line on
    /// stderr, exit 1 — never silently ignored and never a default guess.
    /// The refusal happens before any repository access, so it holds in a
    /// directory that is not a repository at all *and* in a real fixture
    /// repository: the refusal is argument-shaped, not repository-shaped.
    @Test func badArgumentTailsAreUsageFailuresAtExitOneEverywhere() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-graph-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let refusedTails: [[String]] = [
            ["graph", "--limit"],                       // missing value
            ["graph", "--limit", "abc"],                // non-numeric
            ["graph", "--limit", "0"],                  // zero
            ["graph", "--limit", "-1"],                 // negative
            ["graph", "--limit=3"],                     // joined form
            ["graph", "--all"],                         // unknown flag
            ["graph", "--limit", "3", "--limit", "4"],  // repeated flag
            ["graph", "--limit", "3", "extra"],         // trailing token
        ]
        for workingDirectory in [empty.path, repo.url.path] {
            for arguments in refusedTails {
                let result = try #require(
                    runEngineCommand(arguments: arguments, workingDirectory: workingDirectory),
                    "the arm must claim every graph invocation, including \(arguments)")

                #expect(result.exitCode == .usage,
                        "arguments \(arguments) are a usage failure in \(workingDirectory)")

                let object = try jsonObject(result.stdout)
                #expect(object["ok"] as? Bool == false,
                        "arguments \(arguments) must not succeed in \(workingDirectory)")
                let error = try #require(object["error"] as? [String: Any])
                #expect(error["code"] as? String == "usage",
                        "arguments \(arguments) must report the usage error code; got \(error["code"] as? String ?? "nil")")
                #expect(result.stderr.contains("[error] usage:"),
                        "the human-readable usage line must reach stderr for \(arguments); got '\(result.stderr)'")
            }
        }
    }

    // MARK: - Fixture-determined values, the linear fixture

    /// `FixtureRepository.linear` commits a → b → c on `main`, a single
    /// lane: three rows, newest first, every row in lane 0, first-parent
    /// edges staying in lane 0 (`parentLanes` `[[0], [0], []]`, the values
    /// LaneAssignmentTests pins for this fixture), and the root carrying no
    /// parents.
    @Test func linearFixtureRendersThreeRowsInOneLaneNewestFirst() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["graph"], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == true)
        #expect(object["schemaVersion"] as? Int == 1)

        let rows = try #require(object["result"] as? [[String: Any]],
                                "result must be the GraphRow array itself")
        #expect(rows.count == 3, "a→b→c is exactly three rows; got \(rows.count)")

        let oidC = try #require(repo.oids["c"], "the fixture must record c's oid")
        let oidB = try #require(repo.oids["b"], "the fixture must record b's oid")
        let oidA = try #require(repo.oids["a"], "the fixture must record a's oid")
        let oids = try #require(rows.map { $0["oid"] as? String },
                                "every row must carry its oid")
        #expect(oids == [oidC, oidB, oidA],
                "the graph is c, b, a — newest first; got \(oids)")

        let lanes = try #require(rows.map { $0["lane"] as? Int },
                                 "every row must carry its lane")
        #expect(lanes == [0, 0, 0], "a linear history occupies one lane; got \(lanes)")

        let parentLanes = try #require(rows.map { $0["parentLanes"] as? [Int] },
                                       "every row must carry its parentLanes")
        #expect(parentLanes == [[0], [0], []],
                "first parents stay in the commit's own lane; the root has no edges; got \(parentLanes)")

        let parents = try #require(rows.map { $0["parents"] as? [String] },
                                   "every row must carry its parents")
        #expect(parents == [[oidB], [oidA], []],
                "the fixture chains a→b→c; got \(parents)")
    }

    // MARK: - Fixture-determined values, the merged fixture

    /// `FixtureRepository.merged` is the smallest DAG with a second lane:
    /// branch off a, merged back. The lane values are the ones
    /// LaneAssignmentTests pins for this fixture — the merge sits in lane 0
    /// with its second parent's edge routed to lane 1, the branch commit
    /// occupies lane 1, and both the first parent and the shared base stay
    /// in lane 0.
    @Test func mergedFixturePutsTheBranchInASecondLane() throws {
        let repo = try FixtureRepository.merged()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["graph"], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == true)
        #expect(object["schemaVersion"] as? Int == 1)

        let rows = try #require(object["result"] as? [[String: Any]],
                                "result must be the GraphRow array itself")
        #expect(rows.count == 4, "a, b, side, merge is exactly four rows; got \(rows.count)")

        let oidMerge = try #require(repo.oids["merge"], "the fixture must record merge's oid")
        let oidB = try #require(repo.oids["b"], "the fixture must record b's oid")
        let oidSide = try #require(repo.oids["side"], "the fixture must record side's oid")
        let oidA = try #require(repo.oids["a"], "the fixture must record a's oid")

        let merge = try #require(
            rows.first(where: { $0["oid"] as? String == oidMerge }),
            "the merge commit must be among the rows")
        #expect(merge["parents"] as? [String] == [oidB, oidSide],
                "the merge commit has two parents in parent order; got \(merge["parents"] as? [String] ?? [])")
        #expect(merge["lane"] as? Int == 0, "the merge commit sits in lane 0")
        #expect(merge["parentLanes"] as? [Int] == [0, 1],
                "the first parent runs straight down and side's edge continues in lane 1; got \(merge["parentLanes"] as? [Int] ?? [])")

        let b = try #require(rows.first(where: { $0["oid"] as? String == oidB }),
                             "b must be among the rows")
        #expect(b["lane"] as? Int == 0, "main's line stays in lane 0")

        let side = try #require(rows.first(where: { $0["oid"] as? String == oidSide }),
                                "side must be among the rows")
        #expect(side["lane"] as? Int == 1, "the branch commit occupies the second lane")

        let a = try #require(rows.first(where: { $0["oid"] as? String == oidA }),
                             "a must be among the rows")
        #expect(a["lane"] as? Int == 0, "the shared base converges into the leftmost lane")
    }

    // MARK: - --limit caps the rows

    /// `--limit <n>` passes through as the engine's `--max-count`: two rows
    /// on the linear fixture, the newest two, parents outside the window
    /// still named.
    @Test func limitFlagCapsTheRowsAtTheRequestedCount() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let oidC = try #require(repo.oids["c"], "the fixture must record c's oid")
        let oidB = try #require(repo.oids["b"], "the fixture must record b's oid")
        let oidA = try #require(repo.oids["a"], "the fixture must record a's oid")

        let result = try #require(
            runEngineCommand(arguments: ["graph", "--limit", "2"],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == true)

        let rows = try #require(object["result"] as? [[String: Any]],
                                "result must be the GraphRow array itself")
        #expect(rows.count == 2, "--limit 2 leaves exactly two rows; got \(rows.count)")

        let oids = try #require(rows.map { $0["oid"] as? String },
                                "every row must carry its oid")
        #expect(oids == [oidC, oidB], "the cap keeps the newest two; got \(oids)")

        let parents = try #require(rows.map { $0["parents"] as? [String] },
                                   "every row must carry its parents")
        #expect(parents == [[oidB], [oidA]],
                "parents outside the window still appear; got \(parents)")
    }

    // MARK: - The registry spec

    /// Kills mutation 3 (remove `graphSpec` from `CommandRegistry.all`): the
    /// spec must be registered, with a non-empty summary, schemaName "graph",
    /// exit codes 0, 1 (usage), and 6, and the one flag this surface accepts.
    @Test func graphSpecIsRegisteredWithRequiredMetadata() throws {
        let spec = try #require(CommandRegistry.lookup(name: "graph"),
                                "graph must be in CommandRegistry.all")
        #expect(!spec.summary.isEmpty)
        #expect(spec.schemaName == "graph")
        let codes = Set(spec.exitCodes.map(\.code))
        #expect(codes.contains(0))
        #expect(codes.contains(1))
        #expect(codes.contains(6))
        let limitFlag = try #require(
            spec.flags.first(where: { $0.long == "limit" }),
            "the spec must document the --limit flag")
        #expect(limitFlag.argument == "n",
                "--limit takes a value argument; got \(limitFlag.argument ?? "none")")
    }

    // MARK: - Schema binding (step 6)

    /// Binds the generated schema to the type, the way #0346's
    /// `LogCommandTests` does for its array-valued result: the payload is an
    /// array of objects with nested parent arrays, which the flat-only
    /// `PayloadShape` cannot express (#0194), so the schema carries the
    /// self-reference form naming `graph` — not a field list. A
    /// fully-populated `GraphRow` then pins its own wire keys to exactly its
    /// four `CodingKeys` (the case name IS the wire key, per #0130).
    @Test func schemaResultIsTheSelfReferenceAndTheTypeEncodesOnlyItsCodingKeys() throws {
        let graphSchemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardCommandsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit (package root)
            .appendingPathComponent("Schemas", isDirectory: true)
            .appendingPathComponent("graph.json")

        let data = try Data(contentsOf: graphSchemaURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(object["envelope"] as? [String: Any])
        let success = try #require(envelope["success"] as? [String: Any])
        let result = try #require(success["result"] as? [String: Any])
        #expect(result["schema"] as? String == "graph",
                "graph.json must carry the self-reference form until payload shapes can express arrays")
        #expect(result["fields"] == nil,
                "a field list appeared — bind it to the encoded keys like WhereAmIWireTests does")

        let row = GraphRow(
            oid: "0123456789abcdef0123456789abcdef01234567",
            parents: ["fedcba9876543210fedcba9876543210fedcba98"],
            lane: 1,
            parentLanes: [1, 2])

        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        let json = String(decoding: try encoder.encode(Envelope(result: EncodableResult([row]))),
                          as: UTF8.self)
        let encoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let rows = try #require(encoded["result"] as? [[String: Any]],
                                "an array result encodes as a JSON array")
        #expect(rows.count == 1, "the encoded array must carry exactly the one row")
        let encodedRow = try #require(rows.first, "the encoded array must be non-empty")
        #expect(
            Set(encodedRow.keys) == ["oid", "parents", "lane", "parentLanes"],
            "a fully-populated GraphRow encodes exactly its four wire keys; got \(encodedRow.keys.sorted())")
        #expect(encodedRow["oid"] as? String == "0123456789abcdef0123456789abcdef01234567")
        #expect(encodedRow["parents"] as? [String] == ["fedcba9876543210fedcba9876543210fedcba98"])
        #expect(encodedRow["lane"] as? Int == 1)
        #expect(encodedRow["parentLanes"] as? [Int] == [1, 2])
    }
}
