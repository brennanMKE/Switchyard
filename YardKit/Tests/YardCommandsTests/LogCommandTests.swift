// LogCommandTests.swift — the `log` arm in `runEngineCommand` (#0346)

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

@Suite("log engine arm")
struct LogCommandTests {

    // MARK: - The not-a-repository gate

    /// `WorktreeContext.resolve` throws on its own outside a repository, and
    /// the arm turns every failure into `EnvelopeFail(code: .repositoryError)`
    /// with exit 6. Kills mutation 1 (break the not-a-repository path so it
    /// returns success): a success envelope has `ok == true` and exit 0.
    @Test func nonRepositoryPathReturnsRepositoryErrorAtExitSix() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-log-non-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let result = try #require(
            runEngineCommand(arguments: ["log"], workingDirectory: empty.path))

        #expect(result.exitCode == .repositoryError)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "repository_error")
    }

    // MARK: - No option flags: the argument refusal

    /// `log` takes only range arguments (#0346): any `-`-prefixed token is a
    /// usage failure — `EnvelopeFail(code: .usage, …)` on stdout, the
    /// human-readable line on stderr, exit 1 — never silently ignored and
    /// never a default guess. The refusal happens before any repository
    /// access, so it holds in a directory that is not a repository at all
    /// *and* in a real fixture repository: the refusal is argument-shaped,
    /// not repository-shaped.
    @Test func unknownFlagsAreUsageFailuresAtExitOneEverywhere() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-log-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        for workingDirectory in [empty.path, repo.url.path] {
            for arguments in [["log", "--since", "yesterday"], ["log", "main..HEAD", "--max-count=1"]] {
                let result = try #require(
                    runEngineCommand(arguments: arguments, workingDirectory: workingDirectory),
                    "the arm must claim every log invocation, including \(arguments)")

                #expect(result.exitCode == .usage,
                        "arguments \(arguments) are a usage failure in \(workingDirectory)")

                let object = try jsonObject(result.stdout)
                #expect(object["ok"] as? Bool == false,
                        "arguments \(arguments) must not succeed in \(workingDirectory)")
                let error = try #require(object["error"] as? [String: Any])
                #expect(error["code"] as? String == "usage",
                        "arguments \(arguments) must report the usage error code; got \(error["code"] as? String ?? "nil")")
                #expect(result.stderr.contains("[error] usage:"),
                        "the human-readable usage line must reach stderr; got '\(result.stderr)'")
            }
        }
    }

    // MARK: - Fixture-determined values, the default listing

    /// `FixtureRepository.linear` commits a → b → c on `main`, so the default
    /// listing (no range arguments) is exactly those three commits, and
    /// `git log` emits them newest-first — which `CommitLog.run` preserves
    /// (CommitLog.swift: the parse order comment). Messages ride `%B`
    /// verbatim, so `git commit -m a`'s stored "a\n" is preserved (the
    /// trailing-newline fix in `parse`). Parents of the two non-root commits
    /// name the fixture's oids; the root commit has none.
    @Test func defaultListingIsExactlyTheThreeLinearCommitsNewestFirst() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["log"], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == true)
        #expect(object["schemaVersion"] as? Int == 1)

        let entries = try #require(object["result"] as? [[String: Any]],
                                   "result must be the CommitLogEntry array itself")
        #expect(entries.count == 3, "a→b→c is exactly three commits; got \(entries.count)")

        let oidC = try #require(repo.oids["c"], "the fixture must record c's oid")
        let oidB = try #require(repo.oids["b"], "the fixture must record b's oid")
        let oidA = try #require(repo.oids["a"], "the fixture must record a's oid")
        let oids = try #require(entries.map { $0["oid"] as? String },
                                "every entry must carry its oid")
        #expect(oids == [oidC, oidB, oidA],
                "the default listing is c, b, a — newest first; got \(oids)")

        let expectedParents: [[String]] = [[oidB], [oidA], []]
        let expectedMessages = ["c\n", "b\n", "a\n"]
        for (index, entry) in entries.enumerated() {
            let parents = try #require(entry["parents"] as? [String],
                                       "every entry must carry its parents")
            #expect(parents == expectedParents[index],
                    "the fixture chains a→b→c; got \(parents)")
            let message = try #require(entry["message"] as? String,
                                       "every entry must carry its message")
            #expect(message == expectedMessages[index],
                    "%B rides the wire verbatim including git's trailing newline; got '\(message)'")
            #expect(entry["author"] as? String == "Fixture",
                    "the fixture sets user.name Fixture; got \(entry["author"] as? String ?? "nil")")
            let signature = try #require(entry["signatureStatus"] as? String,
                                         "every entry must carry its signatureStatus")
            #expect(signature == "noSig",
                    "the fixture disables signing; got \(signature)")
            let trailers = try #require(entry["trailers"] as? [[String: Any]],
                                        "every entry must carry its trailers")
            #expect(trailers.isEmpty,
                    "fixture commits carry no trailers; got \(trailers)")
        }

        let root = try #require(entries.last, "the three-entry listing must be non-empty")
        #expect(root["oid"] as? String == oidA, "the root commit is a")
    }

    // MARK: - Fixture-determined values, one range argument

    /// One range argument narrows the log: `b..HEAD` is every commit
    /// reachable from HEAD but not from b — exactly c on the linear fixture.
    /// The reduced listing is what the fixture determines.
    @Test func rangeArgumentLimitsTheLogToCommitsAfterB() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let oidB = try #require(repo.oids["b"], "the fixture must record b's oid")

        let result = try #require(
            runEngineCommand(arguments: ["log", "\(oidB)..HEAD"],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == true)

        let entries = try #require(object["result"] as? [[String: Any]],
                                   "result must be the CommitLogEntry array itself")
        #expect(entries.count == 1, "b..HEAD leaves exactly c; got \(entries.count)")

        let first = try #require(entries.first, "the range listing must be non-empty")
        let oidC = try #require(repo.oids["c"], "the fixture must record c's oid")
        #expect(first["oid"] as? String == oidC, "the sole commit after b is c")
        #expect(first["parents"] as? [String] == [oidB],
                "c's parent is b; got \(first["parents"] as? [String] ?? [])")
    }

    // MARK: - The registry spec

    /// Kills mutation 3 (remove `logSpec` from `CommandRegistry.all`): the
    /// spec must be registered, with a non-empty summary, schemaName "log",
    /// and exit codes 0, 1 (usage), and 6.
    @Test func logSpecIsRegisteredWithRequiredMetadata() throws {
        let spec = try #require(CommandRegistry.lookup(name: "log"),
                                "log must be in CommandRegistry.all")
        #expect(!spec.summary.isEmpty)
        #expect(spec.schemaName == "log")
        let codes = Set(spec.exitCodes.map(\.code))
        #expect(codes.contains(0))
        #expect(codes.contains(1))
        #expect(codes.contains(6))
    }

    // MARK: - Schema binding (step 6)

    /// Binds the generated schema to the type, the way #0345's
    /// `HunksCommandTests` does for its array-valued result: the payload is
    /// an array of objects with nested trailer arrays, which the flat-only
    /// `PayloadShape` cannot express (#0194), so the schema carries the
    /// self-reference form naming `log` — not a field list. A
    /// fully-populated `CommitLogEntry` then pins its own wire keys to
    /// exactly its seven `CodingKeys` (the case name IS the wire key, per
    /// #0130), and a fully-populated `Trailer` pins its two the same way.
    @Test func schemaResultIsTheSelfReferenceAndTheTypesEncodeOnlyTheirCodingKeys() throws {
        let logSchemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardCommandsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit (package root)
            .appendingPathComponent("Schemas", isDirectory: true)
            .appendingPathComponent("log.json")

        let data = try Data(contentsOf: logSchemaURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(object["envelope"] as? [String: Any])
        let success = try #require(envelope["success"] as? [String: Any])
        let result = try #require(success["result"] as? [String: Any])
        #expect(result["schema"] as? String == "log",
                "log.json must carry the self-reference form until payload shapes can express arrays")
        #expect(result["fields"] == nil,
                "a field list appeared — bind it to the encoded keys like WhereAmIWireTests does")

        let trailer = try #require(Trailer.parse("Agent-Name: yard"),
                                   "a well-formed trailer line must parse")
        let entry = CommitLogEntry(
            oid: "0123456789abcdef0123456789abcdef01234567",
            parents: ["fedcba9876543210fedcba9876543210fedcba98"],
            author: "Fixture",
            refs: "HEAD -> main",
            signatureStatus: .good,
            message: "subject\n\nbody\n\nAgent-Name: yard\n",
            trailers: [trailer])

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
                == ["oid", "parents", "author", "refs", "signatureStatus", "message", "trailers"],
            "a fully-populated CommitLogEntry encodes exactly its seven wire keys; got \(encodedEntry.keys.sorted())")

        let encodedTrailers = try #require(encodedEntry["trailers"] as? [[String: Any]],
                                           "the encoded entry must carry its trailers array")
        let encodedTrailer = try #require(encodedTrailers.first,
                                          "the encoded trailers array must be non-empty")
        #expect(Set(encodedTrailer.keys) == ["key", "value"],
                "a fully-populated Trailer encodes exactly its two wire keys; got \(encodedTrailer.keys.sorted())")
        #expect(encodedTrailer["key"] as? String == "Agent-Name")
        #expect(encodedTrailer["value"] as? String == "yard")
        #expect(encodedEntry["signatureStatus"] as? String == "good",
                "SignatureStatus encodes as its declared case-name string; got \(encodedEntry["signatureStatus"] as? String ?? "nil")")
    }
}
