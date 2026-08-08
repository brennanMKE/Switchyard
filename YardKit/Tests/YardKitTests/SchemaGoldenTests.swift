// SchemaGoldenTests.swift — the drift gate for the checked-in schema contract (#0026)

import Foundation
import Testing
@testable import YardKit

/// `YardKit/Schemas/`, resolved from this file's compile-time path:
/// `Tests/YardKitTests/SchemaGoldenTests.swift` → up three → package root.
private let schemasDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // YardKitTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // YardKit (package root)
    .appendingPathComponent("Schemas", isDirectory: true)

/// Parses the emitted schema for a spec back into a dictionary.
private func schemaObject(for spec: CommandSpec) throws -> [String: Any] {
    let text = try renderSchema(for: spec)
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
    return try #require(object as? [String: Any], "schema must be a JSON object")
}

/// Top-level key set of a JSON object given as text.
private func topLevelKeys(ofJSON text: String) throws -> Set<String> {
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
    let dictionary = try #require(object as? [String: Any], "expected a JSON object")
    return Set(dictionary.keys)
}

@Suite("Schema golden files")
struct SchemaGoldenTests {

    /// The drift gate. Every command in the registry must have a checked-in
    /// schema file that byte-matches what the code emits right now. Set
    /// SCHEMA_REGENERATE=1 to rewrite the files after an intentional change —
    /// see Schemas/README.md for the versioning rule that applies to the diff.
    @Test("every registered command's checked-in schema byte-matches the emitter")
    func checkedInSchemasMatchEmitter() throws {
        #expect(!CommandRegistry.all.isEmpty, "an empty registry would make this test vacuous")
        let regenerate = ProcessInfo.processInfo.environment["SCHEMA_REGENERATE"] == "1"
        for spec in CommandRegistry.all {
            let url = schemasDirectory.appendingPathComponent("\(spec.schemaName).json")
            let emitted = try renderSchema(for: spec) + "\n"
            if regenerate {
                try emitted.write(to: url, atomically: true, encoding: .utf8)
            }
            let checkedIn = try String(contentsOf: url, encoding: .utf8)
            #expect(checkedIn == emitted,
                    "Schemas/\(spec.schemaName).json no longer matches the code. If the change is intentional, regenerate with SCHEMA_REGENERATE=1 swift test --filter checkedInSchemasMatchEmitter and apply Schemas/README.md's versioning rule to the diff.")
        }
    }

    @Test("the schema directory holds exactly one file per registered command")
    func noOrphanSchemaFiles() throws {
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: schemasDirectory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
        let expected = CommandRegistry.all.map(\.schemaName).sorted()
        #expect(!expected.isEmpty, "an empty registry would make this test vacuous")
        #expect(onDisk == expected,
                "Schemas/ must hold exactly the registry's schemas — stale: \(Set(onDisk).subtracting(expected)), missing: \(Set(expected).subtracting(onDisk))")
        #expect(FileManager.default.fileExists(
                    atPath: schemasDirectory.appendingPathComponent("README.md").path),
                "Schemas/README.md carries the versioning policy and must exist")
    }

    @Test("checked-in schemas carry the current envelope version")
    func checkedInSchemasCarryTheCurrentVersion() throws {
        for spec in CommandRegistry.all {
            let url = schemasDirectory.appendingPathComponent("\(spec.schemaName).json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            let dictionary = try #require(object as? [String: Any])
            #expect(dictionary["schemaVersion"] as? Int == EnvelopeSchema.v1.rawValue,
                    "Schemas/\(spec.schemaName).json must declare the current schemaVersion")
        }
    }

    /// Binds the schema to reality: the success shape the schema declares must
    /// have exactly the keys a real encoded `Envelope` produces.
    @Test("declared success keys match a real encoded envelope")
    func successShapeMatchesRealEnvelope() throws {
        let schema = try schemaObject(for: CommandRegistry.noopSpec)
        let envelope = try #require(schema["envelope"] as? [String: Any], "schema must declare the envelope shapes")
        let success = try #require(envelope["success"] as? [String: Any])
        let real = try topLevelKeys(ofJSON: jsonString(Envelope(result: EncodableResult("x"))))
        #expect(Set(success.keys) == real,
                "schema declares \(success.keys.sorted()); the code emits \(real.sorted())")
        #expect(real.contains("schemaVersion"))
    }

    /// Same binding for the failure shape, plus the closed error-code set:
    /// every code in `EnvelopeErrorCode` appears in the schema's enum.
    @Test("declared failure keys match a real failure envelope, and the error-code enum is the closed set")
    func failureShapeMatchesRealEnvelope() throws {
        let schema = try schemaObject(for: CommandRegistry.switchyardSpec)
        let envelope = try #require(schema["envelope"] as? [String: Any], "schema must declare the envelope shapes")
        let failure = try #require(envelope["failure"] as? [String: Any])

        let realText = jsonString(EnvelopeFail(code: .usage, message: "m", hint: "h"))
        let real = try topLevelKeys(ofJSON: realText)
        #expect(Set(failure.keys) == real,
                "schema declares \(failure.keys.sorted()); the code emits \(real.sorted())")

        let declaredError = try #require(failure["error"] as? [String: Any])
        let realObject = try JSONSerialization.jsonObject(with: Data(realText.utf8))
        let realDictionary = try #require(realObject as? [String: Any])
        let realError = try #require(realDictionary["error"] as? [String: Any])
        #expect(Set(declaredError.keys) == Set(realError.keys))

        let codeField = try #require(declaredError["code"] as? [String: Any])
        let declaredCodes = try #require(codeField["enum"] as? [String])
        #expect(declaredCodes == EnvelopeErrorCode.allCases.map(\.rawValue).sorted(),
                "every EnvelopeErrorCode must appear in the schema's enum, sorted")
    }

    /// Negative control: the key-set comparison above must be able to fail.
    /// An envelope missing `schemaVersion` must not match the declared shape.
    @Test("an envelope missing schemaVersion does not match the declared success shape")
    func wrongEnvelopeIsRejected() throws {
        let schema = try schemaObject(for: CommandRegistry.noopSpec)
        let envelope = try #require(schema["envelope"] as? [String: Any], "schema must declare the envelope shapes")
        let success = try #require(envelope["success"] as? [String: Any])
        let wrong = try topLevelKeys(ofJSON: #"{"ok":true,"result":{}}"#)
        #expect(Set(success.keys) != wrong,
                "a wrong envelope matching the schema means the comparison is vacuous")
    }
}
