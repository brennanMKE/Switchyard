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
        ///
        /// `terminationStatus` is the child's `Process.terminationStatus`
        /// after `waitWithDeadline`'s escalation finished -- 15 (`SIGTERM`)
        /// when `terminate()` alone ended it within the grace period, 9
        /// (`SIGKILL`) when it did not and the escalation had to finish the
        /// job. Measured 2026-08-17, #0239: this is what distinguishes "the
        /// ordinary case" from "the child trapped SIGTERM and needed the
        /// escalation this type exists for" without reading a clock.
        case timedOut(after: Duration, arguments: [String], terminationStatus: Int32)

        public var description: String {
            switch self {
            case let .exited(code, stderr, arguments):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "git \(arguments.joined(separator: " ")) exited \(code)"
                    + (detail.isEmpty ? "" : ": \(detail)")
            case let .launchFailed(message):
                return "could not launch git: \(message)"
            case let .timedOut(after, arguments, terminationStatus):
                let cause = terminationStatus == SIGKILL
                    ? "ignored SIGTERM and had to be killed (SIGKILL)"
                    : "was terminated (signal \(terminationStatus))"
                return "git \(arguments.joined(separator: " ")) did not finish within \(after) "
                    + "and \(cause)"
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
    ///   - extraEnvironment: merged over the base environment. **`Process` on
    ///     Darwin normalizes non-ASCII environment *values* from NFC to NFD
    ///     as they cross the exec boundary** -- measured independently
    ///     (#0335) with a precomposed `"Café Élodie"`: the UTF-8 bytes set
    ///     here, `67 97 102 195 169 32 195 137 108 111 100 105 101` (13
    ///     bytes), are read back by the child as `67 97 102 101 204 129 32
    ///     69 204 129 108 111 100 105 101` (15 bytes) -- `é` (`195 169`)
    ///     arrives decomposed as `e` + U+0301 (`101 204 129`), and likewise
    ///     for `É`. **Process *arguments* are not affected** -- the same
    ///     string passed as an argument round-trips exactly, which is the
    ///     workaround: prefer an argument (`--author=`, for instance) over
    ///     an environment value for any non-ASCII string. `GitProcess` does
    ///     not normalize values on the way in or out; see
    ///     `GitProcessTests.extraEnvironmentNonASCIIValueArrivesNFDNormalized`,
    ///     which pins this as current behaviour rather than a fix.
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
    /// - Parameters:
    ///   - extraEnvironment: see `run(_:workingDirectory:standardInput:
    ///     extraEnvironment:timeout:)` -- the same NFD-normalization trap
    ///     applies here, since `run` calls this to do the actual work.
    ///   - timeout: see `run(_:workingDirectory:standardInput:
    ///     extraEnvironment:timeout:)`. When the deadline expires this throws
    ///     `Failure.timedOut` rather than returning an `Output` -- unlike a
    ///     plain non-zero exit, a timeout is never information a caller reads
    ///     from `exitCode`.
    public func capture(
        _ arguments: [String],
        workingDirectory: String? = nil,
        standardInput: Data? = nil,
        extraEnvironment: [String: String] = [:],
        timeout: Duration? = nil
    ) throws -> Output {
        let prepared = try prepare(
            arguments,
            workingDirectory: workingDirectory,
            standardInput: standardInput,
            extraEnvironment: extraEnvironment
        )
        defer {
            try? prepared.stderrHandle.close()
            try? FileManager.default.removeItem(at: prepared.stderrURL)
        }

        do {
            try prepared.process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        if let standardInput, let inPipe = prepared.process.standardInput as? Pipe {
            inPipe.fileHandleForWriting.write(standardInput)
            inPipe.fileHandleForWriting.closeFile()
        }

        let outData: Data
        if let timeout {
            // A bounded wait needs stdout drained concurrently, not after:
            // a child blocked on its own prompt (pinentry, an ssh-agent
            // dialog) writes nothing and closes nothing, so a synchronous
            // `readDataToEndOfFile()` below would block forever and
            // `waitWithDeadline` would never get a chance to act. This
            // branch is reached only by the two signing-adjacent call
            // sites `GitProcess.signingTimeout` documents (#0163), so the
            // extra thread and semaphore per call are affordable here —
            // unlike the `else` branch, which every other `GitProcess`
            // call in the package still takes, unconditionally, on every
            // invocation.
            let drain = StdoutDrain(pipe: prepared.outPipe)
            drain.start()
            try Self.waitWithDeadline(prepared.process, timeout: timeout, arguments: arguments)
            outData = drain.finish()
        } else {
            // Drain stdout to completion, then wait. stderr is already going
            // to a file, so there is no second pipe to deadlock against and
            // no thread to block.
            //
            // Draining two pipes needs either concurrent reads or a run
            // loop, and blocking on a DispatchGroup (or a semaphore, as the
            // timeout branch above does) starves Swift concurrency's
            // cooperative thread pool -- measured #0163 round 1: making
            // every call take that path, not just the timeout one, took the
            // full suite from 38s to over 12 minutes. A file has no buffer
            // limit, so one pipe plus one file removes the problem rather
            // than managing it, and this is the unconditional path every
            // non-timeout call takes -- which is nearly all of them.
            outData = prepared.outPipe.fileHandleForReading.readDataToEndOfFile()
            prepared.process.waitUntilExit()
        }
        let errData = (try? Data(contentsOf: prepared.stderrURL)) ?? Data()

        return Output(
            standardOutput: outData,
            standardError: String(decoding: errData, as: UTF8.self),
            exitCode: prepared.process.terminationStatus
        )
    }

    /// A configured-but-unlaunched process plus the side channels around it:
    /// the stdout pipe a caller must drain, and the temporary stderr file the
    /// caller must close and delete.
    private struct Prepared {
        let process: Process
        let outPipe: Pipe
        let stderrURL: URL
        let stderrHandle: FileHandle
    }

    /// Builds what both `capture` paths run: the argument vector (the working
    /// directory prefixed as `-C`), the sanitized environment, the stdout
    /// pipe, and stderr routed to a temporary file.
    ///
    /// stderr goes to a file, not a pipe — **this is the deadlock guard**:
    /// draining two pipes needs either concurrent reads or a run loop, and
    /// blocking on a DispatchGroup starves Swift concurrency's cooperative
    /// thread pool — which deadlocks the whole suite once swift-testing runs
    /// tests in parallel. A file has no buffer limit, so one pipe plus one
    /// file removes the problem rather than managing it. The async twin of
    /// this method drains its single pipe with `readabilityHandler`, so it
    /// never has the two-pipe problem either.
    private func prepare(
        _ arguments: [String],
        workingDirectory: String?,
        standardInput: Data?,
        extraEnvironment: [String: String]
    ) throws -> Prepared {
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

        let outPipe = Pipe()
        process.standardOutput = outPipe

        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        guard let errHandle = try? FileHandle(forWritingTo: errURL) else {
            throw Failure.launchFailed("could not open a stderr buffer")
        }
        process.standardError = errHandle
        process.standardInput = standardInput == nil ? FileHandle.nullDevice : Pipe()

        return Prepared(
            process: process,
            outPipe: outPipe,
            stderrURL: errURL,
            stderrHandle: errHandle
        )
    }

    // MARK: - The non-blocking path (#0344)

    /// Async twin of `run(_:workingDirectory:standardInput:extraEnvironment:
    /// timeout:)`, for callers already on Swift concurrency's cooperative
    /// pool (#0344). Same arguments, same `Failure` values, same `Output`;
    /// the difference is only *where the thread sits* while `git` runs: the
    /// synchronous entry points block the calling thread for the subprocess's
    /// lifetime, this one suspends the calling task instead, so a
    /// cooperative-pool thread is held for microseconds per call rather than
    /// for the whole subprocess. Synchronous callers keep the synchronous
    /// overloads -- this adds a path, it does not replace one.
    @discardableResult
    public func run(
        _ arguments: [String],
        workingDirectory: String? = nil,
        standardInput: Data? = nil,
        extraEnvironment: [String: String] = [:],
        timeout: Duration? = nil
    ) async throws -> Output {
        let result = try await capture(
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

    /// Async twin of `capture(_:workingDirectory:standardInput:
    /// extraEnvironment:timeout:)` (#0344): runs `git` and returns its output
    /// whatever the exit code, without holding a cooperative-pool thread for
    /// the subprocess's lifetime. Same `Output`, same `Failure` values, same
    /// argument and environment construction (both paths share `prepare`),
    /// same timeout semantics.
    ///
    /// How the thread is released:
    ///
    /// - **stdout** is drained by `readabilityHandler`, which Foundation
    ///   invokes on its own queue as data arrives and once more with empty
    ///   data at EOF. stderr still goes to a temporary file (`prepare`'s
    ///   deadlock guard), so stdout is the only pipe and there is no
    ///   two-pipe ordering problem to manage.
    /// - **completion** requires *both* stdout EOF and process exit, because
    ///   either can arrive last. Whichever event observes the second
    ///   condition builds the `Output` and funnels it through
    ///   `ResumeOnce` (modeled on the one in `BrokerConnection`), which
    ///   guarantees the continuation is resumed exactly once no matter how
    ///   the events interleave with the timeout or cancellation below.
    /// - **timeout** is enforced by a detached watchdog task instead of
    ///   `waitWithDeadline`'s `usleep` polling loop: it sleeps until the
    ///   deadline, then runs the same escalation — `terminate()` (SIGTERM),
    ///   `terminationGracePeriod`, `kill(pid, SIGKILL)` if the child ignored
    ///   SIGTERM — reaps, and reports `Failure.timedOut` carrying the child's
    ///   `terminationStatus` (15 or 9), exactly as the synchronous path
    ///   documents (#0239). The watchdog marks the deadline expired *before*
    ///   terminating, so the killed child's exit + EOF can never report
    ///   success ahead of it — a child that had to be terminated is a
    ///   timeout, whatever its exit status, as in the synchronous path.
    /// - **cancellation** of the surrounding task terminates the child and
    ///   resumes with `CancellationError`, with the same SIGTERM-then-SIGKILL
    ///   escalation so a child that traps SIGTERM cannot outlive the caller.
    ///
    /// The handlers are installed *before* `run()`: Foundation does not
    /// invoke `terminationHandler` for a child that exited before it was
    /// set, and a fast child can exit within milliseconds of launch. Events
    /// that fire before the continuation below attaches are stored as the
    /// gate's pending result and delivered on attach.
    @discardableResult
    public func capture(
        _ arguments: [String],
        workingDirectory: String? = nil,
        standardInput: Data? = nil,
        extraEnvironment: [String: String] = [:],
        timeout: Duration? = nil
    ) async throws -> Output {
        let prepared = try prepare(
            arguments,
            workingDirectory: workingDirectory,
            standardInput: standardInput,
            extraEnvironment: extraEnvironment
        )
        let process = prepared.process
        let errURL = prepared.stderrURL
        defer {
            try? prepared.stderrHandle.close()
            try? FileManager.default.removeItem(at: errURL)
        }

        let state = AsyncCaptureState()
        let gate = ResumeOnce<Output>()

        // Both completion sources funnel through here; whichever observes
        // the last of the two conditions builds the result. Reading the
        // stderr file is safe: the child has exited by then, so its stderr
        // is final, and the `defer` above cannot have removed the file yet
        // -- this function stays suspended inside the continuation below
        // until `gate.finish` resumes it.
        let complete: @Sendable () -> Void = { [state, gate] in
            let (outData, exitCode) = state.snapshot()
            let errData = (try? Data(contentsOf: errURL)) ?? Data()
            gate.finish(.success(Output(
                standardOutput: outData,
                standardError: String(decoding: errData, as: UTF8.self),
                exitCode: exitCode
            )))
        }

        prepared.outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            let eof = chunk.isEmpty
            if eof {
                // Empty data is EOF (the write end closed); nil the handler
                // or Foundation keeps invoking it forever.
                handle.readabilityHandler = nil
            }
            if state.record(chunk: chunk, isEOF: eof) {
                complete()
            }
        }
        process.terminationHandler = { child in
            // terminationStatus is valid inside the handler -- Foundation
            // has reaped the child by the time it runs.
            if state.markExited(child.terminationStatus) {
                complete()
            }
        }

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        if let standardInput, let inPipe = process.standardInput as? Pipe {
            // Written from a dedicated thread, not the calling task's: a
            // large payload can fill the pipe and block the write, and this
            // path exists precisely so no cooperative-pool thread is held
            // while the child runs.
            nonisolated(unsafe) let writeHandle = inPipe.fileHandleForWriting
            Thread.detachNewThread {
                writeHandle.write(standardInput)
                writeHandle.closeFile()
            }
        }

        // The watchdog and the cancellation handler touch the process from
        // other threads. `Process` is not `Sendable`; every access here is a
        // status check or the escalation `waitWithDeadline` already performs
        // from a foreign thread, and the two closures never mutate it.
        nonisolated(unsafe) let childProcess = process

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Output, any Error>) in
                gate.attach(continuation)

                if let timeout {
                    Task.detached(priority: .utility) { [state, gate] in
                        try? await Task.sleep(for: timeout)
                        guard !gate.isFinished else { return }
                        // Mark the deadline expired BEFORE terminating: the
                        // killed child's exit + EOF must not be able to
                        // report success ahead of the timedOut below.
                        state.markDeadlineExpired()
                        if childProcess.isRunning { childProcess.terminate() }
                        try? await Task.sleep(for: Self.terminationGracePeriod)
                        guard !gate.isFinished else { return }
                        if childProcess.isRunning {
                            kill(childProcess.processIdentifier, SIGKILL)
                        }
                        childProcess.waitUntilExit()
                        gate.finish(.failure(Failure.timedOut(
                            after: timeout,
                            arguments: arguments,
                            terminationStatus: childProcess.terminationStatus
                        )))
                    }
                }
            }
        } onCancel: {
            if childProcess.isRunning {
                childProcess.terminate()
            }
            gate.finish(.failure(CancellationError()))
            // Same escalation the timeout path uses, so a child that traps
            // SIGTERM cannot outlive the caller that cancelled it. The gate
            // is already finished, so nothing this task does later can
            // double-resume; it only finishes the job.
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: Self.terminationGracePeriod)
                if childProcess.isRunning {
                    kill(childProcess.processIdentifier, SIGKILL)
                }
            }
        }
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
        throw Failure.timedOut(
            after: timeout, arguments: arguments, terminationStatus: process.terminationStatus)
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

    /// A dedicated `Thread`, deliberately not `DispatchQueue.global()`.
    /// `capture` runs inside one of ~1000 parallel swift-testing tests, any
    /// of which may itself be executing ON a GCD global-queue worker thread.
    /// Submitting the read to that same queue and then blocking on it in
    /// `finish()` is the textbook GCD deadlock: a pool thread waiting on
    /// another task queued on its own, now-exhausted, pool. Measured #0163
    /// round 2: with the drain on `DispatchQueue.global()`, the full suite
    /// did not finish in over ten minutes at ~0% CPU (genuinely stalled, not
    /// merely slow) even though every individual test file was fast in
    /// isolation -- exactly the shape of pool exhaustion, which only
    /// appears once enough concurrent callers are competing for the same
    /// bounded pool. A `Thread` is not drawn from any shared pool, so it
    /// cannot be blocked behind other work queued on one.
    func start() {
        Thread.detachNewThread { [self] in
            result = handle.readDataToEndOfFile()
            semaphore.signal()
        }
    }

    /// Blocks until the read has completed and returns everything it read.
    func finish() -> Data {
        semaphore.wait()
        return result
    }
}

