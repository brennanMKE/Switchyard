// SchemaPayloadBinding.swift — the reusable half of the schema binding that
// pins a payload's `optional` flags to what the result type actually encodes
// (#0243). #0194 bound the field NAMES; this file binds the ABSENCE half, and
// is written so the next command's wire test gets the check for free: build a
// fully-populated and a minimally-populated value, pass both key sets, call
// `assertSchemaOptionalFlagsMatchEncodedAbsence`. The convention it pins is
// the one in CommandSpec's doc comment: a field marked `optional` is ABSENT
// from the wire when there is nothing to report — never `null` — and a field
// NOT marked `optional` is always present.

import Foundation
import Testing

/// One payload field exactly as a checked-in schema declares it: the wire key
/// and whether the schema claims the key may be absent.
struct SchemaPayloadField: Equatable {
    let name: String
    let optional: Bool
}

/// Reads `envelope.success.result.fields[]` off a checked-in schema file.
/// Every extraction failure stops the calling test loudly — a schema that
/// carries the historical self-reference instead of a real field list, or a
/// field without a string `name` and a boolean `optional`, must never be
/// read as "no fields", which would make the binding vacuous.
func checkedInSchemaPayloadFields(schemaURL: URL) throws -> [SchemaPayloadField] {
    let data = try Data(contentsOf: schemaURL)
    let object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let envelope = try #require(object["envelope"] as? [String: Any])
    let success = try #require(envelope["success"] as? [String: Any])
    let result = try #require(success["result"] as? [String: Any])
    let rawFields = try #require(
        result["fields"] as? [[String: Any]],
        "\(schemaURL.lastPathComponent)'s result must declare a real field list, not the self-reference")
    var fields: [SchemaPayloadField] = []
    for field in rawFields {
        let name = try #require(field["name"] as? String,
                                "every declared field must have a string name")
        let optional = try #require(field["optional"] as? Bool,
                                    "every declared field must have a boolean optional flag")
        fields.append(SchemaPayloadField(name: name, optional: optional))
    }
    #expect(!fields.isEmpty, "\(schemaURL.lastPathComponent) must declare at least one payload field")
    return fields
}

/// The two ways a schema's `optional` flags can lie about the type, each as
/// the set of field names that disagree. Both empty means bound.
struct SchemaOptionalMismatch: Equatable {
    /// The schema marks these fields `optional`, but a minimally-populated
    /// value (every optional nil) still encodes them — they are never absent,
    /// so an agent reading the schema is told a gap exists where none does.
    let schemaMarksOptionalButTypeAlwaysEncodes: Set<String>
    /// The type omits these keys from a minimally-populated value, but the
    /// schema marks them required — an agent is told they are always present,
    /// and then finds them missing at parse time (#0243's failing agent).
    let typeOmitsButSchemaMarksRequired: Set<String>
}

/// The absence-half comparison, kept pure so the matcher itself is testable:
/// a field marked `optional` must be exactly a key that is present when the
/// value is fully populated and ABSENT when it is minimally populated.
/// Fields are matched by wire key; a schema name the type never encodes
/// cannot appear in either mismatch set, which is #0194's test's job to catch.
func schemaOptionalMismatch(
    schemaFields: [SchemaPayloadField],
    encodedFullKeys: Set<String>,
    encodedMinimalKeys: Set<String>
) -> SchemaOptionalMismatch {
    // "Absent" is measured against what the type ACTUALLY encodes, not
    // against the schema's own name list, so a bogus schema name marked
    // `optional` cannot silently satisfy the comparison.
    let absentKeys = encodedFullKeys.subtracting(encodedMinimalKeys)
    let schemaOptional = Set(schemaFields.filter(\.optional).map(\.name))
    return SchemaOptionalMismatch(
        schemaMarksOptionalButTypeAlwaysEncodes: schemaOptional.subtracting(absentKeys),
        typeOmitsButSchemaMarksRequired: absentKeys.subtracting(schemaOptional))
}

