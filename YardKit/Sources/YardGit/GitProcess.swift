// GitProcess.swift

import Foundation

/// The single place `YardGit` shells out to `git`.
///
/// The engine is a hybrid: libgit2 for the object database, diff, blame, and
/// merge; `git` for refs, `HEAD`, the reflog, DAG traversal, network
/// operations, hooks, signing, worktrees, and sparse checkout. That boundary is
/// only maintainable if it is visible in one place, so no other type in
/// `YardGit` constructs a `Process` — asserted by a test.
public struct GitProcess: Sendable {

    /// Environment variable set on every invocation so the
    /// `reference-transaction` hook can recognize `yard`'s own ref writes and
    /// skip them (#0042). Without it the journal records itself recording
    /// itself.
    public static let markerVariable = "SWITCHYARD_YARD_INVOCATION"

    public enum Failure: Error, CustomStringConvertible, Sendable {
        /// `git` ran and exited non-zero. Carries stderr, because a bare exit
        /// code tells whoever hits it nothing.
        case exited(code: Int32, stderr: String, arguments: [String])
        /// `git` could not be launched at all.
        case launchFailed(String)

        public var description: String {
            switch self {
            case let .exited(code, stderr, arguments):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "git \(arguments.joined(separator: " ")) exited \(code)"
                    + (detail.isEmpty ? "" : ": \(detail)")
            case let .launchFailed(message):
                return "could not launch git: \(message)"
            }
        }
    }

    public struct Output: Sendable {
        public let standardOutput: Data
        public let standardError: String
        public let exitCode: Int32

        /// stdout decoded as UTF-8, lossily. Git paths may contain arbitrary
        /// bytes, so callers that must preserve them use `standardOutput`.
        public var text: String {
            String(decoding: standardOutput, as: UTF8.self)
        }

        /// stdout split into lines with the trailing empty element removed.
        public var lines: [String] {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .dropLast(while: { $0.isEmpty })
                .map(String.init)
        }
    }

    /// Absolute path to the git executable. Absolute so `PATH` cannot redirect
    /// us to something else.
    public let executablePath: String

    public init(executablePath: String = "/usr/bin/git") {
        self.executablePath = executablePath
    }

    /// Runs `git` and returns its output, throwing on a non-zero exit.
    ///
    /// - Parameters:
    ///   - arguments: arguments after the executable, without a leading "git".
    ///   - workingDirectory: passed via `-C`, so the process CWD is untouched.
    ///   - standardInput: written to stdin, then closed.
    ///   - extraEnvironment: merged over the base environment.
    @discardableResult
    public func run(
        _ arguments: [String],
        workingDirectory: String? = nil,
        standardInput: Data? = nil,
        extraEnvironment: [String: String] = [:]
    ) throws -> Output {
        let result = try capture(
            arguments,
            workingDirectory: workingDirectory,
            standardInput: standardInput,
            extraEnvironment: extraEnvironment
        )
        guard result.exitCode == 0 else {
            throw Failure.exited(
                code: result.exitCode,
                stderr: result.standardError,
                arguments: arguments
            )
        }
        return result
    }

    /// Runs `git` and returns its output whatever the exit code.
    ///
    /// Some git commands use exit status as information rather than failure —
    /// `diff --quiet` and `merge-base --is-ancestor`, for instance — so callers
    /// that expect that use this and inspect `exitCode` themselves.
    public func capture(
        _ arguments: [String],
        workingDirectory: String? = nil,
        standardInput: Data? = nil,
        extraEnvironment: [String: String] = [:]
    ) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)

        var argv: [String] = []
        if let workingDirectory {
            // -C rather than currentDirectoryURL: git resolves it the way the
            // rest of git does, including for worktrees.
            argv += ["-C", workingDirectory]
        }
        argv += arguments
        process.arguments = argv
        process.environment = Self.environment(adding: extraEnvironment)

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = standardInput == nil ? FileHandle.nullDevice : Pipe()

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        if let standardInput, let inPipe = process.standardInput as? Pipe {
            inPipe.fileHandleForWriting.write(standardInput)
            inPipe.fileHandleForWriting.closeFile()
        }

        // Read both pipes concurrently. Reading one to completion first
        // deadlocks as soon as the other fills its buffer, which shows up only
        // on large output — exactly the case a small test would miss.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "co.sstools.switchyard.gitprocess", attributes: .concurrent)
        let lock = NSLock()

        group.enter()
        queue.async {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); outData = d; lock.unlock()
            group.leave()
        }
        group.enter()
        queue.async {
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData = d; lock.unlock()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()

        return Output(
            standardOutput: outData,
            standardError: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    /// The environment every invocation runs under.
    ///
    /// `yard` is never interactive: no editor, no pager, no credential prompt
    /// that blocks forever. A command that would need one must fail with a
    /// structured error instead of hanging a headless agent run.
    static func environment(adding extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // Nothing may spawn an editor. `yard commit` without -m is an error,
        // not a prompt.
        env["GIT_EDITOR"] = "false"
        env["GIT_SEQUENCE_EDITOR"] = "false"
        env["EDITOR"] = "false"
        env["VISUAL"] = "false"

        // No pager, ever. A pager on a pipe would hang the caller.
        env["GIT_PAGER"] = "cat"
        env["PAGER"] = "cat"

        // No interactive credential or SSH prompts.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = ""
        env["SSH_ASKPASS"] = ""

        // Stable, parseable output regardless of the user's locale.
        env["LC_ALL"] = "C"

        // Lets the reference-transaction hook skip our own ref writes (#0042).
        env[markerVariable] = "1"

        for (key, value) in extra { env[key] = value }
        return env
    }
}

private extension Array {
    /// Drops trailing elements matching a predicate.
    func dropLast(while predicate: (Element) -> Bool) -> ArraySlice<Element> {
        var end = endIndex
        while end > startIndex, predicate(self[index(before: end)]) {
            end = index(before: end)
        }
        return self[startIndex..<end]
    }
}
