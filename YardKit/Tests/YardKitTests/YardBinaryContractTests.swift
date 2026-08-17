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

    // MARK: - Failure path -- app unreachable for a known remote command
    //
    // A *known* command `runYard` cannot answer on its own -- one named in
    // `CommandRegistry.all`, currently only "whereami" -- is routed through
    // `dispatch` to the app (guide §11 decision 15, #0124, `route(_:)` in
    // CommandLineRunner.swift). Spawning the real binary with that command
    // would therefore try to reach the real broker/app on whatever machine
    // runs this suite -- on a machine with the broker registered that can
    // mean actually launching Switchyard.app, which this suite must never
    // do (see CLAUDE.md's Code signing / "never launch the app"
    // boundaries). So this test, and the four below it, call `dispatch`
    // in-process with an injected connector that always throws, instead of
    // spawning a subprocess.
    //
    // These tests deliberately do NOT use a genuinely unknown/typo'd
    // command such as "bogus-command": as of #0124 round 3, `route(_:)`
    // classifies that as `.unknown` rather than `.remote`, and `dispatch`
    // answers `.unknown` the same way it answers `.local` -- straight from
    // `runYard`, without ever touching `connect` at all. Using a bogus
    // command here would test the wrong path (and would pass for the wrong
    // reason, since a usage envelope is also `ok: false` with a
    // `schemaVersion`). "whereami" is used instead because it is a real,
    // registered command that genuinely needs the app -- see
    // `DispatchTests.unknownCommandNeverCallsConnectAndExitsWithUsage` for
    // the `.unknown` case's own dedicated test, including the assertion
    // that the connector is never invoked.
    //
    // The local-only paths elsewhere in this file (root command, noop,
    // binary-exists) are unaffected: those commands are always answered
    // locally and never touch the connector, subprocess or not.

    /// Always fails, deterministically, without ever touching a broker, a
    /// launch agent, or `NSWorkspace` -- the seam `dispatch` exists to make
    /// testable (see its doc comment in Dispatch.swift).
    private func unreachableAppConnector() async throws -> AppConnection {
        throw AppConnectionError.appUnavailable
    }

    @Test("a known remote command routes to the app and exits 3 when it is unreachable")
    func remoteCommandRoutesToUnreachableApp() async throws {
        let result = await dispatch(
            arguments: ["whereami"], workingDirectory: "/", connect: unreachableAppConnector)

        #expect(result.exitCode == .appUnavailable)

        let data = Data(result.stdout.utf8)
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: [])
            #expect(json is [String: Any], "failure stdout is not a JSON dictionary")
            let dict = try #require(json as? [String: Any], "stdout parsed but was not a JSON object")

            #expect(dict["ok"] as? Bool == false, "failure envelope must have ok=false")

            let errorCode: Any?
            if let inner = dict["error"] as? [String: Any] {
                errorCode = inner["code"]
            } else {
                errorCode = nil
            }

            #expect(errorCode as? String == "app_unavailable", "error.code must be \"app_unavailable\", got \(String(describing: errorCode))")
        } catch {
            Issue.record("failure stdout is not valid JSON: \(error)")
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

    @Test("failure stdout is pure JSON") func failureNoNonJsonPrefixOrSuffix() async throws {
        let result = await dispatch(
            arguments: ["whereami"], workingDirectory: "/", connect: unreachableAppConnector)
        let stdout = Data(result.stdout.utf8)
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

    @Test("stderr carries the error line on failure") func stderrCarriesErrorLineOnFailure() async throws {
        let result = await dispatch(
            arguments: ["whereami"], workingDirectory: "/", connect: unreachableAppConnector)
        let text = result.stderr

        #expect(!text.isEmpty, "stderr must not be empty on failure")
        if !text.isEmpty {
            #expect(text.hasPrefix("[error]"), "stderr should begin with '[error]' marker")
            #expect(text.contains("app_unavailable"), "stderr must contain the error code label 'app_unavailable'")
            #expect(text.hasSuffix("\n"), "stderr line must terminate with newline")
        }
    }

    @Test("failure stderr uses wire code not Swift case name") func failureStderrUsesWireCode() async throws {
        let result = await dispatch(
            arguments: ["whereami"], workingDirectory: "/", connect: unreachableAppConnector)
        let text = result.stderr

        #expect(!text.isEmpty, "stderr must not be empty on failure")
        if !text.isEmpty {
            #expect(text.contains("app_unavailable"), "stderr should carry wire code 'app_unavailable'")
            #expect(!text.contains("EnvelopeErrorCode"), "stderr must not leak Swift type qualifiers")
            #expect(!text.contains("AppConnectionError"), "stderr must not leak Swift type qualifiers")
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

    @Test("app-unreachable failure emits schemaVersion and ok=false") func appUnreachableEmitsSchemaVersionAndOkFalse() async throws {
        let result = await dispatch(
            arguments: ["whereami"], workingDirectory: "/", connect: unreachableAppConnector)
        let stdout = Data(result.stdout.utf8)
        #expect(!stdout.isEmpty, "stdout was empty on failure")

        do {
            let json = try JSONSerialization.jsonObject(with: stdout, options: [])
            #expect(json is [String: Any], "failure stdout is not a JSON dictionary")
            let dict = try #require(json as? [String: Any], "stdout parsed but was not a JSON object")

            #expect(dict["schemaVersion"] is Int)
            #expect((dict["ok"] as? Bool) == false, "failure envelope must have ok=false")
        } catch {
            Issue.record("failure stdout is not valid JSON: \(error)")
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