/// The one-call binding for a command's wire test (#0243): reads the
/// checked-in schema file and asserts its `optional` flags are exactly the
/// keys that drop out of the wire between the fully-populated and the
/// minimally-populated encoding. The two directional mismatches are asserted
/// separately so a failure names the lying fields and the direction they lie
/// in.
func assertSchemaOptionalFlagsMatchEncodedAbsence(
    schemaURL: URL,
    encodedFullKeys: Set<String>,
    encodedMinimalKeys: Set<String>
) throws {
    let fields = try checkedInSchemaPayloadFields(schemaURL: schemaURL)
    let mismatch = schemaOptionalMismatch(
        schemaFields: fields,
        encodedFullKeys: encodedFullKeys,
        encodedMinimalKeys: encodedMinimalKeys)
    #expect(mismatch.schemaMarksOptionalButTypeAlwaysEncodes.isEmpty,
            "\(schemaURL.lastPathComponent) marks \(mismatch.schemaMarksOptionalButTypeAlwaysEncodes.sorted()) optional, but a minimally-populated value always encodes them")
    #expect(mismatch.typeOmitsButSchemaMarksRequired.isEmpty,
            "\(schemaURL.lastPathComponent) marks \(mismatch.typeOmitsButSchemaMarksRequired.sorted()) required, but a minimally-populated value omits them")
}

/// Top-level key set of a JSON object given as text. Shared across the wire
/// tests that bind a checked-in schema to a type's encoded keys.
func topLevelKeys(ofJSON text: String) throws -> Set<String> {
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
    let dictionary = try #require(object as? [String: Any], "expected a JSON object")
    return Set(dictionary.keys)
}

/// The matcher's own test: it must be able to fail in both directions, with
/// the exact lying fields named, and stay quiet when the flags are true.
/// Without this control a broken comparison would make every command's
/// binding test vacuously green (#0243's mutation evidence, compressed).
@Suite("Schema optional-flag binding matcher")
struct SchemaOptionalMatcherTests {

    @Test func matcherQuietWhenFlagsAreTrueAndLoudInBothDriftDirections() {
        let fields = [
            SchemaPayloadField(name: "a", optional: true),
            SchemaPayloadField(name: "b", optional: false),
        ]
        // Truth: `a` drops out of a minimal value, `b` never does.
        let bound = schemaOptionalMismatch(
            schemaFields: fields, encodedFullKeys: ["a", "b"], encodedMinimalKeys: ["b"])
        #expect(bound.schemaMarksOptionalButTypeAlwaysEncodes.isEmpty)
        #expect(bound.typeOmitsButSchemaMarksRequired.isEmpty)

        // Drift 1 (mutation A's shape): `a` demoted to required while the
        // type still omits it from a minimal value.
        let demoted = [
            SchemaPayloadField(name: "a", optional: false),
            SchemaPayloadField(name: "b", optional: false),
        ]
        let lyingRequired = schemaOptionalMismatch(
            schemaFields: demoted, encodedFullKeys: ["a", "b"], encodedMinimalKeys: ["b"])
        #expect(lyingRequired.typeOmitsButSchemaMarksRequired == ["a"])
        #expect(lyingRequired.schemaMarksOptionalButTypeAlwaysEncodes.isEmpty)

        // Drift 2 (mutation B's shape): `b` promoted to optional while the
        // type still encodes it in a minimal value.
        let promoted = [
            SchemaPayloadField(name: "a", optional: true),
            SchemaPayloadField(name: "b", optional: true),
        ]
        let lyingOptional = schemaOptionalMismatch(
            schemaFields: promoted, encodedFullKeys: ["a", "b"], encodedMinimalKeys: ["b"])
        #expect(lyingOptional.schemaMarksOptionalButTypeAlwaysEncodes == ["b"])
        #expect(lyingOptional.typeOmitsButSchemaMarksRequired.isEmpty)
    }
}
