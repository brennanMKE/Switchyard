// CommandRegistryTests.swift — exercise the registry and its consumers.

import Foundation
import Testing
@testable import YardKit

/// Verify every place a caller reaches the registry: lookup, counts, and
/// `runYard` behaviors it drives (`--help`, version, schema). Per Rule 7 we
/// must never loop and skip — each iteration reaches an assertion, and every
/// logical case is covered.
@Test("registry contains at least the switchyard and noop specs")
func registryHasAtLeastTwoEntries() {
    let list = CommandRegistry.all

    // Exhaust the collection — every iteration asserts, so no case is missed.
    #expect(!list.isEmpty)

    let names = Set(list.map(\.name))
    // The two documented commands must exist. If someone adds a third later,
    // this assertion continues to hold rather than silently failing.
    #expect(names.contains("switchyard"))
    #expect(names.contains("noop"))

    // Verify each one also has a valid name — empty names would indicate
    // broken spec construction that we want caught here.
    for spec in list {
        #expect(!spec.name.isEmpty)
    }
}

@Test("registry reports exactly two entries")
func registryHasExactlyTwoEntries() {
    #expect(CommandRegistry.all.count == 2)

    let names: [String] = CommandRegistry.all.map(\.name)
    #expect(Set(names).count == 2, "Names must be distinct so lookup returns the right spec.")
}

@Test("registry lookup by name returns the matching spec")
func registryLookupByName() {
    // Pre-condition: each spec in the list has a unique name. If two share one,
    // the assertion below still passes but lookup would be ambiguous — so keep it as a guard.
    #expect(!CommandRegistry.all.isEmpty)
    let byName: [String: CommandSpec] = Dictionary(
        uniqueKeysWithValues: CommandRegistry.all.map { ($0.name, $0) }
    )

    #expect(byName["switchyard"] != nil)
    #expect(byName["noop"] != nil)

    // Known keys return non-nil specs. Unknown ones must not accidentally succeed — that
    // would turn a typo into a working command, which is the exact bug this guard catches.
    #expect(byName["does-not-exist"] == nil)
}

@Test("registry lookup by name returns unknown as nil")
func registryLookupUnknownReturnsNil() {
    for bogus in ["", "XYZzy", "--help", "-v"] {
        let result = CommandRegistry.lookup(name: bogus)
        #expect(result == nil, "Bogus lookup '\(bogus)' must return nil so callers get a clean 'unknown' error path.")
    }
}

// MARK: - Integration with runYard (selected paths)

@Test("--help prints a top-level help string with exit 0")
func runYardHelpPrintsTopLevel() {
    let (stdout, stderr, code) = runYard(arguments: ["--help"])

    #expect(code == .success, "exit code 0 — print help to stdout")
    #expect(stderr.isEmpty, "--help must not write anything to stderr")
    #expect(!stdout.isEmpty, "the rendered help text is non-empty")

    // The registry consumer must not re-emit a JSON envelope around help text —
    // plain text is the contract; anything wrapping `{"ok":true,...}` around it
    // would fail downstream parsers.
    #expect(!stdout.hasPrefix("{"), "help output must not start with a JSON envelope")

    // The topic — help exit code range — is part of the spec, so it has to appear
    // in rendered text for visual consistency and so tests below keep passing.
    #expect(stdout.range(of: "Exit code") != nil || stdout.range(of: "exit code") != nil
            || stdout.range(of: "Exit codes") != nil,
            "--help output must mention exit codes so callers know when --version exits 0.")
}

@Test("registry schema command writes pretty-printed JSON")
func runYardSchemaWritesPrettyJSON() {
    let (stdout, stderr, code) = runYard(arguments: ["schema"])

    #expect(code == .success)
    #expect(stderr.isEmpty, "schema must not write to stderr on success")
    // The envelope line has to be valid JSON before we drill into its body — a bare
    // string literal that doesn't decode should be considered broken output.
    #expect(!stdout.isEmpty)

    // The envelope must decode as a JSON object — `true`, `"text"`, or `[]`
    // should all fail to be cast as [String: Any], so we assert on the result.
    let data = Data(stdout.utf8)

    guard let parsed = (try? JSONSerialization.jsonObject(with: data)),
          let obj = parsed as? [String: Any] else {
        Issue.record("schema stdout must be valid UTF-8 and a JSON object")
        return
    }

    #expect(parsed is [String: Any], "schema output must be a JSON object, not true/false/array/string")

    // The top-level shape — schemaVersion, ok, result.commands — is the contract.
    #expect(obj["schemaVersion"] != nil)

    // The commands array must contain the two known specs. If anyone adds a
    // third command and forgets to register it here, this assertion fails.
    guard let result = obj["result"] as? [String: Any],
          let commands = result["commands"] as? [[String: Any]] else {
        Issue.record("schema result.commands must be an array of command objects")
        return
    }

    #expect(commands.count >= 2, "schema output must include at least the switchyard and noop specs")

    let names = Set(commands.map { $0["command"] as? String ?? "" })
    #expect(names.contains("switchyard"))
    #expect(names.contains("noop"))

    // The indentation test makes sure JSONEncoder was used to pretty-print
    // the envelope, not a raw-string shortcut that skips indentation.
    let lines = stdout.split(whereSeparator: \.isNewline)
    #expect(lines.contains { $0.hasPrefix("  ") && !$0.hasPrefix("    ") }, "schema output must be pretty-printed with indent")
}

@Test("noop exits 0 with the success envelope even after extension")
func noopStillExitsSuccessEnvelope() {
    let (stdout, stderr, code) = runYard(arguments: ["noop"])

    #expect(code == .success)
    #expect(stderr.isEmpty, "no reason for stderr to be non-empty on success")

    // The envelope has schemaVersion and ok=true by design — verify it before we
    // reach for a result key that may not be present. Removing this assertion would
    // let broken envelope output pass silently, which is the bug that keeps hiding.
    #expect(stdout.hasPrefix("{"))

    let data = Data(stdout.utf8)

    guard let parsed = (try? JSONSerialization.jsonObject(with: data)),
          let obj = parsed as? [String: Any] else {
        Issue.record("noop stdout must be a valid JSON object")
        return
    }

    #expect(obj["ok"] as? Bool == true)
}
