// GitProcess.swift

import Dispatch
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
        /// The child was still running when its deadline expired, and was
        /// terminated. Distinct from `.exited`: nothing about its status is a
        /// git exit code -- a SIGKILLed child reports 9, which collides with
        /// `ExitClass.signingFailed`'s raw value. Callers that care why the
        /// timeout mattered classify it themselves; this case only reports
        /// that it happened.
        case timedOut(after: Duration, arguments: [String])

        public var description: String {
            switch self {
            case let .exited(code, stderr, arguments):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "git \(arguments.joined(separator: " ")) exited \(code)"
                    + (detail.isEmpty ? "" : ": \(detail)")
            case let .launchFailed(message):
                return "could not launch git: \(message)"
            case let .timedOut(after, arguments):
                return "git \(arguments.joined(separator: " ")) did not finish within \(after) "
                    + "and was terminated"
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

    /// The bound applied to `CommitCreate`'s `git commit` and, when signing
    /// could be in effect, `Fixup`'s `git rebase --autosquash` — the two
    /// places a signing helper's own UI (pinentry, an ssh-agent prompt) can
    /// block a `GitProcess` invocation indefinitely, none of it governed by
    /// the `GIT_TERMINAL_PROMPT=0` family of environment variables (#0163).
    ///
    /// This is a guess about human patience, not a measurement: long enough
    /// that a person typing a passphrase is not cut off mid-entry, short
    /// enough that a headless invocation with no display for pinentry to
    /// attach to does not hang the caller for a useful multiple of that. Not
    /// used anywhere else -- `run`/`capture` default `timeout` to `nil`
    /// (today's unbounded wait) so a clone or fetch is never cut short by a
    /// blanket default (guide §11 decision 18, option 3, rejected).
    public static let signingTimeout: Duration = .seconds(30)

    /// How long `waitWithDeadline` gives a child to react to `terminate()`
    /// (`SIGTERM`) before escalating to `SIGKILL`. Measured 2026-08-17: an
    /// ordinary child exits within ~1s of `terminate()`; a child that traps
    /// and ignores `SIGTERM` needs the `SIGKILL` that follows this grace
    /// period. Not `public` -- callers choose their own `timeout`, but the
    /// escalation shape is this type's own concern.
    private static let terminationGracePeriod: Duration = .seconds(1)

    /// How often `waitWithDeadline` polls `Process.isRunning` while waiting
    /// for either the deadline or the grace period to elapse.
    private static let pollIntervalMicroseconds: UInt32 = 10_000

    /// Runs `git` and returns its output, throwing on a non-zero exit.
    ///
    /// - Parameters:
    ///   - arguments: arguments after the executable, without a leading "git".
    ///   - workingDirectory: passed via `-C`, so the process CWD is untouched.
    ///   - standardInput: written to stdin, then closed.
    ///   - extraEnvironment: merged over the base environment.
    ///   - timeout: when non-`nil`, the child is terminated (and reported as
    ///     `Failure.timedOut`) if it has not exited by this deadline. `nil`
    ///     (the default) is today's behavior: `waitUntilExit()` with no
    ///     bound. Only signing-adjacent callers pass a value -- see
    ///     `signingTimeout`.
    @discardableResult
    public func run(
        _ arguments: [String],
        workingDirectory: String? = nil,
        standardInput: Data? = nil,
        extraEnvironment: [String: String] = [:],
        timeout: Duration? = nil
    ) throws -> Output {
        let result = try capture(
            arguments,
            workingDirectory: workingDirectory,
            standardInput: standardInput,
            extraEnvironment: extraEnvironment,
            timeout: timeout
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
    ///
    /// - Parameter timeout: see `run(_:workingDirectory:standardInput:
    ///   extraEnvironment:timeout:)`. When the deadline expires this throws
    ///   `Failure.timedOut` rather than returning an `Output` -- unlike a
    ///   plain non-zero exit, a timeout is never information a caller reads
    ///   from `exitCode`.
    public func capture(
        _ arguments: [String],
        workingDirectory: String? = nil,
        standardInput: Data? = nil,
        extraEnvironment: [String: String] = [:],
        timeout: Duration? = nil
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

        // Drain stdout on a background queue rather than reading it
        // synchronously here. A child blocked on its own prompt (pinentry,
        // an ssh-agent dialog) writes nothing and closes nothing, so a
        // synchronous `readDataToEndOfFile()` would block forever and the
        // bounded wait below would never get a chance to act. stderr is
        // already going to a file, so there is no second pipe to manage.
        let drain = StdoutDrain(pipe: outPipe)
        drain.start()

        if let timeout {
            try Self.waitWithDeadline(process, timeout: timeout, arguments: arguments)
        } else {
            process.waitUntilExit()
        }
        let outData = drain.finish()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()

        return Output(
            standardOutput: outData,
            standardError: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    /// Waits for `process` up to `timeout`, then escalates: `terminate()`
    /// (`SIGTERM`), a short grace period, then `kill(pid, SIGKILL)` if it is
    /// still alive. `waitUntilExit()` runs last either way, to reap -- it
    /// returns promptly once the child is actually dead, which by the end of
    /// escalation it always is (measured 2026-08-17, #0163).
    ///
    /// Throws `Failure.timedOut` when the deadline expired; returns normally
    /// when the process exited on its own within it.
    private static func waitWithDeadline(
        _ process: Process, timeout: Duration, arguments: [String]
    ) throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning, clock.now < deadline {
            usleep(pollIntervalMicroseconds)
        }
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }

        // Deadline expired and the child is still alive. Escalate: SIGTERM,
        // a grace period, then SIGKILL if it ignored SIGTERM.
        process.terminate()
        let graceDeadline = clock.now.advanced(by: terminationGracePeriod)
        while process.isRunning, clock.now < graceDeadline {
            usleep(pollIntervalMicroseconds)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        throw Failure.timedOut(after: timeout, arguments: arguments)
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

/// Reads a pipe's read end to EOF on a background queue.
///
/// `capture` cannot read stdout synchronously before waiting on the process:
/// a child blocked on its own prompt keeps its stdout pipe open with nothing
/// written and no EOF, so a synchronous `readDataToEndOfFile()` would block
/// forever and `waitWithDeadline` would never get a chance to act. Reading on
/// a separate queue lets that deadline loop run concurrently; the read
/// finishes on its own shortly after the process dies, because that is when
/// the pipe's write end closes. `@unchecked Sendable`: `result` is written
/// once, on the background queue, before `semaphore.signal()`, and read only
/// after `semaphore.wait()` returns on the caller's thread -- the semaphore
/// is the synchronization the compiler cannot see.
private final class StdoutDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let semaphore = DispatchSemaphore(value: 0)
    private var result = Data()

    init(pipe: Pipe) {
        self.handle = pipe.fileHandleForReading
    }

    func start() {
        DispatchQueue.global(qos: .utility).async {
            self.result = self.handle.readDataToEndOfFile()
            self.semaphore.signal()
        }
    }

    /// Blocks until the read has completed and returns everything it read.
    func finish() -> Data {
        semaphore.wait()
        return result
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
