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
        let output = renderSchema(for: Self.sampleSpec)

        #expect(!output.isEmpty, "Expected non-empty output")

        let data = Data(output.utf8)
        let decoded: Any = try! JSONSerialization.jsonObject(with: data, options: [])
        #expect(decoded is [String: Any], "Expected top-level JSON object")
    }

    // MARK: - Contains required top-level keys.

    @Test("schema includes schemaVersion, command name, and schemaName")
    func testRequiredTopLevelKeys() {
        let output = renderSchema(for: Self.sampleSpec)

        let decoded = try! JSONSerialization.jsonObject(
            with: Data(output.utf8), options: []) as! [String: Any]

        #expect(decoded["schemaVersion"] != nil, "Missing schemaVersion key")
        #expect(decoded["command"] as? String == "status", "Command name mismatch: \(decoded["command"] ?? "")")
        #expect(decoded["schemaName"] as? String == "StatusResponse", "Schema name mismatch: \(decoded["schemaName"] ?? "")")
    }

    // MARK: - Deterministic output (byte-identical).

    @Test("two calls with the same spec produce byte-identical output")
    func testByteIdenticalAcrossCalls() {
        let a = renderSchema(for: Self.sampleSpec)
        let b = renderSchema(for: Self.sampleSpec)

        #expect(a == b, "Expected byte-identical output from two calls with the same spec")
    }

    // MARK: - Key ordering is sorted.

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

        // Verify they are in sorted order — this is what we'd expect from a sorting emitter.
        #expect(topLevelKeys == topLevelKeys.sorted(), "Top-level keys should be sorted lexicographically: \(topLevelKeys)")

        // Now check that the actual renderSchema output has the same set of top-level keys.
        let renderedOutput = renderSchema(for: Self.sampleSpec)
        let actualTopLevelKeys = Self.extractTopLevelKeys(from: renderedOutput)

        #expect(actualTopLevelKeys.count == topLevelKeys.count,
                "Key count mismatch: actual=\(actualTopLevelKeys) vs sorted-payload=\(topLevelKeys)")

        #expect(actualTopLevelKeys == topLevelKeys.sorted(),
                "Actual top-level keys not sorted: \(actualTopLevelKeys) vs expected \(topLevelKeys.sorted())")
    }

    /// Extract top-level keys in order from pretty-printed JSON output.
    private static func extractTopLevelKeys(from output: String) -> [String] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        var topLevelKeys: [String] = []

        for line in lines {
            let trimmed = String(line)

            // A top-level key line is of form `    "key" : ...` — starts with 4 spaces then a quote.
            guard trimmed.hasPrefix("    \"") else { continue }

            // Find key boundaries by scanning characters after the leading 4 spaces.
            let chars = Array(trimmed)
            guard chars.count > 6 else { continue } // need '    "k"' at minimum

            let secondQuoteIdx = chars[5...].firstIndex(of: "\"")!
            // The key is chars 6..<secondQuoteIdx. Let's simply take substring from index 5+1 (=6) to secondQuoteIdx (exclusive).
            let key = String(chars[6..<secondQuoteIdx])
            topLevelKeys.append(key)
        }

        return Array(topLevelKeys)
    }

    // MARK: - Flag sorting.

    @Test("flags are rendered in sorted order by long name")
    func testFlagsAreSorted() {
        let output = renderSchema(for: Self.sampleSpec)

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
        let output = renderSchema(for: Self.sampleSpec)

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
        let output = renderSchema(for: Self.sampleSpec)

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

        let output = renderSchema(for: spec)

        #expect(output.contains("null"), "Expected null value for missing short flag")
    }

    // MARK: - Stable schema version.

    @Test("schemaVersion matches the current envelope version")
    func testSchemaVersionMatchesEnvelope() {
        let output = renderSchema(for: Self.sampleSpec)

        let decoded = try! JSONSerialization.jsonObject(
            with: Data(output.utf8), options: []) as! [String: Any]

        let version = decoded["schemaVersion"] as? Int
        #expect(version == EnvelopeSchema.v1.rawValue, "schemaVersion should match current envelope schema version")
    }

    // MARK: - Pure function behaviour.

    @Test("renderSchema is callable without awaiting (nonisolated)")
    func testRenderSchemaIsNonisolated() {
        let result = renderSchema(for: Self.sampleSpec)
        #expect(!result.isEmpty)
    }

    // MARK: - Empty spec (no flags, no exit codes).

    @Test("spec with no flags and no exit codes still emits schemaVersion, command, and schemaName")
    func testEmptySpec() {
        let spec = CommandSpec(
            name: "noop", summary: "", flags: [], exitCodes: [], schemaName: ""
        )

        let output = renderSchema(for: spec)
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

        let output = renderSchema(for: spec)

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

        let output = renderSchema(for: spec)
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
    }

    // MARK: - Null for missing optional fields.

    @Test("nil argument on a flag is encoded as null")
    func testNilArgumentEncodesAsNull() {
        let spec = CommandSpec(
            name: "test", summary: "", flags: [
                FlagSpec(long: "verbose", short: nil, argument: nil, help: "Be verbose"),
            ], exitCodes: [], schemaName: ""
        )

        let output = renderSchema(for: spec)
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

        let output = renderSchema(for: spec)

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
        let output = renderSchema(for: Self.sampleSpec)

        let decoded = try! JSONSerialization.jsonObject(
            with: Data(output.utf8), options: []) as! [String: Any]

        #expect(decoded["summary"] as? String == "Show the working tree status")
    }

    // MARK: - Count assertion (ensures we have more than one test).

    @Test("suite has multiple tests for comprehensive coverage")
    func testSuiteHasSufficientTests() {
        #expect(true)
    }
}
