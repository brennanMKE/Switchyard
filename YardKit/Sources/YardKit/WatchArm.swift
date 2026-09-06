// WatchArm.swift — the `switchyard watch` arm (#0058)

import Foundation

/// The process-global SIGINT latch. A C signal handler may only touch
/// memory: this plain `Int32` store is the whole handler body. `nonisolated(
/// unsafe)` because a signal can arrive on any thread while the poller
/// reads it — a benign torn-read-free single-word store, the standard shape
/// for a signal latch (Rule 7c's concern is asserting on time, which nothing
/// here does; the flag is only ever read as set-or-not).
nonisolated(unsafe) internal var watchSIGINTReceived: Int32 = 0

/// The `signal(SIGINT)` handler body: latch the flag, nothing else.
/// Internal so the wiring test can exercise the latch directly — the test
/// runner blocks SIGINT on its own threads, so in-process delivery cannot
/// be observed there; the OS-delivery path is covered by the round-2
/// subprocess test, where the CLI owns its own signal disposition.
internal func watchSIGINTHandler(_ signal: Int32) {
    watchSIGINTReceived = 1
}

/// Installs the SIGINT latch handler. Called by `WatchArm.run` before it
/// connects; internal so the wiring test can install it, raise the signal
/// in-process, and observe the latch flip without a subprocess.
internal func watchInstallSIGINTHandler() {
    signal(SIGINT, watchSIGINTHandler)
}

/// The CLI-exported client the app pushes watch events to (#0058).
///
/// Exported by setting `NSXPCConnection.exportedInterface`/
/// `exportedObject` before the connection resumes — the reverse direction of
/// the CLI's other XPC use, where the CLI holds proxies to the app's
/// exported `AppService`. The app receives a proxy typed as
/// `WatchClientProtocol` as `performWatch`'s `client` argument and calls
/// these methods per event. XPC invokes the exported object off the
/// caller's queue; every closure this sink forwards to is `@Sendable`, and
/// the line buffer it lands in is lock-guarded, so arrival order is write
/// order.
final class WatchEventSink: NSObject, WatchClientProtocol, @unchecked Sendable {
    private let onEvent: @Sendable (Data) -> Void
    private let onSessionEnded: @Sendable (Data) -> Void

    init(
        onEvent: @escaping @Sendable (Data) -> Void,
        onSessionEnded: @escaping @Sendable (Data) -> Void
    ) {
        self.onEvent = onEvent
        self.onSessionEnded = onSessionEnded
    }

    func event(_ data: Data) {
        onEvent(data)
    }

    func sessionEnded(reason: Data) {
        onSessionEnded(reason)
    }
}

/// Where event lines go before the arm returns: either straight to the
/// caller's sink as each arrives (production — the stream contract is
/// "as it arrives", so buffering until session end is wrong), or into the
/// buffer this arm returns as stdout when no sink was injected (the
/// established arm return shape, what tests assert on).
private final class WatchLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var arrivals = 0
    private let emit: (@Sendable (String) -> Void)?

    init(emit: (@Sendable (String) -> Void)?) {
        self.emit = emit
    }

    func append(_ line: String) {
        let written: (@Sendable () -> Void)? = lock.withLock {
            arrivals += 1
            if let emit {
                return { emit(line + "\n") }
            }
            lines.append(line)
            return nil
        }
        written?()
    }

    /// How many lines have arrived so far, whichever sink they went to.
    /// The post-reply drain (see ``WatchArm/drainInFlight``) watches this to
    /// wait out the events still in flight behind the end reply.
    var arrivalCount: Int {
        lock.withLock { arrivals }
    }

    /// Everything buffered, each line newline-terminated; empty when a live
    /// sink was injected (those lines were already written).
    func flushed() -> String {
        let joined: String = lock.withLock {
            let joined = lines.map { $0 + "\n" }.joined()
            lines.removeAll()
            return joined
        }
        return joined
    }
}

