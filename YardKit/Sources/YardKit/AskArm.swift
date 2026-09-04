// AskArm.swift — the `ask "<question>" --options a,b,c` arm (#0056)

import Foundation

/// The `switchyard ask "<question>" --options a,b,c [--timeout <seconds>]`
/// arm: the general human-in-the-loop pattern for the cases that are not
/// diff review (#0056). On success the payload IS the reply:
/// `{"optionIndex":n,"optionText":"…"}` plus the optional message.
///
/// **Remote over XPC, like every M4 interactive command.** The arm connects
/// with `launchIfNeeded: false` and exits 3 when the app is down — never a
/// silent non-interactive fallback, because an agent proceeding without the
/// human's answer would be a bug. `dispatch` intercepts the arm before the
/// generic `perform` path, exactly as it does for `review`.
///
/// **The blocking contract** is review's (#0055): the CLI awaits the reply
/// for up to `--timeout + 5 s` (the backstop margin); the app-side pending
/// store arms the head of the repository's queue with exactly `--timeout`
/// (a queued ask's clock starts when it reaches the head — see
/// `PendingAskStore`), so the typed timeout normally arrives first. The app
/// quitting mid-ask surfaces through the connection's error path as exit 5.
///
/// **Exit codes.** 0 an option was picked (the payload is the reply), 7 the
/// human declined to answer (a decided reply with declined semantics — the
/// envelope still carries the reply and `"ok":true`, the same contract as a
/// rejected review), 3 app unavailable, 5 app quit mid-ask, 10 the wait
/// timed out, 1 usage. There is no 4-shaped "superseded" exit: asks queue.
public enum AskArm {

    /// The subcommand name, as registered in `CommandRegistry.all`.
    static let commandName = "ask"

    /// The default `--timeout`, in seconds. **A judgement, not a
    /// measurement** — the same judgement as review's: a forgotten session
    /// must not pin the app forever, but a human thinking through a hard
    /// question must not be cut off either.
    static let defaultTimeoutSeconds = 3600

    /// The CLI-side backstop margin over `--timeout`. The app-side pending
    /// ask is armed with exactly `timeoutSeconds` once it is the head, so
    /// the typed timeout normally beats this backstop; the margin exists so
    /// a lost or late reply still cannot hang the CLI past its contract. A
    /// parameter of `run` (defaulting to this constant) rather than mutable
    /// static state: the suite passes a small value where it needs a fast
    /// worst case, and there is no shared mutable state to make
    /// concurrency-safe.
    static let backstopMargin: Duration = .seconds(5)

    /// One accepted invocation, already validated.
    struct Invocation: Equatable {
        var question: String
        var options: [String]
        var timeoutSeconds: Int
    }

    enum ParseOutcome: Equatable {
        case run(Invocation)
        case refused(String)
    }

