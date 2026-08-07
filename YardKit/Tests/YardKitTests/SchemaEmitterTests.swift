// SchemaEmitterTests.swift

import Foundation
import Testing
@testable import YardKit

@Suite("SchemaEmitter")
struct SchemaEmitterTests {

    private static let sampleSpec = CommandSpec(
        name: "status",
        summary: "Show the working tree status",
        flags: [
            FlagSpec(long: "short", short: "s", argument: nil, help: "Use the shorter output format"),
            FlagSpec(long: "branch", short: nil, argument: nil, help: "Show branch information"),
            FlagSpec(long: "path", short: nil, argument: "PATH", help: "Show only the specified path"),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "Success"),
            ExitCodeSpec(code: 1, meaning: "Unmerged files exist in the index"),
            ExitCodeSpec(code: 2, meaning: "Another operation is already in progress"),
        ],
        schemaName: "StatusResponse"
    )

    // MARK: - Valid JSON (decoded, not string-compared).

    @Test("rendered schema decodes as valid JSON")
    func testOutputDecodesWithJSONSerialization() {
        let output = try! renderSchema(for: Self.sampleSpec)

        #expect(!output.isEmpty, "Expected non-empty output")

        let data = Data(output.utf8)
        let decoded: Any = try! JSONSerialization.jsonObject(with: data, options: [])
        #expect(decoded is [String: Any], "Expected top-level JSON object")
    }

    // MARK: - Contains required top-level keys.

    @Test("schema includes schemaVersion, command name, and schemaName")
    func testRequiredTopLevelKeys() {
        let output = try! renderSchema(for: Self.sampleSpec)

        let decoded = try! JSONSerialization.jsonObject(
            with: Data(output.utf8), options: []) as! [String: Any]

        #expect(decoded["schemaVersion"] != nil, "Missing schemaVersion key")
        #expect(decoded["command"] as? String == "status", "Command name mismatch: \(decoded["command"] ?? "")")
        #expect(decoded["schemaName"] as? String == "StatusResponse", "Schema name mismatch: \(decoded["schemaName"] ?? "")")
    }

    // MARK: - Deterministic output (byte-identical).

    @Test("two calls with the same spec produce byte-identical output")
    func testByteIdenticalAcrossCalls() {
        let a = try! renderSchema(for: Self.sampleSpec)
        let b = try! renderSchema(for: Self.sampleSpec)

        #expect(a == b, "Expected byte-identical output from two calls with the same spec")
    }

    // MARK: - Key ordering is sorted.

    /// Extract top-level keys in order from pretty-printed JSON output,
    /// regardless of indentation width. Delegates to `extractKeysAtDepth` with target depth 1.
    private static func extractTopLevelKeys(from output: String) -> [String] {
        return Self.extractKeysAtDepth(from: output, depth: 1)
    }

    @Test("top-level keys appear in sorted order — using unsorted insertion to prove the emitter sorts them")
    func testTopLevelKeysAreSorted() {
        // Build a raw payload where keys are inserted in REVERSE order. If the emitter is truly
        // sorting, output must still have keys in lexicographic order regardless of insertion order.
        let reversePayload: [String: Any] = [
            "summary": Self.sampleSpec.summary,
            "schemaVersion": EnvelopeSchema.v1.rawValue,
            "flags": [],
            "exitCodes": [],
            "command": Self.sampleSpec.name,
            "schemaName": Self.sampleSpec.schemaName,
        ]

        let data = try! JSONSerialization.data(withJSONObject: reversePayload, options: [.prettyPrinted, .sortedKeys])
        let sortedOutput = String(data: data, encoding: .utf8)!

        // Extract top-level keys from this raw payload rendered with sortedKeys.
        let topLevelKeys = Self.extractTopLevelKeys(from: sortedOutput)

        // Guard non-empty before comparing — an extractor that silently returns [] makes every
        // following assertion pass unconditionally, which hides a broken extractor.
        #expect(!topLevelKeys.isEmpty, "Extractor returned empty array; assertions below would pass vacuously")

        // Verify they are in sorted order — this is what we'd expect from a sorting emitter.
        #expect(topLevelKeys == topLevelKeys.sorted(), "Top-level keys should be sorted lexicographically: \(topLevelKeys)")

        // Now check that the actual renderSchema output has the same set of top-level keys.
        let renderedOutput = try! renderSchema(for: Self.sampleSpec)
        let actualTopLevelKeys = Self.extractTopLevelKeys(from: renderedOutput)

        #expect(!actualTopLevelKeys.isEmpty, "Extractor returned empty array for renderSchema output; assertions below would pass vacuously")

        #expect(actualTopLevelKeys.count == topLevelKeys.count,
                "Key count mismatch: actual=\(actualTopLevelKeys) vs sorted-payload=\(topLevelKeys)")

        #expect(actualTopLevelKeys == topLevelKeys.sorted(),
                "Actual top-level keys not sorted: \(actualTopLevelKeys) vs expected \(topLevelKeys.sorted())")
    }

    /// Extract keys at a given brace depth, regardless of indentation width.
    /// Returns the keys in the order they appear in the output string. Useful for asserting
    /// on byte-offset ordering: if keys A, B, C appear at offsets oA < oB < oC, and the string
    /// is guaranteed sorted, then A < B < C in dictionary-key order.
    private static func extractKeysAtDepth(from output: String, depth targetDepth: Int) -> [String] {
        let pattern = "\"([A-Za-z]+)\"\\s*:"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var keys: [(key: String, offset: Int)] = []
        let range = NSRange(output.startIndex..., in: output)

        for match in regex.matches(in: output, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: output) else { continue }
            let keyStart = match.range.location

            // Count brace depth at the start of this match's line.
            var d = 0
            let offsetByLimit = min(keyStart, output.count)
            for ch in output.prefix(offsetByLimit) {
                switch ch {
                case "{": d += 1
                case "}": d -= 1
                default: break
                }
            }

            if d == targetDepth {
                keys.append((String(output[keyRange]), keyStart))
            }
        }

        return keys.map(\.key)
    }

    // MARK: - Key ordering is sorted (byte-offset approach).

    @Test("top-level keys increase in byte offset in lexicographic order")
    func testTopLevelKeysOrderByByteOffset() {
        let output = try! renderSchema(for: Self.sampleSpec)

        // Build a spec whose keys would NOT be in sorted order if we used an unsorted dictionary
        // with insertion-order keys. The keys below are deliberately out of alpha order:
        let outOfOrderPayload: [String: Any] = [
            "summary": Self.sampleSpec.summary,
            "schemaVersion": EnvelopeSchema.v1.rawValue,
            "flags": [],
            "exitCodes": [],
            "command": Self.sampleSpec.name,
            "schemaName": Self.sampleSpec.schemaName,
        ]

        // Use sortedKeys option — the only way this could emit unsorted output is if our
        // emitter bypassed .sortedKeys.
        let sortedData = try! JSONSerialization.data(withJSONObject: outOfOrderPayload, options: [.prettyPrinted, .sortedKeys])
        let sortedText = String(data: sortedData, encoding: .utf8)!

        // Extract keys at depth 1 (top-level) without assuming any indentation width.
        let referenceKeys = Self.extractKeysAtDepth(from: sortedText, depth: 1)
        let actualKeys = Self.extractKeysAtDepth(from: output, depth: 1)

        // Non-empty guard before any comparison.
        #expect(!referenceKeys.isEmpty, "Reference extractor returned empty array on sorted payload; assertions below pass vacuously")
        #expect(!actualKeys.isEmpty, "Actual extractor returned empty array on renderSchema output; assertions below pass vacuously")

        // The byte offset of key N+1 in the output must be greater than the byte offset of key N.
        // If keys were emitted in unsorted order, this check would still pass (offsets always increase
        // left-to-right) — so the real test here is that referenceKeys == actualKeys AND
        // referenceKeys is in sorted order. If the emitter were NOT sorting, referenceKeys would be
        // in insertion order and we'd catch that below.
        #expect(referenceKeys == referenceKeys.sorted(), "Reference emitter output keys not sorted: \(referenceKeys)")
        #expect(actualKeys == referenceKeys, "renderSchema keys differ from JSONSerialization.sortedKeys output: actual=\(actualKeys) expected=\(referenceKeys)")
    }

    // MARK: - Flag sorting.

    @Test("flags are rendered in sorted order by long name")
    func testFlagsAreSorted() {
        let output = try! renderSchema(for: Self.sampleSpec)

        let decoded = try! JSONSerialization.jsonObject(
            with: Data(output.utf8), options: []) as! [String: Any]

        let flags = decoded["flags"] as! [[String: Any]]
        let flagLongs = flags.compactMap { $0["long"] as? String }

        #expect(!flagLongs.isEmpty, "Expected at least one flag in rendered output")
        #expect(
            flagLongs == flagLongs.sorted(),
            "Flag long names not in sorted order: \(flagLongs)"
        )
    }

    // MARK: - Exit code sorting.

    @Test("exit codes are rendered in ascending numeric order")
    func testExitCodesAreSorted() {
        let output = try! renderSchema(for: Self.sampleSpec)

        let decoded = try! JSONSerialization.jsonObject(
            with: Data(output.utf8), options: []) as! [String: Any]

        let exitCodes = decoded["exitCodes"] as! [[String: Any]]
        let codes = exitCodes.compactMap { $0["code"] as? Int }

        #expect(codes.count >= 3, "Expected at least 3 exit codes")
        #expect(
            codes == codes.sorted(),
            "Exit code numbers not in sorted order: \(codes)"
        )
    }

    // MARK: - Pretty-printed output.

    @Test("output contains newlines and indentation indicating pretty printing")
    func testOutputIsPrettyPrinted() {
        let output = try! renderSchema(for: Self.sampleSpec)

        #expect(output.contains("\n"), "Expected newlines in pretty-printed output")

        // Count distinct lines to make sure pretty printing produces a multi-line document.
        let newlineCount = output.split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(newlineCount >= 5, "Expected at least 5 lines in pretty-printed output")
    }

    // MARK: - Nil short flag handled.

    @Test("flags without a short name emit null for the short field")
    func testNilShortFlagEmitsNull() {
        let spec = CommandSpec(
            name: "test",
            summary: "",
            flags: [
                FlagSpec(long: "verbose", short: nil, argument: nil, help: "Verbose"),
            ],
            exitCodes: [],
            schemaName: ""
        )

        let output = try! renderSchema(for: spec)

        #expect(output.contains("null"), "Expected null value for missing short flag")
    }

    // MARK: - Stable schema version.

    @Test("schemaVersion matches the current envelope version")
    func testSchemaVersionMatchesEnvelope() {
        let output = try! renderSchema(for: Self.sampleSpec)

        let decoded = try! JSONSerialization.jsonObject(
            with: Data(output.utf8), options: []) as! [String: Any]

        let version = decoded["schemaVersion"] as? Int
        #expect(version == EnvelopeSchema.v1.rawValue, "schemaVersion should match current envelope schema version")
    }

    // MARK: - Pure function behaviour.

    @Test("renderSchema is callable without awaiting (nonisolated)")
    func testRenderSchemaIsNonisolated() {
        let result = try! renderSchema(for: Self.sampleSpec)
        #expect(!result.isEmpty)
    }

    // MARK: - Empty spec (no flags, no exit codes).

    @Test("spec with no flags and no exit codes still emits schemaVersion, command, and schemaName")
    func testEmptySpec() {
        let spec = CommandSpec(
            name: "noop", summary: "", flags: [], exitCodes: [], schemaName: ""
        )

        let output = try! renderSchema(for: spec)
        #expect(!output.isEmpty, "Expected non-empty output for empty spec")

        let decoded = try! JSONSerialization.jsonObject(
            with: Data(output.utf8), options: []) as! [String: Any]

        #expect(decoded["command"] as? String == "noop")
        #expect(decoded["schemaVersion"] != nil)
    }

    // MARK: - Conjunction test. Flag with short name AND an argument together — the exact failure mode #0086 hit.

    @Test("flag with both a short name and an argument renders all three fields together")
    func testFlagWithShortAndArgument() {
        let spec = CommandSpec(
            name: "log", summary: "", flags: [
                FlagSpec(long: "path", short: "p", argument: "PATH", help: "Limit to path"),
            ], exitCodes: [], schemaName: "LogResponse"
        )

        let output = try! renderSchema(for: spec)

        // Decode and check the flag object has all three fields populated (not nil).
        let decoded = try! JSONSerialization.jsonObject(
            with: Data(output.utf8), options: []) as! [String: Any]

        let flags = decoded["flags"] as! [[String: Any]]

        #expect(flags.count == 1)
        let flag = flags[0]

        #expect(flag["long"] as? String == "path")
        #expect(flag["short"] as? String == "p")
        // When an argument is present, JSONSerialization represents it as a string value, not nil.
        #expect(flag["argument"] != nil, "Expected argument to be non-nil")
    }

    // MARK: - Conjunction test. Full spec with sorted flags, exit codes, and all top-level keys together.

    @Test("full spec renders flags and exit codes and all keys are sorted together")
    func testFullSpecSorted() {
        let spec = CommandSpec(
            name: "diff",
            summary: "Show changes between commits",
            flags: [
                FlagSpec(long: "stat", short: "s", argument: nil, help: "Show stats"),
                FlagSpec(long: "path", short: "p", argument: "PATH", help: "Limit to path"),
                FlagSpec(long: "cached", short: nil, argument: nil, help: "Only cached changes"),
            ],
            exitCodes: [
                ExitCodeSpec(code: 1, meaning: "Changes found"),
                ExitCodeSpec(code: 0, meaning: "No changes"),
            ],
            schemaName: "DiffResponse"
        )

        let output = try! renderSchema(for: spec)
        #expect(!output.isEmpty, "Expected non-empty output")

        // Verify it's valid JSON.
        let decoded = try! JSONSerialization.jsonObject(
            with: Data(output.utf8), options: []) as! [String: Any]

        // Verify keys are sorted at top level.
        let keys = Array(decoded.keys).sorted()
        #expect(keys == ["command", "exitCodes", "flags", "schemaName", "schemaVersion", "summary"])

        // Verify top-level fields.
        #expect(decoded["command"] as? String == "diff")
        #expect((decoded["schemaVersion"] as? Int) == EnvelopeSchema.v1.rawValue)
        #expect(decoded["schemaName"] as? String == "DiffResponse")

        // Verify flags sorted by long name.
        let flagLongs = ((decoded["flags"] as! [[String: Any]])).map { $0["long"] as? String }.compactMap { $0 }
        #expect(flagLongs == ["cached", "path", "stat"])

        // Verify exit codes sorted by code.
        let exitCodes = ((decoded["exitCodes"] as! [[String: Any]])).map { $0["code"] as? Int }.compactMap { $0 }
        #expect(exitCodes == [0, 1])

        // NOTE: This test checks the key *set* at top level (sorted on both sides), not the
        // ordering. The actual ordering of keys in the emitted JSON is tested by
        // testTopLevelKeysAreSorted and testTopLevelKeysOrderByByteOffset.
    }

    // MARK: - Null for missing optional fields.

    @Test("nil argument on a flag is encoded as null")
    func testNilArgumentEncodesAsNull() {
        let spec = CommandSpec(
            name: "test", summary: "", flags: [
                FlagSpec(long: "verbose", short: nil, argument: nil, help: "Be verbose"),
            ], exitCodes: [], schemaName: ""
        )

        let output = try! renderSchema(for: spec)
        #expect(output.contains("null"), "Expected null for nil argument")

        let decoded = try! JSONSerialization.jsonObject(
            with: Data(output.utf8), options: []) as! [String: Any]

        let flags = decoded["flags"] as! [[String: Any]]
        // When argument is nil, JSONSerialization writes "null" — in the decoded dict this is NSNull.
        #expect(flags[0]["argument"] is NSNull, "Expected argument field to be NSNull (JSON null)")
    }

    // MARK: - Spec with only a short name.

    @Test("flag with only a long name renders null for argument and short")
    func testShortOnlyFlag() {
        let spec = CommandSpec(
            name: "test", summary: "", flags: [
                FlagSpec(long: "v", short: nil, argument: nil, help: "Verbose"),
            ], exitCodes: [], schemaName: ""
        )

        let output = try! renderSchema(for: spec)

        #expect(!output.isEmpty, "Expected non-empty output")

        let decoded = try! JSONSerialization.jsonObject(
            with: Data(output.utf8), options: []) as! [String: Any]

        #expect(decoded["command"] as? String == "test")
        let flags = decoded["flags"] as! [[String: Any]]
        #expect(flags.count == 1)

        // nil short → NSNull in output.
        #expect(flags[0]["short"] is NSNull, "Expected null short for flag without a short name")
        #expect(flags[0]["long"] as? String == "v")
    }

    // MARK: - Summary present.

    @Test("summary appears at top level as the spec provides it")
    func testSummaryFieldPresent() {
        let output = try! renderSchema(for: Self.sampleSpec)

        let decoded = try! JSONSerialization.jsonObject(
            with: Data(output.utf8), options: []) as! [String: Any]

        #expect(decoded["summary"] as? String == "Show the working tree status")
    }

    // MARK: - Argument encoding uses NSNull pattern.

    @Test("nil argument encodes via .map { $0 as Any } ?? NSNull() pattern")
    func testNilArgumentUsesNSNullPattern() {
        let spec = CommandSpec(
            name: "test", summary: "", flags: [
                FlagSpec(long: "verbose", short: nil, argument: nil, help: "Be verbose"),
            ], exitCodes: [], schemaName: ""
        )

        let output = try! renderSchema(for: spec)

        // The argument value in the JSON must be null.
        let decoded = try! JSONSerialization.jsonObject(
            with: Data(output.utf8), options: []) as! [String: Any]

        let flags = decoded["flags"] as! [[String: Any]]
        #expect(flags[0]["argument"] is NSNull, "Expected argument to be NSNull for nil flag.argument")
    }

    @Test("non-nil argument encodes as string, not NSNull")
    func testNonNilArgumentIsString() {
        let spec = CommandSpec(
            name: "log", summary: "", flags: [
                FlagSpec(long: "path", short: nil, argument: "PATH", help: "Limit to path"),
            ], exitCodes: [], schemaName: ""
        )

        let output = try! renderSchema(for: spec)
        let decoded = try! JSONSerialization.jsonObject(
            with: Data(output.utf8), options: []) as! [String: Any]

        let flags = decoded["flags"] as! [[String: Any]]
        #expect(flags[0]["argument"] is String, "Expected argument to be a string when non-nil")
        #expect(flags[0]["argument"] as? String == "PATH", "Expected argument value to be PATH")
    }
}