/// Guarantees a continuation is resumed exactly once, from whichever of the
/// stdout-EOF, process-exit, timeout, or cancellation event gets there first.
/// Modeled on the `ResumeOnce` in `YardKit`'s `BrokerConnection.swift`;
/// duplicated here because `YardGit` cannot depend on `YardKit`. Unlike that
/// one, `finish` marks the gate finished even when it stashes a pending
/// result, so two events racing before `attach` cannot both stick.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var pending: Result<T, any Error>?
    private var finished = false

    /// True once a result has been delivered or is waiting to be.
    var isFinished: Bool {
        lock.withLock { finished }
    }

    func attach(_ continuation: CheckedContinuation<T, any Error>) {
        let ready: Result<T, any Error>? = lock.withLock {
            // An event can beat `attach` if the child is very fast, so a
            // result that arrived early is stashed and delivered here.
            if let pending {
                return pending
            }
            self.continuation = continuation
            return nil
        }
        if let ready {
            continuation.resume(with: ready)
        }
    }

    func finish(_ result: Result<T, any Error>) {
        let target: CheckedContinuation<T, any Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            guard let continuation else {
                pending = result
                return nil
            }
            self.continuation = nil
            return continuation
        }
        target?.resume(with: result)
    }
}

/// The async `capture`'s shared mutable state: the stdout buffer drained by
/// `readabilityHandler`, and the completion conditions. All access is
/// funnelled through one lock; `record`/`markExited` return true exactly
/// once each, on the single call that observes both conditions met, so the
/// result is built by exactly one event source.
private final class AsyncCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var sawEOF = false
    private var sawExit = false
    private var deadlineExpired = false
    private var exitStatus: Int32 = 0

    /// Appends a drained chunk; `isEOF` is true for the empty-data EOF call.
    /// Returns true exactly once, when EOF and process exit have both been
    /// recorded and the deadline has not expired.
    func record(chunk: Data, isEOF: Bool) -> Bool {
        lock.withLock {
            buffer.append(chunk)
            if isEOF { sawEOF = true }
            return sawEOF && sawExit && !deadlineExpired
        }
    }

    /// Records the child's exit status. Returns true exactly once, when EOF
    /// and process exit have both been recorded and the deadline has not
    /// expired.
    func markExited(_ status: Int32) -> Bool {
        lock.withLock {
            exitStatus = status
            sawExit = true
            return sawEOF && sawExit && !deadlineExpired
        }
    }

    /// Called by the watchdog the moment the deadline expires, *before* it
    /// terminates the child. From here the child's death (exit + EOF) can no
    /// longer report success -- a child that had to be terminated is reported
    /// as `Failure.timedOut` by the watchdog, never as a successful capture
    /// that happens to carry a signal exit status. This mirrors the
    /// synchronous `waitWithDeadline`, which throws `timedOut` whenever it
    /// had to escalate, whatever the child's status.
    func markDeadlineExpired() {
        lock.withLock { deadlineExpired = true }
    }

    /// The drained stdout and the child's exit status. Valid once either
    /// `record` or `markExited` has returned true.
    func snapshot() -> (data: Data, exitCode: Int32) {
        lock.withLock { (buffer, exitStatus) }
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

/// All three cases are repository-state failures — guide §6 code 6. `exited` is
/// git refusing an operation against this repository; `timedOut` joined them
/// with #0239 and carries the same class, because a helper that had to be
/// killed is a repository operation that could not be carried out; and
/// `launchFailed` is a 6
/// and not a 4 (request failed) because codes 1–5 and 7 are decided above
/// the engine (#0141 Decision 3) — the engine's whole vocabulary is 6/8/9,
/// and "the git operation could not be carried out" is repository semantics.
extension GitProcess.Failure: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