    /// Pure argv parsing, in the same spirit as `ReviewArm.parseInvocation`:
    /// decide everything from `arguments` before any I/O happens.
    ///
    /// - The question is positional — exactly one.
    /// - `--options a,b,c` — required, comma-split in the order given. An
    ///   empty list, or any empty option in it, is a usage refusal: an
    ///   answer option that names nothing is not answerable.
    /// - `--timeout <seconds>` — optional, a positive integer, default 3600
    ///   (a judgement — see `defaultTimeoutSeconds`).
    ///
    /// A question that begins with `-` reads as a flag and is refused with
    /// the other unknown flags — the same limitation as a review range that
    /// begins with `-`, and worth the same refusal rather than guessing.
    static func parseInvocation(_ arguments: [String]) -> ParseOutcome {
        guard arguments.first == commandName else {
            return .refused("not an ask invocation")
        }

        var question: String?
        var options: [String]?
        var timeoutSeconds = defaultTimeoutSeconds

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--options":
                index += 1
                guard index < arguments.count else {
                    return .refused("--options requires a comma-separated list of answer options")
                }
                let split = arguments[index].split(separator: ",", omittingEmptySubsequences: false)
                    .map(String.init)
                guard !split.isEmpty, split.allSatisfy({ !$0.isEmpty }) else {
                    return .refused("--options must name at least one non-empty answer option")
                }
                options = split
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
                if question != nil {
                    return .refused("pass exactly one question argument")
                }
                question = argument
            }
            index += 1
        }

        guard let question, !question.isEmpty else {
            return .refused("pass the question to ask, e.g. switchyard ask \"Deploy now?\" --options yes,no")
        }
        guard let options else {
            return .refused("pass the answer options with --options, e.g. --options yes,no")
        }
        return .run(Invocation(question: question, options: options, timeoutSeconds: timeoutSeconds))
    }

    /// Runs the arm: parse, connect, send, await the outcome, map it.
    ///
    /// - Parameters:
    ///   - arguments: the process arguments after the executable name.
    ///   - workingDirectory: the CLI process's working directory. The app
    ///     resolves the repository from it — the CLI does not link the
    ///     engine, so it cannot fill `AskRequest.commonDir` itself.
    ///   - connect: injectable so the dispatch-level and arm-level tests run
    ///     without a broker, launch agent, or app. Production uses
    ///     `AppConnection.connect(launchIfNeeded: false)` — ask never
    ///     launches the app (the M4 exit criterion).
    ///   - backstopMargin: the wait over `--timeout` before the CLI gives up
    ///     on its own (see `backstopMargin`). Production never passes this.
    static func run(
        arguments: [String],
        workingDirectory: String,
        connect: () async throws -> AppConnection = {
            try await AppConnection.connect(launchIfNeeded: false)
        },
        backstopMargin: Duration = AskArm.backstopMargin
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
        let request = AskRequest(
            // Resolved app-side from `workingDirectory` — see AskRequest.
            commonDir: "",
            question: invocation.question,
            options: invocation.options,
            timeoutSeconds: invocation.timeoutSeconds)
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        guard let requestData = try? encoder.encode(request) else {
            return failureResult(.requestFailed, "Failed to encode the ask request.", .requestFailed)
        }

        do {
            let app = try await connect()
            defer { app.close() }

            let outcomeData = try await app.performAsk(
                request: requestData,
                workingDirectory: workingDirectory,
                timeout: .seconds(Double(invocation.timeoutSeconds)) + backstopMargin)
            let decoder = JSONDecoder()
            if let outcome = try? decoder.decode(AskOutcome.self, from: outcomeData) {
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
                "the app replied with something that could not be decoded as an ask outcome",
                .requestFailed)
        } catch let error as AppConnectionError {
            return connectionFailure(exitCode: error.exitCode, message: String(describing: error))
        } catch let error as CLIError {
            // The CLI's own backstop fired before any outcome arrived. From
            // the agent's side this is the same fact as the store's typed
            // timeout: no answer within the wait. Exit 10, not 2.
            if case .timedOut = error {
                return failureResult(
                    .timedOut,
                    "no answer arrived within \(invocation.timeoutSeconds)s",
                    .timedOut)
            }
            return connectionFailure(exitCode: error.exitCode, message: String(describing: error))
        } catch {
            return failureResult(.requestFailed, String(describing: error), .requestFailed)
        }
    }

    /// Maps the app's typed outcome to the process result.
    private static func render(
        _ outcome: AskOutcome,
        timeoutSeconds: Int
    ) -> (stdout: String, stderr: String, exitCode: ExitCode) {
        switch outcome {
        case .decided(let reply):
            // The wire contract from the issue: the payload is the reply.
            let json = jsonString(Envelope(result: EncodableResult(reply)))
            if reply.declined == true {
                // Exit 7 like a rejected review — but the envelope still
                // carries the reply, `"ok":true`. A decline is the human's
                // word, not an error in the exchange.
                let human = "[error] human_declined: the review was rejected\n"
                return (json, human, .humanDeclined)
            }
            return (json, "", .success)
        case .timedOut:
            return failureResult(
                .timedOut,
                "no answer arrived within \(timeoutSeconds)s",
                .timedOut)
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
