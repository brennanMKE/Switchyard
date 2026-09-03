// WhereAmIWireTests.swift — WhereAmI encodes to the schemaVersion 1 envelope (#0129)

import Foundation
import Testing
import YardGit
import YardKit

/// Encodes a value the way the CLI writes envelopes: `JSONEncoder` with
/// `.sortedKeys` and nothing else — the same configuration as
/// `EnvelopeFail.write()` and YardKit's internal `jsonString`. Sorted keys
/// make the bytes deterministic, so tests can assert literal JSON.
func wireJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting.insert(.sortedKeys)
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

@Suite("WhereAmI wire shape")
struct WhereAmIWireTests {

    /// Every field populated, asserted against the literal bytes. A
    /// round-trip cannot catch a key both sides share wrongly; the literal is
    /// the contract.
    @Test func fullValueEncodesToTheLiteralWireShape() throws {
        let value = WhereAmI(
            branch: "main", upstream: "origin/main", ahead: 2, behind: 1,
            isMidRebase: false, isMidMerge: true, isMidCherryPick: false,
            stashCount: 3, untrackedCount: 4, unstagedCount: 5, stagedCount: 6,
            hasConflicts: true, conflictCount: 7,
            headOID: "a1b2c3d",
            rawHead: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0")
        #expect(try wireJSON(value) == #"{"ahead":2,"behind":1,"branch":"main","conflictCount":7,"hasConflicts":true,"headOID":"a1b2c3d","isMidCherryPick":false,"isMidMerge":true,"isMidRebase":false,"rawHead":"a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0","stagedCount":6,"stashCount":3,"unstagedCount":5,"untrackedCount":4,"upstream":"origin\/main"}"#)
    }

    /// A detached HEAD with no upstream: every nil optional is OMITTED from
    /// the wire, not encoded as null — the same rule the envelope itself uses
    /// for `result` and `error.hint`.
    @Test func nilOptionalsAreOmittedFromTheWire() throws {
        let value = WhereAmI(
            branch: nil, upstream: nil, ahead: nil, behind: nil,
            isMidRebase: false, isMidMerge: false, isMidCherryPick: false,
            stashCount: 0, untrackedCount: 0, unstagedCount: 0, stagedCount: 0,
            hasConflicts: false, conflictCount: 0,
            headOID: "a1b2c3d",
            rawHead: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0")
        let json = try wireJSON(value)
        #expect(json == #"{"conflictCount":0,"hasConflicts":false,"headOID":"a1b2c3d","isMidCherryPick":false,"isMidMerge":false,"isMidRebase":false,"rawHead":"a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0","stagedCount":0,"stashCount":0,"unstagedCount":0,"untrackedCount":0}"#)
        #expect(!json.contains("\"branch\""))
        #expect(!json.contains("null"))
    }

    /// The M1 exit-criterion sentence, literally: the engine result type
    /// encodes to a `schemaVersion: 1` envelope. Wrapped in the real
    /// `Envelope` through `EncodableResult` — the compile itself proves the
    /// `Encodable & Sendable` bound, and the literal pins the whole response.
    @Test func envelopeWrapsWhereAmIWithTheV1Keys() throws {
        let value = WhereAmI(
            branch: "main", upstream: nil, ahead: nil, behind: nil,
            isMidRebase: false, isMidMerge: false, isMidCherryPick: false,
            stashCount: 0, untrackedCount: 0, unstagedCount: 1, stagedCount: 0,
            hasConflicts: false, conflictCount: 0,
            headOID: "cafc5cd",
            rawHead: "cafc5cde84e5e8b8ddd67d821b0b803b60f43216")
        let json = try wireJSON(Envelope(result: EncodableResult(value)))
        #expect(json == #"{"ok":true,"result":{"branch":"main","conflictCount":0,"hasConflicts":false,"headOID":"cafc5cd","isMidCherryPick":false,"isMidMerge":false,"isMidRebase":false,"rawHead":"cafc5cde84e5e8b8ddd67d821b0b803b60f43216","stagedCount":0,"stashCount":0,"unstagedCount":1,"untrackedCount":0},"schemaVersion":1}"#)

        // Structural read-back of the envelope frame, so a failure here
        // distinguishes "envelope broke" from "payload byte drift".
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["ok"] as? Bool == true)
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["branch"] as? String == "main")
    }

    // MARK: - Binding the schema to the type (#0194)

    /// `YardKit/Schemas/whereami.json`, resolved from this file's compile-time
    /// path: `Tests/YardWireTests/WhereAmIWireTests.swift` → up three → package
    /// root → `Schemas/whereami.json`.
    private static let whereamiSchemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // YardWireTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // YardKit (package root)
        .appendingPathComponent("Schemas", isDirectory: true)
        .appendingPathComponent("whereami.json")

    /// Extracts the payload field names the generated schema declares, from
    /// `envelope.success.result.fields[].name`.
    private static func schemaPayloadFieldNames() throws -> Set<String> {
        let data = try Data(contentsOf: whereamiSchemaURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(object["envelope"] as? [String: Any])
        let success = try #require(envelope["success"] as? [String: Any])
        let result = try #require(success["result"] as? [String: Any])
        let fields = try #require(result["fields"] as? [[String: Any]],
                                   "whereami.json's result must declare a real field list, not the self-reference")
        let names = fields.compactMap { $0["name"] as? String }
        #expect(names.count == fields.count, "every declared field must have a string name")
        return Set(names)
    }

