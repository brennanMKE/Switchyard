// ReviewArm.swift — the `review <range|--staged> --wait` arm (#0055)

import Foundation

/// The `switchyard review <range|--staged> --wait` arm: the command that
/// pushes a diff into the app's UI, blocks on a human decision, and returns
/// the answer as structured data (#0055 — the project's centerpiece). On
/// success the payload IS the reply:
/// `{"decision":"approve"|"reject"|"amend","comments":[...],...}`.
///
/// **Remote over XPC, like every M4 interactive command.** The arm connects
/// with `launchIfNeeded: false` and exits 3 when the app is down — never a
/// silent non-interactive fallback, because an agent proceeding without the
/// human decision it was asked for would be a bug. `dispatch` intercepts the
/// arm before the generic `perform` path (which would run the review argv
/// app-side, where no CLI process is waiting for a reply).
///
/// **The blocking contract.** The CLI awaits the reply for up to
/// `--timeout + 5 s` (the backstop margin). The app-side pending store is
/// armed with exactly `--timeout`, so the typed timeout outcome normally
/// arrives first; the backstop exists so a lost reply still cannot hang the
/// CLI past its contract. The app quitting mid-review surfaces through the
/// connection's error path as exit 5 — never as a decision.
///
/// **Exit codes.** 0 approve or amend (amend is not a rejection — the patch
/// came back edited), 7 reject (same code as RemoteControl; the envelope
/// still carries the full reply and `"ok":true` — the JSON is the contract,
/// the exit code is the signal), 3 app unavailable, 5 app quit mid-review,
/// 10 the wait timed out, 4 the request was superseded by a newer review for
/// the same repository or the app could not serve it, 1 usage. The planning
/// pass named the timeout code 8 under the belief 0-7 were the taken range;
/// `blockedOnConflicts` (8) and `signingFailed` (9) predate it, so
/// ``ExitCode/timedOut`` is 10 — the first free value.
///
/// **Round 1 scope.** The wire, the blocking semantics, and the pending
/// store. The app registers the request and holds it for the human (or a
/// test double); the sheet that renders the diff and captures the decision
/// is round 2, and the app-side diff resolution is rounds 2/3.
public enum ReviewArm {

    /// The subcommand name, as registered in `CommandRegistry.all`.
    static let commandName = "review"

    /// The default `--timeout`, in seconds. **A judgement, not a measurement**
    /// (the planning pass suggested 3600): a forgotten session must not pin
    /// the app forever, but a human thinking through a large diff must not be
    /// cut off either.
    static let defaultTimeoutSeconds = 3600

    /// The CLI-side backstop margin over `--timeout`. The app-side pending
    /// review is armed with exactly `timeoutSeconds`, so the typed timeout
    /// normally beats this backstop; the margin exists so a lost or late
    /// reply still cannot hang the CLI past its contract. A parameter of
    /// `run` (defaulting to this constant) rather than mutable static state:
    /// the suite passes a small value where it needs a fast worst case, and
    /// there is no shared mutable state to make concurrency-safe.
    static let backstopMargin: Duration = .seconds(5)

    /// One accepted invocation, already validated.
    struct Invocation: Equatable {
        var staged: Bool
        var range: String?
        var timeoutSeconds: Int

        /// Only valid when the parse accepted the invocation — exactly one
        /// of `staged` / `range` holds by construction.
        var selector: ReviewSelector {
            staged ? .staged : .range(range ?? "")
        }
    }

    enum ParseOutcome: Equatable {
        case run(Invocation)
        case refused(String)
    }

