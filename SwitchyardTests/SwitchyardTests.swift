import Foundation
import Testing

struct SwitchyardTests {

    private static let boundedWait: TimeInterval = 5.0
    private static let pollIntervalNanoseconds: UInt64 = 100_000_000

    @Test func appSurvivesFiveSecondsWhenLaunchedAgainstAGitWorkspace() async throws {
        let executable = try Self.appExecutable()
        let repository = try Self.makeTemporaryGitRepository()
        defer { try? FileManager.default.removeItem(at: repository) }

        let process = Process()
        process.executableURL = executable
        process.arguments = [repository.path]
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        do {
            try process.run()
        } catch {
            Issue.record("Switchyard failed to launch at \(executable.path): \(error)")
            return
        }
        defer { Self.stop(process) }

        let deadline = Date().addingTimeInterval(Self.boundedWait)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }
        let survived = process.isRunning

        Self.stop(process)
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        #expect(survived, """
            Switchyard was not alive after the \(Int(Self.boundedWait)) s bounded wait \
            (termination status \(process.terminationStatus), \
            reason: \(process.terminationReason == .uncaughtSignal ? "uncaught signal" : "exit")). \
            stderr: \(stderr.isEmpty ? "(empty)" : stderr)
            """)
    }

    private static func appExecutable() throws -> URL {
        let productsDirectory: URL
        if let envPath = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"] {
            productsDirectory = URL(fileURLWithPath: envPath, isDirectory: true)
        } else {
            productsDirectory = Bundle(for: BundleToken.self).bundleURL
        }
        let appBundleName = "Switchyard.app"
        let relativeExecutable = "Contents/MacOS/Switchyard"
        var candidateDirectory = productsDirectory
        var candidate = candidateDirectory
            .appendingPathComponent(appBundleName, isDirectory: true)
            .appendingPathComponent("Contents/MacOS/Switchyard")
        while !FileManager.default.fileExists(atPath: candidate.path)
            && candidateDirectory.path != "/"
            && candidateDirectory.path != "." {
            candidateDirectory.deleteLastPathComponent()
            candidate = candidateDirectory
                .appendingPathComponent(appBundleName, isDirectory: true)
                .appendingPathComponent("Contents/MacOS/Switchyard")
        }
        try #require(
            FileManager.default.fileExists(atPath: candidate.path),
            "built app executable not found (searched up from \(productsDirectory.path))"
        )
        return candidate
    }

    private static func makeTemporaryGitRepository() throws -> URL {
        let scratch = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("launch-smoke", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let repository = scratch.appendingPathComponent(
            "repo-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(["init", "--initial-branch=main", repository.path])
        try runGit(["-C", repository.path, "config", "user.email", "smoke-test@example.invalid"])
        try runGit(["-C", repository.path, "config", "user.name", "Switchyard Smoke Test"])
        try runGit(["-C", repository.path, "commit", "--allow-empty", "-m", "smoke"])
        return repository
    }

    private static func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw GitFixtureError(
                command: "git \(arguments.joined(separator: " "))",
                status: process.terminationStatus,
                stderr: stderr
            )
        }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning, process.processIdentifier > 0 {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private struct GitFixtureError: Error, CustomStringConvertible {
        let command: String
        let status: Int32
        let stderr: String

        var description: String {
            "git fixture step failed (status \(status)): \(command) — \(stderr)"
        }
    }

    private final class BundleToken {}
}