    /// The binding that makes the schema true rather than decorative
    /// (#0194): the field names `whereami.json` declares must be **exactly**
    /// the keys a fully-populated `WhereAmI` actually encodes — no more, no
    /// fewer. A hand-written schema and a hand-written wire literal can each
    /// drift from the type independently; this test reads the generated file
    /// off disk, so it catches drift in either direction.
    ///
    /// Mutation A — add a field to `CommandRegistry.whereamiSpec`'s payload
    /// that `WhereAmI` does not encode (e.g. a fictitious `"bogus"` field),
    /// regenerate the schema, and this test reddens: the schema's field-name
    /// set gains `"bogus"`, which the encoded JSON never has.
    ///
    /// Mutation B — remove one real field from `whereamiSpec`'s payload (e.g.
    /// drop `"rawHead"`), regenerate the schema, and this test reddens the
    /// other way: the encoded JSON still has `"rawHead"`, which the schema's
    /// field-name set no longer does.
    @Test func schemaFieldNamesMatchTheEncodedKeysExactly() throws {
        let value = WhereAmI(
            branch: "main", upstream: "origin/main", ahead: 2, behind: 1,
            isMidRebase: false, isMidMerge: true, isMidCherryPick: false,
            stashCount: 3, untrackedCount: 4, unstagedCount: 5, stagedCount: 6,
            hasConflicts: true, conflictCount: 7,
            headOID: "a1b2c3d",
            rawHead: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0")
        let encodedKeys = try topLevelKeys(ofJSON: wireJSON(value))
        #expect(!encodedKeys.isEmpty, "a fully-populated value must encode at least one key")

        let schemaFieldNames = try Self.schemaPayloadFieldNames()
        #expect(!schemaFieldNames.isEmpty, "whereami.json must declare at least one payload field")

        #expect(schemaFieldNames == encodedKeys,
                "schema declares \(schemaFieldNames.sorted()); the type encodes \(encodedKeys.sorted())")
    }

    /// The second half of the binding (#0243), beside #0194's name half: a
    /// minimally-populated `WhereAmI` — every optional nil — must omit
    /// exactly the keys `whereami.json` marks `optional`, no more, no fewer.
    /// #0194's test says nothing about absence, and #0243 measured that
    /// flipping an `optional` flag and regenerating the golden file leaves
    /// every gate green with a schema that lies. The convention at stake:
    /// absent means absent, not `null` — an agent told a field is required
    /// which is then simply missing fails in a way the schema was supposed
    /// to prevent. Goes through the shared helper, so the next command's
    /// wire test is the same one call.
    ///
    /// Mutation A — flip `branch`'s `optional: true` to `false` in
    /// `CommandRegistry.whereamiSpec`, regenerate the golden file
    /// (`SCHEMA_REGENERATE=1 swift test --filter checkedInSchemasMatchEmitter`):
    /// the golden gate is green again, and THIS test reddens — `branch` is
    /// absent from the minimal value but the schema now calls it required.
    ///
    /// Mutation B — mark a required field optional instead (e.g. `rawHead`),
    /// regenerate, and this test reddens the other way: `rawHead` is still
    /// encoded by the minimal value but the schema now says it may be absent.
    @Test func schemaOptionalFieldsMatchTheKeysAMinimalValueOmits() throws {
        let fullyPopulated = WhereAmI(
            branch: "main", upstream: "origin/main", ahead: 2, behind: 1,
            isMidRebase: false, isMidMerge: true, isMidCherryPick: false,
            stashCount: 3, untrackedCount: 4, unstagedCount: 5, stagedCount: 6,
            hasConflicts: true, conflictCount: 7,
            headOID: "a1b2c3d",
            rawHead: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0")
        let minimallyPopulated = WhereAmI(
            branch: nil, upstream: nil, ahead: nil, behind: nil,
            isMidRebase: false, isMidMerge: false, isMidCherryPick: false,
            stashCount: 0, untrackedCount: 0, unstagedCount: 0, stagedCount: 0,
            hasConflicts: false, conflictCount: 0,
            headOID: "a1b2c3d",
            rawHead: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0")
        let fullKeys = try topLevelKeys(ofJSON: wireJSON(fullyPopulated))
        #expect(!fullKeys.isEmpty, "a fully-populated value must encode at least one key")
        let minimalKeys = try topLevelKeys(ofJSON: wireJSON(minimallyPopulated))
        #expect(!minimalKeys.isEmpty, "a minimally-populated value must encode at least one key")
        #expect(minimalKeys.isSubset(of: fullKeys),
                "the minimal value's keys must be a subset of the full value's keys")

        try assertSchemaOptionalFlagsMatchEncodedAbsence(
            schemaURL: Self.whereamiSchemaURL,
            encodedFullKeys: fullKeys,
            encodedMinimalKeys: minimalKeys)
    }
}

    // `topLevelKeys(ofJSON:)` moved to `SchemaPayloadBinding.swift` (#0243)
    // as a shared internal helper, so the next command's wire test binds both
    // halves of the schema contract without re-deriving it.