    /// Pure argv parsing, in the same spirit as `HookArm.gate`: decide
    /// everything from `arguments` before any I/O happens.
    ///
    /// - `<range>` or `--staged` — exactly one, required.
    /// - `--wait` — required in this build. A non-blocking form does not
    ///   exist yet, so asking for one is a usage refusal, not a fallback.
    /// - `--timeout <seconds>` — optional, a positive integer, default 3600
    ///   (a judgement — see `defaultTimeoutSeconds`).
    static func parseInvocation(_ arguments: [String]) -> ParseOutcome {
        guard arguments.first == commandName else {
            return .refused("not a review invocation")
        }

        var staged = false
        var sawWait = false
        var range: String?
        var timeoutSeconds = defaultTimeoutSeconds

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--staged":
                staged = true
            case "--wait":
                sawWait = true
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
                if range != nil {
                    return .refused("pass exactly one range argument, or --staged")
                }
                range = argument
            }
            index += 1
        }

        guard sawWait else {
            return .refused("the blocking form requires --wait; a non-blocking form is not implemented yet")
        }
        if staged && range != nil {
            return .refused("pass either a commit range or --staged, not both")
        }
        guard staged || range != nil else {
            return .refused("pass a commit range (e.g. main..HEAD) or --staged")
        }
        return .run(Invocation(staged: staged, range: range, timeoutSeconds: timeoutSeconds))
    }

    /// Runs the arm: parse, connect, send, await the outcome, map it.
    ///
    /// - Parameters:
    ///   - arguments: the process arguments after the executable name.
    ///   - workingDirectory: the CLI process's working directory. The app
    ///     resolves the repository from it — the CLI does not link the
    ///     engine, so it cannot fill `ReviewRequest.commonDir` itself.
    ///   - connect: injectable so the dispatch-level and arm-level tests run
    ///     without a broker, launch agent, or app. Production uses
    ///     `AppConnection.connect(launchIfNeeded: false)` — review never
    ///     launches the app (the M4 exit criterion).
    ///   - backstopMargin: the wait over `--timeout` before the CLI gives up
    ///     on its own (see `backstopMargin`). Production never passes this.
    static func run(
        arguments: [String],
        workingDirectory: String,
        connect: () async throws -> AppConnection = {
            try await AppConnection.connect(launchIfNeeded: false)
        },
        backstopMargin: Duration = ReviewArm.backstopMargin
    ) async -> (stdout: String, stderr: String, exitCode: ExitCode) {
        switch parseInvocation(arguments) {
        case .refused(let message):
            return failureResult(.usage, message, .usage)
        case .run(let invocation):
            return await runBlocking(
                invocation: invocation,
                workingDirectory: workingDirectory,
                connect: connect,
                backstopMargin: backstopMargin)
        }
    }

    private static func runBlocking(
        invocation: Invocation,
        workingDirectory: String,
        connect: () async throws -> AppConnection,
        backstopMargin: Duration
    ) async -> (stdout: String, stderr: String, exitCode: ExitCode) {
        let request = ReviewRequest(
            // Resolved app-side from `workingDirectory` — see ReviewRequest.
            commonDir: "",
            selector: invocation.selector,
            timeoutSeconds: invocation.timeoutSeconds)
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        guard let requestData = try? encoder.encode(request) else {
            return failureResult(.requestFailed, "Failed to encode the review request.", .requestFailed)
        }

        do {
            let app = try await connect()
            defer { app.close() }

            let outcomeData = try await app.performReview(
                request: requestData,
                workingDirectory: workingDirectory,
                timeout: .seconds(Double(invocation.timeoutSeconds)) + backstopMargin)
            let decoder = JSONDecoder()
            if let outcome = try? decoder.decode(ReviewOutcome.self, from: outcomeData) {
                return render(outcome, timeoutSeconds: invocation.timeoutSeconds)
            }
            // The app refused the request before anything was registered
            // (undecodable bytes, unresolvable repository): it replied a
            // failure envelope instead of an outcome.
            if let failure = try? decoder.decode(EnvelopeFail.self, from: outcomeData) {
                let human = "[error] \(failure.error.code.rawValue): \(failure.error.message)\n"
                return (jsonString(failure), human, failure.error.matchExitCode())
            }
            return failureResult(
                .requestFailed,
                "the app replied with something that could not be decoded as a review outcome",
                .requestFailed)
        } catch let error as AppConnectionError {
            return connectionFailure(exitCode: error.exitCode, message: String(describing: error))
        } catch let error as CLIError {
            // The CLI's own backstop fired before any outcome arrived. From
            // the agent's side this is the same fact as the store's typed
            // timeout: no decision within the wait. Exit 10, not 2.
            if case .timedOut = error {
                return failureResult(
                    .timedOut,
                    "no review decision arrived within \(invocation.timeoutSeconds)s",
                    .timedOut)
            }
            return connectionFailure(exitCode: error.exitCode, message: String(describing: error))
        } catch {
            return failureResult(.requestFailed, String(describing: error), .requestFailed)
        }
    }

    /// Maps the app's typed outcome to the process result.
    private static func render(
        _ outcome: ReviewOutcome,
        timeoutSeconds: Int
    ) -> (stdout: String, stderr: String, exitCode: ExitCode) {
        switch outcome {
        case .decided(let reply):
            // The wire contract from the issue: the payload is the reply.
            let json = jsonString(Envelope(result: EncodableResult(reply)))
            switch reply.decision {
            case .reject:
                // Exit 7 like RemoteControl — but the envelope still carries
                // the decision and every comment, `"ok":true`.
                let human = "[error] human_declined: the review was rejected\n"
                return (json, human, .humanDeclined)
            case .approve, .amend:
                // Amend is not a rejection: the human wants the patch changed
                // and answered with the edited patch. Exit 0.
                return (json, "", .success)
            }
        case .timedOut:
            return failureResult(
                .timedOut,
                "no review decision arrived within \(timeoutSeconds)s",
                .timedOut)
        case .superseded:
            return failureResult(
                .requestFailed,
                "the review request was superseded by a newer request for the same repository; no decision was received",
                .requestFailed)
        }
    }

    // MARK: - Result shapers (same shapes as Dispatch.connectionFailureResult)

    private static func failureResult(
        _ code: EnvelopeErrorCode,
        _ message: String,
        _ exitCode: ExitCode
    ) -> (stdout: String, stderr: String, exitCode: ExitCode) {
        let env = EnvelopeFail(code: code, message: message)
        let human = "[error] \(env.error.code.rawValue): \(env.error.message)\n"
        return (jsonString(env), human, exitCode)
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
