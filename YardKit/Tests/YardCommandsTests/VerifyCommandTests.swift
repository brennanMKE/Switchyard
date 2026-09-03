// VerifyCommandTests.swift — the `verify` arm in `runEngineCommand` (#0348)

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

@Suite("verify engine arm")
struct VerifyCommandTests {

    // MARK: - The not-a-repository gate

    /// `WorktreeContext.resolve` throws on its own outside a repository, and
    /// the arm turns every failure into `EnvelopeFail(code: .repositoryError)`
    /// with exit 6. Kills mutation 1 (break the not-a-repository path so it
    /// returns success): a success envelope has `ok == true` and exit 0.
    @Test func nonRepositoryPathReturnsRepositoryErrorAtExitSix() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-verify-non-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let result = try #require(
            runEngineCommand(arguments: ["verify", "HEAD"], workingDirectory: empty.path))

        #expect(result.exitCode == .repositoryError)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "repository_error")
    }

    // MARK: - The strict argument grammar

    /// `verify` accepts only one non-flag revision token (#0348): a missing
    /// revision, two or more tokens, or any `-`-prefixed token is a usage
    /// failure — `EnvelopeFail(code: .usage, …)` on stdout, the
    /// human-readable line on stderr, exit 1 — never silently ignored and
    /// never a default guess. The refusal happens before any repository
    /// access, so it holds in a directory that is not a repository at all
    /// *and* in a real fixture repository: the refusal is argument-shaped,
    /// not repository-shaped.
    @Test func badArgumentTailsAreUsageFailuresAtExitOneEverywhere() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-verify-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let refusedTails: [[String]] = [
            ["verify"],                    // missing revision
            ["verify", "HEAD", "main"],    // two revisions
            ["verify", "--verbose"],       // unknown flag
            ["verify", "-v", "HEAD"],      // flag before a revision
        ]
        for workingDirectory in [empty.path, repo.url.path] {
            for arguments in refusedTails {
                let result = try #require(
                    runEngineCommand(arguments: arguments, workingDirectory: workingDirectory),
                    "the arm must claim every verify invocation, including \(arguments)")

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

    // MARK: - Fixture-determined verdict, the linear fixture

    /// `FixtureRepository.linear` commits a → b → c unsigned (the fixture
    /// disables signing), so `HEAD` is c and `SignatureVerification.run`
    /// reports exactly what `SignatureVerificationTests` pins for an unsigned
    /// commit: state `.noSignature` (wire code "noSignature"), format
    /// `.none` (wire string "none"), and `signer`/`key` absent from the wire
    /// — they are nil and omitted, not null (#0129 Decision 4). The command
    /// succeeds regardless: the exit code reports that it ran; the payload
    /// carries the verdict.
    @Test func unsignedHeadOnLinearFixtureCarriesTheFixtureDeterminedVerdict() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["verify", "HEAD"], workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == true)
        #expect(object["schemaVersion"] as? Int == 1)

        let verification = try #require(object["result"] as? [String: Any],
                                        "result must be the SignatureVerification object itself")
        // The wire keys are exactly state, format, signer, key — the type has
        // no oid field, so there is nothing to compare against the fixture's
        // recorded oids (the unsigned test in `SignatureVerificationTests`
        // asserts noSignature/none/nil/nil and likewise never touches oids).
        let state = try #require(verification["state"] as? [String: Any],
                                 "state must encode as its {code: …} object")
        #expect(state["code"] as? String == "noSignature")
        #expect(verification["format"] as? String == "none")
        #expect(verification["signer"] == nil,
                "an unsigned commit has no signer; the key must be absent, not null")
        #expect(verification["key"] == nil,
                "an unsigned commit has no key; the key must be absent, not null")
    }

    // MARK: - A revision git cannot resolve

    /// The engine-level `unknownRevisionThrows` test pins that
    /// `SignatureVerification.run` throws `GitProcess.Failure` for a revision
    /// git cannot resolve, so the arm's catch maps it to
    /// `EnvelopeFail(code: .repositoryError)` at exit 6 — there is no
    /// payload status for an unreadable revision.
    @Test func nonexistentRevisionIsARepositoryErrorAtExitSix() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["verify", "does-not-exist"],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .repositoryError)

        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "repository_error")
    }

    // MARK: - The registry spec

    /// Kills mutation 3 (remove `verifySpec` from `CommandRegistry.all`): the
    /// spec must be registered, with a non-empty summary, schemaName
    /// "verify", and exit codes 0 (completed, whatever the verdict), 1
    /// (usage), and 6 (repository error).
    @Test func verifySpecIsRegisteredWithRequiredMetadata() throws {
        let spec = try #require(CommandRegistry.lookup(name: "verify"),
                                "verify must be in CommandRegistry.all")
        #expect(!spec.summary.isEmpty)
        #expect(spec.schemaName == "verify")
        let codes = Set(spec.exitCodes.map(\.code))
        #expect(codes.contains(0))
        #expect(codes.contains(1))
        #expect(codes.contains(6))
    }

    // MARK: - Schema binding (step 6)

    /// Binds the generated schema to the type, the way #0347's
    /// `GraphCommandTests` does: the payload is a single object whose `state`
    /// is nested (its `code` object, plus `reason` on `cannotCheck`), which
    /// the flat-only `PayloadShape` cannot express (#0194), so the schema
    /// carries the self-reference form naming `verify` — not a field list. A
    /// fully-populated `SignatureVerification` then pins its own wire keys to
    /// exactly its four `CodingKeys`, and a minimal one (both optionals nil)
    /// pins that nil `signer`/`key` are omitted, not null (#0129 Decision 4),
    /// the way #0228's `WorktreeWhereCommandTests` did.
    @Test func schemaResultIsTheSelfReferenceAndTheTypeEncodesOnlyItsCodingKeys() throws {
        let verifySchemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardCommandsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit (package root)
            .appendingPathComponent("Schemas", isDirectory: true)
            .appendingPathComponent("verify.json")

        let data = try Data(contentsOf: verifySchemaURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(object["envelope"] as? [String: Any])
        let success = try #require(envelope["success"] as? [String: Any])
        let result = try #require(success["result"] as? [String: Any])
        #expect(result["schema"] as? String == "verify",
                "verify.json must carry the self-reference form until payload shapes can express nesting")
        #expect(result["fields"] == nil,
                "a field list appeared — bind it to the encoded keys like WhereAmIWireTests does")

        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)

        let populated = SignatureVerification(
            state: .good,
            format: .openpgp,
            signer: "Fixture <f@example.invalid>",
            key: "DEADBEEFCAFE1234")
        let populatedJSON = String(
            decoding: try encoder.encode(Envelope(result: EncodableResult(populated))),
            as: UTF8.self)
        let populatedObject = try #require(
            try JSONSerialization.jsonObject(with: Data(populatedJSON.utf8)) as? [String: Any])
        let populatedResult = try #require(populatedObject["result"] as? [String: Any],
                                           "a single-object result encodes as a JSON object")
        #expect(
            Set(populatedResult.keys) == ["state", "format", "signer", "key"],
            "a fully-populated SignatureVerification encodes exactly its four wire keys; got \(populatedResult.keys.sorted())")
        let populatedState = try #require(populatedResult["state"] as? [String: Any],
                                          "state encodes as its {code: …} object")
        #expect(populatedState as NSDictionary == ["code": "good"],
                "state's wire code is the vocabulary literal, not the case name of a Swift-only spelling; got \(populatedState)")
        #expect(populatedResult["format"] as? String == "openpgp")
        #expect(populatedResult["signer"] as? String == "Fixture <f@example.invalid>")
        #expect(populatedResult["key"] as? String == "DEADBEEFCAFE1234")

        let minimal = SignatureVerification(
            state: .noSignature,
            format: .none,
            signer: nil,
            key: nil)
        let minimalJSON = String(
            decoding: try encoder.encode(Envelope(result: EncodableResult(minimal))),
            as: UTF8.self)
        let minimalObject = try #require(
            try JSONSerialization.jsonObject(with: Data(minimalJSON.utf8)) as? [String: Any])
        let minimalResult = try #require(minimalObject["result"] as? [String: Any],
                                         "a single-object result encodes as a JSON object")
        #expect(
            Set(minimalResult.keys) == ["state", "format"],
            "nil signer and key are omitted from the wire, not null (#0129 Decision 4); got \(minimalResult.keys.sorted())")
        let minimalState = try #require(minimalResult["state"] as? [String: Any],
                                        "state must encode as its {code: …} object")
        #expect(minimalState["code"] as? String == "noSignature")
    }
}