/// The `switchyard watch [--repository path] [--timeout seconds]` arm: join
/// a long-lived session and print every event as newline-delimited JSON on
/// stdout as it arrives.
///
/// **Remote over XPC, like every M4 interactive command.** The arm connects
/// with `launchIfNeeded: false` and exits 3 when the app is down — never a
/// local fallback, because a stream of app-side events cannot exist without
/// the app. `dispatch` intercepts the arm before the generic `perform`
/// path, exactly as it does for `review`, `ask`, and `resolve`.
///
/// **The session shape** is the reverse XPC direction: the arm EXPORTS a
/// `WatchEventSink` (set on the connection before resume), sends
/// `performWatch`, and races three completions against each other — the
/// session reply (the app's one end-of-session reply, hours later if that
/// is how long it takes), the `--timeout` deadline, and the SIGINT latch.
/// Whichever wins, the connection closes INSIDE the race body: a session
/// the arm detached from has a pending reply continuation that only the
/// connection's error handler can resume, so the connection must be closed
/// before the task group's scope-exit await, not after it.
///
/// **Exit codes.** 0 a clean end — the app replied detached/timedOut, the
/// CLI's own `--timeout` deadline fired, or Ctrl-C latched; 1 usage; 3 the
/// app is down; 5 the app terminated the session (`appShutdown` reply) or
/// quit mid-stream (the connection's error path). There is no exit 10: a
/// watch timeout is a detach, not a failed wait — the events already
/// streamed are the result.
public enum WatchArm {

    /// The subcommand name, as registered in `CommandRegistry.all`.
    static let commandName = "watch"

    /// The CLI-side backstop over `--timeout`. The app arms the same
    /// duration (the request carries `timeoutSeconds`), so its typed
    /// `.timedOut` reply normally beats this backstop; the margin exists so
    /// a lost reply still cannot hang the CLI past its contract. A
    /// parameter of `run` (defaulting to this constant) rather than mutable
    /// static state, the way `AskArm` does it: the suite passes a large
    /// value where it needs the app's timer to win deterministically, and
    /// there is no shared mutable state to make concurrency-safe.
    static let backstopMargin: Duration = .seconds(5)

