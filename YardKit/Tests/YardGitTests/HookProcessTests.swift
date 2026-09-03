// HookProcessTests.swift — the built binary as a real hook in a real
// repository (#0154)

import Foundation
import Testing
import YardGit

/// Runs the built `switchyard` executable — the same binary the installed
/// hook script execs — as a subprocess, and reports its exit status.
private func runSwitchyard(
    _ arguments: [String],
    executable: URL,
    environment: [String: String],
    standardInput: Data
) throws -> (status: Int32, stderr: String) {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    if !standardInput.isEmpty {
        try? stdinPipe.fileHandleForWriting.write(contentsOf: standardInput)
    }
    try? stdinPipe.fileHandleForWriting.close()

    process.waitUntilExit()

    // The arm writes at most one short line to stderr (the wrapper discards
    // it in production), so draining after `waitUntilExit` cannot deadlock:
    // the output is far below the pipe buffer's capacity.
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()

    return (process.terminationStatus, String(decoding: stderrData, as: UTF8.self))
}

@Suite("Hook process: the built binary as a real hook")
struct HookProcessTests {

    /// The package root, walked from this file so the test works wherever
    /// the worktree is checked out.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardGitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit (package root)
    }

    /// The built `switchyard` binary. `swift test` builds every target in
    /// the package, executables included, so this exists by the time tests
    /// run; a missing binary is a hard failure, not a skip.
    private var switchyardBinary: URL {
        packageRoot.appendingPathComponent(".build/debug/switchyard")
    }

    /// A scratch bin directory under the package's `build/` (gitignored)
    /// holding a `switchyard` symlink to the built binary — the shape PATH
    /// resolution delivers to the hook script's `command -v switchyard`.
    private func makeBinDirectory(
        containing linkName: String = "switchyard",
        target: URL? = nil
    ) throws -> URL {
        let binary = target ?? switchyardBinary
        try #require(
            FileManager.default.fileExists(atPath: binary.path),
            "the built switchyard binary is missing at \(binary.path) — swift test builds it")
        let directory = packageRoot
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("hook-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(linkName),
            withDestinationURL: binary)
        return directory
    }

    /// Installs #0041's script verbatim into the fixture's hooks directory,
    /// resolved through git like every other hook path, and marks it
    /// executable — git ignores a non-executable hook.
    private func installReferenceTransactionHook(in repo: FixtureRepository) throws {
        let git = GitProcess()
        let relative = try git.run(
            ["rev-parse", "--git-path", "hooks"],
            workingDirectory: repo.url.path).lines[0]
        let hooksDirectory = relative.hasPrefix("/")
            ? URL(fileURLWithPath: relative)
            : repo.url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: hooksDirectory, withIntermediateDirectories: true)
        let hookURL = hooksDirectory.appendingPathComponent("reference-transaction")
        try Data(HookInstall.script(for: .referenceTransaction).utf8).write(to: hookURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
    }

    /// The environment the hook process inherits: git propagates its own
    /// environment to hooks, so putting the bin dir first on PATH is what
    /// makes `command -v switchyard` resolve to the test's symlink rather
    /// than to any CLI a developer has installed system-wide.
    private func hookEnvironment(binDirectory: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let systemPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = binDirectory.path + ":" + systemPath
        return environment
    }

    // MARK: - The real chain: git → script → arm

    /// The criterion, end to end and in both ref formats: with #0041's
    /// script installed and the built binary on the hook's PATH, a ref
    /// update must always succeed — the hook must never abort the user's
    /// transaction. The first commit runs the arm's full forward path
    /// (foreign marker, so stdin is drained and the app is contacted; an
    /// unreachable app must not break anything, and if the developer's real
    /// app happens to be running it simply records the fixture's updates).
    /// The second runs the own-transaction short-circuit. Both exit 0.
    ///
    /// No wall-clock assertion: what the invariant requires is that the
    /// commit happened, which `git.commit`'s throw-on-non-zero plus the ref
    /// reads below assert.
    @Test(
        "a real commit with the hook installed never aborts, in both ref formats",
        arguments: FixtureRepository.RefFormat.supported(git: GitProcess())
    )
    func realHookNeverAbortsTheTransaction(refFormat: FixtureRepository.RefFormat) throws {
        let binDirectory = try makeBinDirectory()
        defer { try? FileManager.default.removeItem(at: binDirectory) }

        var repo = try FixtureRepository(refFormat: refFormat)
        defer { repo.destroy() }
        try installReferenceTransactionHook(in: repo)

        let git = GitProcess()
        var foreignEnvironment = hookEnvironment(binDirectory: binDirectory)
        // Present-but-empty counts as foreign — the documented escape hatch
        // (#0043) — so the arm takes its full forward path inside the real
        // chain here, not just the own-transaction short-circuit.
        foreignEnvironment[GitProcess.markerVariable] = ""

        try git.run(
            ["commit", "-q", "--allow-empty", "-m", "foreign commit"],
            workingDirectory: repo.url.path,
            extraEnvironment: foreignEnvironment)

        // Own transaction: the marker GitProcess stamps by default, so the
        // arm gates out before draining stdin — and still exits 0.
        try git.run(
            ["commit", "-q", "--allow-empty", "-m", "own commit"],
            workingDirectory: repo.url.path,
            extraEnvironment: hookEnvironment(binDirectory: binDirectory))

        // The transactions succeeded: refs exist and resolve.
        let head = try repo.revParse("HEAD")
        #expect(!head.isEmpty)
        let refs = try repo.refNames()
        #expect(refs.contains("refs/heads/main"))
    }

    /// The contract between #0041's script and this arm, proven
    /// behaviorally: the wrapper execs `switchyard hook ref-txn <state>`
    /// with the hook payload on stdin. A stand-in executable records what
    /// it was handed; the real arm's argv/stdin handling is covered by the
    /// direct tests below and the gate tests in YardKitTests.
    @Test func wrapperInvokesTheArmWithStateAndPayload() throws {
        let binDirectory = try makeBinDirectory()
        defer { try? FileManager.default.removeItem(at: binDirectory) }

        // Replace the symlink with a stand-in that records argv and stdin
        // into files beside itself.
        let standIn = binDirectory.appendingPathComponent("switchyard")
        try FileManager.default.removeItem(at: standIn)
        let recording = """
        #!/bin/sh
        printf '%s\\n' "$*" > "$0.argv"
        cat > "$0.stdin"
        exit 0
        """
        try Data(recording.utf8).write(to: standIn)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: standIn.path)

        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }
        try installReferenceTransactionHook(in: repo)

        let hooksRelative = try GitProcess().run(
            ["rev-parse", "--git-path", "hooks"],
            workingDirectory: repo.url.path).lines[0]
        let hooksDirectory = hooksRelative.hasPrefix("/")
            ? URL(fileURLWithPath: hooksRelative)
            : repo.url.appendingPathComponent(hooksRelative)
        let hookPath = hooksDirectory.appendingPathComponent("reference-transaction").path

        let payload = Data("0000000 1234567 refs/heads/main\n".utf8)
        let result = try runSwitchyard(
            [hookPath, "committed"],
            executable: URL(fileURLWithPath: "/bin/sh"),
            environment: hookEnvironment(binDirectory: binDirectory),
            standardInput: payload)
        #expect(
            result.status == 0,
            "wrapper exited \(result.status), stderr: \(result.stderr)")

        // The wrapper found the stand-in through PATH, called it exactly the
        // way the arm must be callable, and replayed the payload on stdin.
        let argvURL = standIn.appendingPathExtension("argv")
        let stdinURL = standIn.appendingPathExtension("stdin")
        let argv = try #require(
            try? String(contentsOf: argvURL, encoding: .utf8),
            "the wrapper never invoked switchyard — no argv recording at \(argvURL.path)")
        #expect(argv.trimmingCharacters(in: .whitespacesAndNewlines) == "hook ref-txn committed")
        let receivedStdin = try #require(
            try? Data(contentsOf: stdinURL),
            "the wrapper never delivered stdin — no recording at \(stdinURL.path)")
        #expect(receivedStdin == payload)
    }

    // MARK: - The arm's own totality, at the process boundary

    /// Environment for a direct binary invocation: this process's
    /// environment minus the marker, so the invocation is foreign and takes
    /// the forward path. The bin dir stays on PATH out of realism; the
    /// binary is exec'd by path.
    private func foreignInvocationEnvironment(binDirectory: URL) -> [String: String] {
        var environment = hookEnvironment(binDirectory: binDirectory)
        environment.removeValue(forKey: GitProcess.markerVariable)
        return environment
    }

    /// Garbage stdin on `committed` with no app reachable: the arm must
    /// still exit 0. This is the direct killer of the exit-0 mutation —
    /// the wrapper's `|| :` would mask a non-zero exit, so the arm is
    /// exec'd here without the wrapper around it. One token cannot parse
    /// as `<old> <new> <ref>`, so every line is counted and dropped.
    @Test func garbageStdinOnCommittedExitsZero() throws {
        let binDirectory = try makeBinDirectory()
        defer { try? FileManager.default.removeItem(at: binDirectory) }

        let result = try runSwitchyard(
            ["hook", "ref-txn", "committed"],
            executable: switchyardBinary,
            environment: foreignInvocationEnvironment(binDirectory: binDirectory),
            standardInput: Data("garbage\n".utf8))

        #expect(result.status == 0)
    }

    /// A missing state argument is refused — logged, never a non-zero exit.
    @Test func missingStateArgumentExitsZeroAndLogsTheRefusal() throws {
        let binDirectory = try makeBinDirectory()
        defer { try? FileManager.default.removeItem(at: binDirectory) }

        let result = try runSwitchyard(
            ["hook", "ref-txn"],
            executable: switchyardBinary,
            environment: foreignInvocationEnvironment(binDirectory: binDirectory),
            standardInput: Data())

        #expect(result.status == 0)
        #expect(
            result.stderr.contains("missing state argument"),
            "expected the refusal on stderr, got: \(result.stderr)")
    }

    /// `prepared` — the state a non-zero exit would abort the user's
    /// transaction in — exits 0.
    @Test func preparedStateExitsZero() throws {
        let binDirectory = try makeBinDirectory()
        defer { try? FileManager.default.removeItem(at: binDirectory) }

        let result = try runSwitchyard(
            ["hook", "ref-txn", "prepared"],
            executable: switchyardBinary,
            environment: foreignInvocationEnvironment(binDirectory: binDirectory),
            standardInput: Data())

        #expect(result.status == 0)
    }
}
