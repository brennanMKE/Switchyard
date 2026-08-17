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

    /// Environment variable carrying the in-flight journal entry's id
    /// (#0221), set only on the scoped `GitProcess` `JournalCheckpoint.around`
    /// hands its body — never on the default instance. Beside
    /// `markerVariable`, not folded into it: the marker answers "is this
    /// ours", this answers "which entry", and conflating them would make an
    /// own operation that took no checkpoint indistinguishable from a
    /// foreign one. The `post-rewrite` hook reads it back to attach its
    /// mapping to the entry that was in flight when the rewrite ran.
    public static let entryVariable = "SWITCHYARD_JOURNAL_ENTRY"

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

    /// The in-flight journal entry id, exported to every subprocess this
    /// instance runs as `entryVariable` (#0221). `nil` on every `GitProcess`
    /// except the one `JournalCheckpoint.around` constructs and passes to its
    /// body — a stored property, not a mutating setter, so `GitProcess` stays
    /// a plain `Sendable` value and the scoping is exactly the lifetime of
    /// the instance the caller was handed, nothing process-global.
    public let journalEntryID: JournalEntryID?

    public init(executablePath: String = "/usr/bin/git", journalEntryID: JournalEntryID? = nil) {
        self.executablePath = executablePath
        self.journalEntryID = journalEntryID
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
        process.environment = Self.environment(
            adding: extraEnvironment, entryID: journalEntryID?.string)

        // stdout comes back through a pipe; stderr goes to a temporary file.
        //
        // Draining two pipes needs either concurrent reads or a run loop, and
        // blocking on a DispatchGroup starves Swift concurrency's cooperative
        // thread pool — which deadlocks the whole suite once swift-testing runs
        // tests in parallel. A file has no buffer limit, so one pipe plus one
        // file removes the problem rather than managing it.
        let outPipe = Pipe()
        process.standardOutput = outPipe

        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        guard let errHandle = try? FileHandle(forWritingTo: errURL) else {
            throw Failure.launchFailed("could not open a stderr buffer")
        }
        defer {
            try? errHandle.close()
            try? FileManager.default.removeItem(at: errURL)
        }
        process.standardError = errHandle
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

        // Drain stdout to completion, then wait. stderr is already going to a
        // file, so there is no second pipe to deadlock against and no thread
        // to block.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()

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
    static func environment(
        adding extra: [String: String] = [:], entryID: String? = nil
    ) -> [String: String] {
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

        // Lets the post-rewrite hook find the in-flight entry to attach its
        // mapping to (#0221). Absent -- not empty-stringed -- when no
        // checkpoint is scoping this invocation.
        if let entryID { env[entryVariable] = entryID }

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

// MARK: - §6 exit class (#0146)

/// Both cases are repository-state failures — guide §6 code 6. `exited` is
/// git refusing an operation against this repository; `launchFailed` is a 6
/// and not a 4 (request failed) because codes 1–5 and 7 are decided above
/// the engine (#0141 Decision 3) — the engine's whole vocabulary is 6/8/9,
/// and "the git operation could not be carried out" is repository semantics.
extension GitProcess.Failure: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
