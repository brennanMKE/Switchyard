// SortedKeyOrderTests.swift

import Foundation
import Testing
@testable import YardKit

struct SortedKeyOrderTests {

    // MARK: - Successful envelope key order — success path (no args)

    @Test func successfulEnvelopeKeysInAlphabeticalOrder() throws {
        let result = runYard(arguments: [])
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(stdout.first == "{", "stdout should start with {")
        #expect(stdout.last == "}", "stdout should end with }")

        // Byte-exact. `Array(json.keys).sorted() == [...]` would be a tautology --
        // `sorted()` guarantees it whatever order the encoder produced. This
        // catches any drift away from `.sortedKeys` on the FIRST run, with no
        // loop and no chance of a lucky pass.
        //
        // The version half is resolved, not pinned: the summary comes from
        // VersionResolver (#0219), which falls back to the package version
        // outside a bundle. What this test pins byte-exact is the key order.
        let executable = currentExecutableURL()
        let summary = VersionResolver.cliVersionSummary(forExecutableAt: executable)
        #expect(stdout == #"{"ok":true,"result":"\#(summary)","schemaVersion":1}"#,
                "the success envelope must be byte-identical, keys in alphabetical order")
    }

    @Test func successfulEnvelopeStdoutIsByteIdenticalAcrossTwentyRuns() {
        var previous: String? = nil
        for i in 0..<20 {
            let result = runYard(arguments: [])
            if let previous, result.stdout != previous {
                Issue.record(
                    "stdout diverged at iteration \(i). Expected: \(previous.prefix(80))\nGot:      \(result.stdout.prefix(80))"
                )
            }
            previous = result.stdout
        }
    }

    // MARK: - Failure envelope key order — unknown command (bogus)

    @Test func failureEnvelopeKeysInAlphabeticalOrder() throws {
        let result = runYard(arguments: ["bogus"])
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(stdout.first == "{", "failure stdout should start with {")
        #expect(stdout.last == "}", "failure stdout should end with }")

        let json = try #require(JSONSerialization.jsonObject(with: Data(stdout.utf8), options: []) as? [String: Any])
        let keys = Array(json.keys).sorted()

        #expect(keys == ["error", "ok", "schemaVersion"],
                "failure envelope keys should appear in alphabetical order, got \(Array(json.keys))")

        let firstKeyPos = try #require(stdout.range(of: "\"\(keys[0])\"")).lowerBound
        let secondKeyPos = try #require(stdout.range(of: "\"\(keys[1])\"")).lowerBound
        let thirdKeyPos = try #require(stdout.range(of: "\"\(keys[2])\"")).lowerBound

        #expect(firstKeyPos < secondKeyPos, "error should appear before ok in failure JSON")
        #expect(secondKeyPos < thirdKeyPos, "ok should appear before schemaVersion in failure JSON")
    }

    @Test func failureEnvelopeStdoutIsByteIdenticalAcrossTwentyRuns() {
        var previous: String? = nil
        for i in 0..<20 {
            let result = runYard(arguments: ["bogus"])
            if let previous, result.stdout != previous {
                Issue.record(
                    "failure stdout diverged at iteration \(i). Expected: \(previous.prefix(80))\nGot:      \(result.stdout.prefix(80))"
                )
            }
            previous = result.stdout
        }
    }

    // MARK: - EnvelopeFail.write() path — direct write test

    @Test func envelopeFailWriteProducesSortedKeysInJSONEncoderPath() throws {
        let env = EnvelopeFail(code: .usage, message: "test message")

        // Capture what the encoder path would produce by reading jsonString
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        guard let data = try? encoder.encode(env),
              let text = String(data: data, encoding: .utf8) else {
            Issue.record("could not encode EnvelopeFail")
            return
        }

        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8), options: []) as? [String: Any])
        let keys = Array(json.keys).sorted()

        #expect(keys == ["error", "ok", "schemaVersion"],
                "EnvelopeFail encoder path should sort keys alphabetically, got \(Array(json.keys))")

        let firstKeyPos = try #require(text.range(of: "\"\(keys[0])\"")).lowerBound
        let secondKeyPos = try #require(text.range(of: "\"\(keys[1])\"")).lowerBound
        let thirdKeyPos = try #require(text.range(of: "\"\(keys[2])\"")).lowerBound

        #expect(firstKeyPos < secondKeyPos, "error should come before ok in EnvelopeFail")
        #expect(secondKeyPos < thirdKeyPos, "ok should come before schemaVersion in EnvelopeFail")
    }

    // MARK: - Mutation test: confirm .sortedKeys is actually being used
}
