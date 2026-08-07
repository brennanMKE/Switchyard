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
            .bundleURL                       // .../debug/YardKitPackageTests.xctest
            .deletingLastPathComponent()     // .../debug
            .appendingPathComponent("switchyard")
    }

    @Test("binary exists") func binaryExistsCheck() {
        #expect(
            FileManager.default.fileExists(atPath: yardBinary.path),
            "switchyard binary not found at \(yardBinary.path); swift test must build it first"
        )
    }

    // MARK: - Helpers

    private func runProcess(binaryPath: URL, args: [String]) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let proc = Process()
        proc.executableURL = binaryPath
        proc.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()
        proc.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return (proc.terminationStatus, stdoutData, stderrData)
    }

    // MARK: - Success path

    @Test("root command exits 0 with a valid envelope") func rootCommandSuccess() throws {
        #expect(
            FileManager.default.fileExists(atPath: yardBinary.path),
            "switchyard binary not found at \(yardBinary.path); swift test must build it first"
        )

        let (status, stdout, _) = try runProcess(binaryPath: yardBinary, args: [])
        #expect(status == 0)

        do {
            let json = try JSONSerialization.jsonObject(with: stdout, options: [])
            #expect(json is [String: Any], "root command stdout is not a JSON dictionary")
            let dict = try #require(json as? [String: Any], "stdout parsed but was not a JSON object")

            #expect(dict["ok"] as? Bool == true, "success envelope must have ok=true")
            #expect(dict["schemaVersion"] is Int)
        } catch {
            Issue.record("root command stdout is not valid JSON: \(error)")
        }
    }

    // MARK: - Failure path -- usage error

    @Test("unknown subcommand exits 1 with a valid envelope") func unknownSubcommandUsageError() throws {
        #expect(
            FileManager.default.fileExists(atPath: yardBinary.path),
            "switchyard binary not found at \(yardBinary.path); swift test must build it first"
        )

        let (status, stdout, _) = try runProcess(binaryPath: yardBinary, args: ["bogus-command"])
        #expect(status == 1)

        do {
            let json = try JSONSerialization.jsonObject(with: stdout, options: [])
            #expect(json is [String: Any], "usage-error stdout is not a JSON dictionary")
            let dict = try #require(json as? [String: Any], "stdout parsed but was not a JSON object")

            #expect(dict["ok"] as? Bool == false, "failure envelope must have ok=false")

            let errorCode: Any?
            if let inner = dict["error"] as? [String: Any] {
                errorCode = inner["code"]
            } else {
                errorCode = nil
            }

            #expect(errorCode as? String == "usage", "error.code must be \"usage\", got \(String(describing: errorCode))")
        } catch {
            Issue.record("usage-error stdout is not valid JSON: \(error)")
        }
    }

    // MARK: - No non-JSON prefix/suffix

    @Test("success stdout is pure JSON with no prefix or suffix") func successStdoutIsPureJson() throws {
        #expect(
            FileManager.default.fileExists(atPath: yardBinary.path),
            "switchyard binary not found at \(yardBinary.path); swift test must build it first"
        )

        let (_, stdout, _) = try runProcess(binaryPath: yardBinary, args: [])
        #expect(!stdout.isEmpty, "success stdout was empty")

        let str = String(data: stdout, encoding: .utf8) ?? ""
        #expect(isJsonStart(str.first), "success stdout does not start with a JSON value")

        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!trimmed.isEmpty, "success stdout was empty after trimming")

        #expect(isJsonEnd(trimmed.last), "success stdout does not end with a JSON value")
    }

    @Test("failure stdout is pure JSON") func failureNoNonJsonPrefixOrSuffix() throws {
        #expect(
            FileManager.default.fileExists(atPath: yardBinary.path),
            "switchyard binary not found at \(yardBinary.path); swift test must build it first"
        )

        let (_, stdout, _) = try runProcess(binaryPath: yardBinary, args: ["bogus-command"])
        #expect(!stdout.isEmpty, "failure stdout was empty")

        do {
            let _ = try JSONSerialization.jsonObject(with: stdout, options: [])
        } catch {
            Issue.record("failure stdout is not valid JSON: \(error)")
        }
    }

    // MARK: - stderr contract

    @Test("stderr is empty on success") func stderrEmptyOnSuccess() throws {
        #expect(
            FileManager.default.fileExists(atPath: yardBinary.path),
            "switchyard binary not found at \(yardBinary.path); swift test must build it first"
        )

        let (_, _, stderr) = try runProcess(binaryPath: yardBinary, args: [])
        #expect(stderr.isEmpty, "stderr should be empty on success but got \(String(data: stderr, encoding: .utf8) ?? "<non-UTF8>")")
    }

    @Test("stderr carries the error line on failure") func stderrCarriesErrorLineOnFailure() throws {
        #expect(
            FileManager.default.fileExists(atPath: yardBinary.path),
            "switchyard binary not found at \(yardBinary.path); swift test must build it first"
        )

        let (_, _, stderr) = try runProcess(binaryPath: yardBinary, args: ["bogus-command"])
        let text = String(data: stderr, encoding: .utf8) ?? ""

        #expect(!text.isEmpty, "stderr must not be empty on failure")
        if !text.isEmpty {
            #expect(text.hasPrefix("[error]"), "stderr should begin with '[error]' marker")
            #expect(text.contains("usage"), "stderr must contain the error code label 'usage'")
            #expect(text.contains("bogus-command"), "stderr must contain the offending subcommand name")
            #expect(text.hasSuffix("\n"), "stderr line must terminate with newline")
        }
    }

    @Test("failure stderr uses wire code not Swift case name") func failureStderrUsesWireCode() throws {
        #expect(
            FileManager.default.fileExists(atPath: yardBinary.path),
            "switchyard binary not found at \(yardBinary.path); swift test must build it first"
        )

        let (_, _, stderr) = try runProcess(binaryPath: yardBinary, args: ["bogus-command"])
        let text = String(data: stderr, encoding: .utf8) ?? ""

        #expect(!text.isEmpty, "stderr must not be empty on failure")
        if !text.isEmpty {
            #expect(text.contains("usage"), "stderr should carry wire code 'usage'")
            #expect(!text.contains("EnvelopeErrorCode"), "stderr must not leak Swift type qualifiers")
        }
    }

    // MARK: - noop path (second success case)

    @Test("noop exits 0 with a valid envelope") func noopSuccess() throws {
        #expect(
            FileManager.default.fileExists(atPath: yardBinary.path),
            "switchyard binary not found at \(yardBinary.path); swift test must build it first"
        )

        let (status, stdout, _) = try runProcess(binaryPath: yardBinary, args: ["noop"])
        #expect(status == 0)

        do {
            let json = try JSONSerialization.jsonObject(with: stdout, options: [])
            #expect(json is [String: Any], "noop stdout is not a JSON dictionary")
            let dict = try #require(json as? [String: Any], "stdout parsed but was not a JSON object")

            #expect(dict["ok"] as? Bool == true, "noop envelope must have ok=true")
        } catch {
            Issue.record("noop stdout is not valid JSON: \(error)")
        }
    }

    // MARK: - Non-zero exit code distinct from usage-specific codes

    @Test("usage failure emits schemaVersion and ok=false") func usageEmitsSchemaVersionAndOkFalse() throws {
        #expect(
            FileManager.default.fileExists(atPath: yardBinary.path),
            "switchyard binary not found at \(yardBinary.path); swift test must build it first"
        )

        let (_, stdout, _) = try runProcess(binaryPath: yardBinary, args: ["bogus-command"])
        #expect(!stdout.isEmpty, "stdout was empty on usage failure")

        do {
            let json = try JSONSerialization.jsonObject(with: stdout, options: [])
            #expect(json is [String: Any], "usage failure stdout is not a JSON dictionary")
            let dict = try #require(json as? [String: Any], "stdout parsed but was not a JSON object")

            #expect(dict["schemaVersion"] is Int)
            #expect((dict["ok"] as? Bool) == false, "usage envelope must have ok=false")
        } catch {
            Issue.record("usage failure stdout is not valid JSON: \(error)")
        }
    }

    // MARK: - JSON boundary helpers

    private func isJsonStart(_ c: Character?) -> Bool {
        guard let c = c else { return false }
        return "{}[]\"".contains(c) || "tf".contains(c) || c.isNumber
    }

    private func isJsonEnd(_ c: Character?) -> Bool {
        guard let c = c else { return false }
        return "}]\"".contains(c) || "tf".contains(c) || c.isNumber
    }

}