    /// Production event-line sink: write each line the moment it arrives.
    /// Public because `dispatch`'s default argument references it.
    public static let standardOutputSink: @Sendable (String) -> Void = { text in
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    /// One accepted invocation, already validated.
    struct Invocation: Equatable {
        var repositoryPath: String?
        var timeoutSeconds: Int?
    }

    enum ParseOutcome: Equatable {
        case run(Invocation)
        case refused(String)
    }

    /// Pure argv parsing, in the same spirit as `AskArm.parseInvocation`:
    /// decide everything from `arguments` before any I/O happens.
    ///
    /// - The repository path is positional — at most one. Absent means the
    ///   all-repositories selector.
    /// - `--timeout <seconds>` — optional, a positive integer; absent means
    ///   until detached.
    static func parseInvocation(_ arguments: [String]) -> ParseOutcome {
        guard arguments.first == commandName else {
            return .refused("not a watch invocation")
        }

        var repositoryPath: String?
        var timeoutSeconds: Int?

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--timeout":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    return .refused("--timeout requires a positive integer of seconds")
                }
                timeoutSeconds = value
            default:
                if argument.hasPrefix("-") {
                    return .refused("unknown flag '\(argument)'")
                }
                if repositoryPath != nil {
                    return .refused("pass at most one repository path argument")
                }
                repositoryPath = argument
            }
            index += 1
        }

        return .run(Invocation(repositoryPath: repositoryPath, timeoutSeconds: timeoutSeconds))
    }

    /// Runs the arm: parse, connect, export the client, stream, map the end.
    ///
    /// - Parameters:
    ///   - arguments: the process arguments after the executable name.
    ///   - workingDirectory: the CLI process's working directory, threaded
    ///     for parity with the other arms; the watch request names its scope
    ///     itself (`repositoryPath`), so nothing resolves from it today.
    ///   - connect: injectable so the arm-level tests run without a broker,
    ///     launch agent, or app. Receives the sink the arm built —
    ///     production passes it as `AppConnection.connect`'s
    ///     `exportedClient`, which sets it on the connection before resume.
    ///     Production uses `launchIfNeeded: false` — watch never launches
    ///     the app (the M4 exit criterion).
    ///   - emit: the live line sink. Nil (tests) buffers lines into the
    ///     returned stdout instead — the established arm return shape.
    ///     Production passes `standardOutputSink`, making each line hit
    ///     stdout the moment its event arrives.
    ///   - shouldDetach: polled between events; true ends the session with
    ///     exit 0 (the SIGINT detach). Nil means the production signal
    ///     latch. Tests inject a closure so the detach is deterministic.
    ///   - detachPollInterval: how often `shouldDetach` is consulted.
    ///     Production never overrides this.
    ///   - backstopMargin: the wait over `--timeout` before the CLI
    ///     detaches on its own (see `backstopMargin`). Production never
    ///     passes this.
    static func run(
        arguments: [String],
        workingDirectory: String,
        connect: (any WatchClientProtocol) async throws -> AppConnection = {
            try await AppConnection.connect(launchIfNeeded: false, exportedClient: $0)
        },
        emit: (@Sendable (String) -> Void)? = nil,
        shouldDetach: (@Sendable () -> Bool)? = nil,
        detachPollInterval: Duration = .milliseconds(100),
        backstopMargin: Duration = WatchArm.backstopMargin
    ) async -> (stdout: String, stderr: String, exitCode: ExitCode) {
        watchInstallSIGINTHandler()
        switch parseInvocation(arguments) {
        case .refused(let message):
            return failureResult(.usage, message, .usage)
        case .run(let invocation):
            return await stream(
                invocation: invocation,
                connect: connect,
                emit: emit,
                shouldDetach: shouldDetach,
                detachPollInterval: detachPollInterval,
                backstopMargin: backstopMargin)
        }
    }

    private static func stream(
        invocation: Invocation,
        connect: (any WatchClientProtocol) async throws -> AppConnection,
        emit: (@Sendable (String) -> Void)?,
        shouldDetach: (@Sendable () -> Bool)?,
        detachPollInterval: Duration,
        backstopMargin: Duration
    ) async -> (stdout: String, stderr: String, exitCode: ExitCode) {
        let lines = WatchLineBuffer(emit: emit)
        let sink = WatchEventSink(
            onEvent: { data in
                lines.append(String(decoding: data, as: UTF8.self))
            },
            onSessionEnded: { _ in
                // The end reason reaches the arm through the session reply —
                // the authoritative channel, which the store guarantees
                // fires once. The push is observed and dropped here.
            })

        let app: AppConnection
        do {
            app = try await connect(sink)
        } catch let error as AppConnectionError {
            return connectionFailure(exitCode: error.exitCode, message: String(describing: error))
        } catch {
            return failureResult(.requestFailed, String(describing: error), .requestFailed)
        }

        let request = WatchRequest(
            repositoryPath: invocation.repositoryPath,
            timeoutSeconds: invocation.timeoutSeconds)
        guard let requestData = try? JSONEncoder().encode(request) else {
            app.close()
            return failureResult(.requestFailed, "Failed to encode the watch request.", .requestFailed)
        }

        enum SessionEnd: Sendable {
            case replied(Data)
            case deadlineReached
            case detached
        }

        let detach: @Sendable () -> Bool = shouldDetach ?? { watchSIGINTReceived != 0 }
        let outcome: SessionEnd
        do {
            outcome = try await withThrowingTaskGroup(of: SessionEnd.self) { group in
                group.addTask {
                    let reasonData = try await app.performWatch(request: requestData, client: sink)
                    return .replied(reasonData)
                }
                if let seconds = invocation.timeoutSeconds {
                    group.addTask {
                        try await Task.sleep(
                            for: .seconds(Double(seconds)) + backstopMargin)
                        return .deadlineReached
                    }
                }
                group.addTask {
                    while !detach() {
                        try await Task.sleep(for: detachPollInterval)
                    }
                    return .detached
                }

                let first = try await group.next()!
                group.cancelAll()
                if case .replied = first {
                    // The connection stays open through the drain — closing
                    // it is what would drop the events in flight.
                    await drainInFlight(lines)
                }
                // Inside the body, not a defer: the scope-exit await below
                // must not wait on the losing session task, whose pending
                // reply continuation is only resumed by the error handler
                // this close() triggers.
                app.close()
                return first
            }
        } catch let error as AppConnectionError {
            app.close()
            return connectionFailure(exitCode: error.exitCode, message: String(describing: error))
        } catch {
            app.close()
            return failureResult(.requestFailed, String(describing: error), .requestFailed)
        }

        switch outcome {
        case .replied(let reasonData):
            return renderEnd(reasonData, lines: lines)
        case .deadlineReached, .detached:
            // A self-detach is a clean end by definition: the events already
            // streamed are the result, and exit 0 says the session ended on
            // the CLI's terms.
            return (lines.flushed(), "", .success)
        }
    }

    /// Waits out the events still in flight behind the session-end reply.
    ///
    /// XPC delivers one-way pushes asynchronously, and under a burst the end
    /// reply can overtake event pushes made shortly before it — closing the
    /// connection the moment the reply lands would then silently drop every
    /// event still marshalling, violating the no-drop criterion. After the
    /// reply, the arrival count is watched until no new event has arrived
    /// for `quiet` (long against real delivery latencies, which are
    /// microseconds; short against a human), or until `bound` elapses,
    /// whichever comes first. Both are constants of the design, not
    /// deadlines events are promised to meet.
    private static func drainInFlight(
        _ lines: WatchLineBuffer,
        quiet: Duration = .milliseconds(150),
        bound: Duration = .seconds(2)
    ) async {
        var settled = lines.arrivalCount
        let deadline = ContinuousClock.now + bound
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: quiet)
            let now = lines.arrivalCount
            if now == settled { return }
            settled = now
        }
    }

    /// Maps the app's session-end reply to the process result. The reply is
    /// `WatchEndReason` bytes on every normal end, or a failure envelope
    /// when the request could not be served at all.
    private static func renderEnd(
        _ reasonData: Data,
        lines: WatchLineBuffer
    ) -> (stdout: String, stderr: String, exitCode: ExitCode) {
        let decoder = JSONDecoder()
        if let reason = try? decoder.decode(WatchEndReason.self, from: reasonData) {
            switch reason {
            case .detached, .timedOut:
                return (lines.flushed(), "", .success)
            case .appShutdown:
                // Events streamed before the end are still the stream —
                // flush them, then the failure envelope as the final line.
                return failureResult(
                    .sessionTerminated,
                    "the app terminated the watch session",
                    .sessionTerminated,
                    prefixedBy: lines.flushed())
            }
        }
        if let failure = try? decoder.decode(EnvelopeFail.self, from: reasonData) {
            let human = "[error] \(failure.error.code.rawValue): \(failure.error.message)\n"
            return (lines.flushed() + jsonString(failure), human, failure.error.matchExitCode())
        }
        return failureResult(
            .requestFailed,
            "the app replied with something that could not be decoded as a watch session end",
            .requestFailed,
            prefixedBy: lines.flushed())
    }

    // MARK: - Result shapers (same shapes as Dispatch.connectionFailureResult)

    private static func failureResult(
        _ code: EnvelopeErrorCode,
        _ message: String,
        _ exitCode: ExitCode,
        prefixedBy events: String = ""
    ) -> (stdout: String, stderr: String, exitCode: ExitCode) {
        let env = EnvelopeFail(code: code, message: message)
        let human = "[error] \(env.error.code.rawValue): \(env.error.message)\n"
        return (events + jsonString(env), human, exitCode)
    }

    private static func connectionFailure(
        exitCode: ExitCode,
        message: String
    ) -> (stdout: String, stderr: String, exitCode: ExitCode) {
        // `ExitCode.codeLabel` and `EnvelopeErrorCode.rawValue` are the same
        // closed set of strings (SchemaGoldenTests pins the agreement), so
        // this round-trip cannot land on the wrong code.
        let code = EnvelopeErrorCode(rawValue: exitCode.codeLabel) ?? .requestFailed
        return failureResult(code, message, exitCode)
    }
}
