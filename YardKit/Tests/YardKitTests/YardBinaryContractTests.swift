// YardBinaryContractTests.swift

import Foundation
import Testing
@testable import YardKit

/// Spawns the `switchyard` binary as a subprocess and asserts on its
/// stdout envelope + exit code. This is the only way to verify the
/// contract: encoding a struct in-process cannot prove what a caller
/// actually receives from the running binary.
struct YardBinaryContractTests {

    // MARK: - Locator

    /// Anchors on a type defined in the test target so Bundle is the one
    /// registered when `swift test` runs.
    private final class BundleAnchor {}

    var yardBinary: URL {
        Bundle(for: BundleAnchor.self)
            .bundleURL                       // …/debug/YardKitPackageTests.xctest
            .deletingLastPathComponent()     // …/debug
            .appendingPathComponent("switchyard")
    }

    /// Preflight: if the binary isn't there the test must fail loudly.
    /// A subprocess test that silently does nothing is exactly the
    /// failure this file exists to prevent.
    private var binaryExists: Bool {
        FileManager.default.fileExists(atPath: yardBinary.path)
    }

    // MARK: - Helpers

    /// Spawn the binary, capture stdout and stderr separately, return
    /// (exitCode, stdoutBytes, stderrBytes). `args` may be empty for the
    /// bare binary invocation. Foundation's `Process.arguments` setter
    /// rejects `nil`, so we always assign a non-nil array — an empty one
    /// gives us argv[0] only.
    private func run(args: String...) -> (status: Int32, stdout: Data, stderr: Data) {
        let proc = Process()
        proc.executableURL = yardBinary

        // Process.arguments excludes argv[0] — argv[0] derives from
        // executableURL. Do not insert the binary path as an argument,
        // that becomes a bogus subcommand and every case fails.
        proc.arguments = Array(args.filter { !$0.isEmpty })

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try? proc.run()
        proc.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return (proc.terminationStatus, stdoutData, stderrData)
    }

    /// Best-effort UTF-8 decode for assertions.
    private func stdoutString(data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    /// Parse `data` as JSON via JSONSerialization; return nil if it does
    /// not parse (or is empty).
    private func parseJSON(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [])
    }

    // MARK: - Preflight

    @Test("binary exists") func binaryExistsCheck() {
        #expect(binaryExists, "switchyard binary not found at \(yardBinary.path); swift test must build it first")
    }

    // MARK: - Success path

    @Test("root command exits 0 with a valid envelope") func rootCommandSuccess() {
        guard binaryExists else { return }

        let (status, stdout, _) = run()
        #expect(status == 0)

        let json = parseJSON(stdout)
        #expect(json != nil, "root command stdout is not valid JSON")

        guard let dict = json as? [String: Any] else { return }
        #expect(dict["ok"] is Bool && (dict["ok"] as? Bool) == true, "success envelope must have ok=true")
        #expect(dict["schemaVersion"] is Int)
    }

    // MARK: - Failure path — usage error

    @Test("unknown subcommand exits 1 with a valid envelope") func unknownSubcommandUsageError() {
        guard binaryExists else { return }

        let (status, stdout, _) = run(args: "bogus-command")
        #expect(status == 1)

        let json = parseJSON(stdout)
        #expect(json != nil, "usage-error stdout is not valid JSON")

        guard let dict = json as? [String: Any] else { return }
        #expect(dict["ok"] is Bool && (dict["ok"] as? Bool) == false, "failure envelope must have ok=false")

        let errorCode: Any?
        if let inner = dict["error"] as? [String: Any] {
            errorCode = inner["code"]
        } else {
            errorCode = nil
        }
        #expect(errorCode as? String == "usage", "error.code must be \"usage\", got \(String(describing: errorCode))")
    }

    // MARK: - No non-JSON prefix/suffix

    @Test("success stdout is pure JSON") func successNoNonJsonPrefixOrSuffix() {
        guard binaryExists else { return }

        let (_, stdout, _) = run(args: "")
        guard !stdout.isEmpty else {
            Issue.record("success stdout was empty")
            return
        }

        let str = stdoutString(data: stdout)
        // The first character of a JSON value must be `{`, `[`, `"`, digit, `t`, `f`, or `n`.
        let jsonStart = CharacterSet(charactersIn: "{}[]\"")
            .union(CharacterSet(charactersIn: "tf"))

        let firstIsJSON: Bool = if let c = str.first {
            "{}[]\"tf".contains(c) || CharacterSet.decimalDigits.contains(c.unicodeScalars.first!)
        } else {
            false
        }
        #expect(firstIsJSON, "success stdout does not start with a JSON value")
        // The last non-whitespace character of a JSON value must be `}`, `]`, `"`, digit, `t`, `f`, or `n`.
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!trimmed.isEmpty, "success stdout was empty after trimming")
    }

    @Test("failure stdout is pure JSON") func failureNoNonJsonPrefixOrSuffix() {
        guard binaryExists else { return }

        let (_, stdout, _) = run(args: "bogus-command")
        guard !stdout.isEmpty else {
            Issue.record("failure stdout was empty")
            return
        }

        _ = stdoutString(data: stdout)
        #expect(parseJSON(stdout) != nil, "failure stdout is not valid JSON")
    }

    // MARK: - stderr observed to be empty (documented gap, #0100)

    @Test("stderr is currently empty on success") func stderrEmptyOnSuccess() {
        guard binaryExists else { return }
        let (_, _, stderr) = run(args: "")
        #expect(stderr.isEmpty, "stderr should be empty on success but got \(String(data: stderr, encoding: .utf8) ?? "<non-UTF8>")")
    }

    @Test("stderr is currently empty on failure") func stderrEmptyOnFailure() {
        guard binaryExists else { return }
        let (_, _, stderr) = run(args: "bogus-command")
        #expect(stderr.isEmpty, "stderr should be empty on failure but got \(String(data: stderr, encoding: .utf8) ?? "<non-UTF8>")")
    }

    // MARK: - noop path (second success case)

    @Test("noop exits 0 with a valid envelope") func noopSuccess() {
        guard binaryExists else { return }

        let (status, stdout, _) = run(args: "noop")
        #expect(status == 0)

        let json = parseJSON(stdout)
        #expect(json != nil, "noop stdout is not valid JSON")

        guard let dict = json as? [String: Any] else { return }
        #expect(dict["ok"] is Bool && (dict["ok"] as? Bool) == true, "noop envelope must have ok=true")
    }

    // MARK: - Non-zero exit code distinct from usage-specific codes

    @Test("usage failure emits schemaVersion and ok=false") func usageEmitsSchemaVersionAndOkFalse() {
        guard binaryExists else { return }

        let (_, stdout, _) = run(args: "bogus-command")
        #expect(!stdout.isEmpty)

        guard let dict = parseJSON(stdout) as? [String: Any] else { return }
        #expect(dict["schemaVersion"] is Int)
        #expect((dict["ok"] as? Bool) == false, "usage envelope must have ok=false")
    }
}
