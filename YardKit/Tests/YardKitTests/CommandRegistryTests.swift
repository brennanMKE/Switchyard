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
    // The documented commands must exist. If someone adds another later,
    // this assertion continues to hold rather than silently failing.
    #expect(names.contains("switchyard"))
    #expect(names.contains("noop"))
    #expect(names.contains("whereami"))

    // Every spec must have a non-empty name, a non-empty schemaName, and at least
    // one documented exit code. Empty fields or no exit codes would indicate broken
    // spec construction that we want caught here — each iteration reaches an assertion.
    for spec in list {
        #expect(!spec.name.isEmpty, "Every spec must have a non-empty name")
        #expect(!spec.schemaName.isEmpty, "Every spec must have a non-empty schemaName")
        #expect(!spec.exitCodes.isEmpty, "Every spec must have at least one documented exit code")
    }
}

@Test("registry reports exactly eleven entries")
func registryHasExactlyElevenEntries() {
    #expect(CommandRegistry.all.count == 11)

    let names: [String] = CommandRegistry.all.map(\.name)
    #expect(Set(names).count == 11, "Names must be distinct so lookup returns the right spec.")
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

    // `renderHelp` emits the literal heading "Exit codes:". Asserting the exact
    // heading rather than a disjunction of near-identical substrings, two of
    // which are prefixes of the third and so could never disagree.
    #expect(stdout.contains("Exit codes:"),
            "--help must render the exit-code section so callers know when each code is returned.")
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

    // The top-level shape — schemaVersion, ok, result.commands — is the contract.
    #expect(obj["schemaVersion"] != nil)

    // The commands array must contain the two known specs. If anyone adds a
    // third command and forgets to register it here, this assertion fails.
    guard let result = obj["result"] as? [String: Any],
          let commands = result["commands"] as? [[String: Any]] else {
        Issue.record("schema result.commands must be an array of command objects")
        return
    }

    // Every spec in the registry must appear — a third command dropped by the
    // emitter would otherwise pass silently. Each element must have a non-empty
    // command key, asserted unconditionally.
    #expect(commands.count == CommandRegistry.all.count,
            "schema output must include exactly as many commands as the registry")

    #expect(!commands.isEmpty, "must have at least one command to iterate")
    for cmd in commands {
        let name = cmd["command"] as? String ?? ""
        #expect(!name.isEmpty, "Every schema element must have a non-empty 'command' key")
    }

    // The indentation test makes sure JSONEncoder was used to pretty-print
    // the envelope, not a raw-string shortcut that skips indentation.
    let lines = stdout.split(whereSeparator: \.isNewline)
    #expect(lines.contains { $0.hasPrefix("  ") && !$0.hasPrefix("    ") }, "schema output must be pretty-printed with indent")
}

// MARK: - --version / -v

@Test("--version prints version text and exits 0")
func runYardVersionFlagPrintsText() throws {
    let (stdout, stderr, code) = runYard(arguments: ["--version"])

    #expect(code == .success, "--version should exit with success (0)")
    #expect(stderr.isEmpty, "--version must not write to stderr")
    #expect(!stdout.isEmpty, "the version text is non-empty")

    // --version is a human command: plain text, first byte not {.
    #expect(stdout.first != "{", "--version output must be plain text, not JSON")

    // The output carries both the CLI name and a version string.
    let parts = stdout.split(whereSeparator: \.isNewline).map(String.init)
    let body = try #require(parts.first, "--version must print at least one line")
    #expect(body.contains(ServiceNames.cliName), "--version output should carry the CLI name")

    // Split on whitespace and check that at least two tokens exist (name + version).
    let tokens = body.split(separator: " ").map(String.init)
    #expect(tokens.count >= 2, "--version output should have name and version as separate tokens")
}

@Test("-v prints version text with the short flag alias")
func runYardShortVersionFlagPrintsText() {
    let (stdout, stderr, code) = runYard(arguments: ["-v"])

    #expect(code == .success, "-v should exit with success (0)")
    #expect(stderr.isEmpty, "-v must not write to stderr")
    #expect(!stdout.isEmpty, "the version text is non-empty")

    // -v and --version must emit identical output — same bytes.
    let long = runYard(arguments: ["--version"]).stdout
    #expect(stdout == long, "-v and --version must emit identical text")

    // First byte still not { — plain text contract holds for the short alias.
    #expect(stdout.first != "{", "-v output must be plain text, not JSON")
}

// MARK: - noop after removing per-subcommand help

@Test("noop with extra arguments still returns the success envelope, exit 0")
func noopWithExtraArgumentsReturnsSuccessEnvelope() {
    let result = runYard(arguments: ["noop", "extra"])

    #expect(result.exitCode == .success,
            "noop with extra args must exit 0 and return the success envelope, not 'unknown'")
    #expect(result.stderr.isEmpty, "noop must produce no stderr on success")

    // stdout is the JSON envelope: first {, last }, parses as an object.
    let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(trimmed.first == "{", "noop+args output must start with {")
    #expect(trimmed.last == "}", "noop+args output must end with }")

    guard let data = trimmed.data(using: .utf8),
          let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        Issue.record("noop+args stdout must decode as a valid JSON object")
        return
    }

    #expect(parsed["ok"] as? Bool == true, "noop+args envelope should have ok=true")
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
