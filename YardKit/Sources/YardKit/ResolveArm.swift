// ResolveArm.swift — the `resolve [--pathspec] --wait` arm (#0057)

import Foundation

/// The `switchyard resolve [pathspec] --wait` arm: the command that opens the
/// three-way merge UI for a repository's conflicts, blocks on the human, and
/// returns every path's resolution as structured data (#0057). On success the
/// payload IS the reply: `{"resolutions":[…]}` or `{"cancelled":true}`.
///
/// **Remote over XPC, like every M4 interactive command.** The arm connects
/// with `launchIfNeeded: false` and exits 3 when the app is down — never a
/// silent non-interactive fallback, because an agent proceeding without the
/// human's resolutions would be a bug. `dispatch` intercepts the arm before
/// the generic `perform` path, exactly as it does for `review` and `ask`.
///
/// **The blocking contract is review's (#0055), inherited whole.** The CLI
/// awaits the reply for up to `--timeout + 5 s` (the backstop margin); the
/// app-side pending store is armed with exactly `--timeout`, so the typed
/// timeout outcome normally arrives first. The app quitting mid-resolve
/// surfaces through the connection's error path as exit 5 — never as a
/// decision.
///
/// **Exit codes.** 0 all conflicts resolved after the reply, 7 the human
/// cancelled (nothing staged, nothing touched — a considered decision, the
/// same code as a rejected review and a declined ask; the envelope still
/// carries the cancelled reply with `"ok":true`), 8 conflicts remain after
/// the reply (`blockedOnConflicts`, which is what that code exists for — the
/// envelope still carries the reply, the same contract as a rejection), 3 app
/// unavailable, 5 app quit mid-resolve, 10 the wait timed out, 4 superseded
/// by a newer resolve for the same repository or the app could not serve it
/// (review's precedent — the design's exit list does not name a superseded
/// code, and the store's supersede semantics need one), 1 usage.
///
/// **The conflicts-remaining check.** The reply is the human's answer, not a
/// certificate that the worktree is clean: per-card staging (round 2) may
/// have resolved some paths and left others, and Submit with nothing staged
/// resolves nothing. After a decided, non-cancelled reply the arm asks the
/// app to run its own `conflicts` command — the CLI does not link the engine,
/// and the generic `perform` path is the wire for app-side engine work — and
/// exits 8 when ANY conflicted path remains in the repository, 0 when none
/// does.
public enum ResolveArm {

    /// The subcommand name, as registered in `CommandRegistry.all`.
    static let commandName = "resolve"

    /// The default `--timeout`, in seconds. **A judgement, not a measurement**
    /// — the same judgement as review's and ask's: a forgotten session must
    /// not pin the app forever, but a human resolving a stack of conflicts
    /// must not be cut off either.
    static let defaultTimeoutSeconds = 3600

    /// The CLI-side backstop margin over `--timeout`. The app-side pending
    /// resolve is armed with exactly `timeoutSeconds`, so the typed timeout
    /// normally beats this backstop; the margin exists so a lost or late
    /// reply still cannot hang the CLI past its contract. A parameter of
    /// `run` (defaulting to this constant) rather than mutable static state:
    /// the suite passes a small value where it needs a fast worst case.
    static let backstopMargin: Duration = .seconds(5)

    /// One accepted invocation, already validated.
    struct Invocation: Equatable {
        var pathspec: String?
        var timeoutSeconds: Int
    }

    enum ParseOutcome: Equatable {
        case run(Invocation)
        case refused(String)
    }

    /// Pure argv parsing, in the same spirit as `ReviewArm.parseInvocation`:
    /// decide everything from `arguments` before any I/O happens.
    ///
    /// - `[pathspec]` — optional, at most one. Absent means every conflicted
    ///   path in the repository.
    /// - `--wait` — required in this build. A non-blocking form does not
    ///   exist yet, so asking for one is a usage refusal, not a fallback.
    /// - `--timeout <seconds>` — optional, a positive integer, default 3600
    ///   (a judgement — see `defaultTimeoutSeconds`).
    static func parseInvocation(_ arguments: [String]) -> ParseOutcome {
        guard arguments.first == commandName else {
            return .refused("not a resolve invocation")
        }

        var sawWait = false
        var pathspec: String?
        var timeoutSeconds = defaultTimeoutSeconds

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
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
                if pathspec != nil {
                    return .refused("pass at most one pathspec")
                }
                pathspec = argument
            }
            index += 1
        }

        guard sawWait else {
            return .refused("the blocking form requires --wait; a non-blocking form is not implemented yet")
        }
        if let pathspec, pathspec.isEmpty {
            return .refused("the pathspec must name a path, or be omitted for every conflicted path")
        }
        return .run(Invocation(pathspec: pathspec, timeoutSeconds: timeoutSeconds))
    }

    /// Runs the arm: parse, connect, send, await the outcome, map it.
    ///
    /// - Parameters:
    ///   - arguments: the process arguments after the executable name.
    ///   - workingDirectory: the CLI process's working directory. The app
    ///     resolves the repository from it — the CLI does not link the
    ///     engine, so it cannot fill `ResolveRequest.commonDir` itself.
    ///   - connect: injectable so the dispatch-level and arm-level tests run
    ///     without a broker, launch agent, or app. Production uses
    ///     `AppConnection.connect(launchIfNeeded: false)` — resolve never
    ///     launches the app (the M4 exit criterion).
    ///   - backstopMargin: the wait over `--timeout` before the CLI gives up
    ///     on its own (see `backstopMargin`). Production never passes this.
    static func run(
        arguments: [String],
        workingDirectory: String,
        connect: () async throws -> AppConnection = {
            try await AppConnection.connect(launchIfNeeded: false)
        },
        backstopMargin: Duration = ResolveArm.backstopMargin
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
        let request = ResolveRequest(
            // Resolved app-side from `workingDirectory` — see ResolveRequest.
            commonDir: "",
            pathspec: invocation.pathspec,
            timeoutSeconds: invocation.timeoutSeconds)
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        guard let requestData = try? encoder.encode(request) else {
            return failureResult(.requestFailed, "Failed to encode the resolve request.", .requestFailed)
        }

        do {
            let app = try await connect()
            defer { app.close() }

            let outcomeData = try await app.performResolve(
                request: requestData,
                workingDirectory: workingDirectory,
                timeout: .seconds(Double(invocation.timeoutSeconds)) + backstopMargin)
            let decoder = JSONDecoder()
            if let outcome = try? decoder.decode(ResolveOutcome.self, from: outcomeData) {
                return await render(
                    outcome,
                    workingDirectory: workingDirectory,
                    app: app)
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
                "the app replied with something that could not be decoded as a resolve outcome",
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
                    "no resolve reply arrived within \(invocation.timeoutSeconds)s",
                    .timedOut)
            }
            return connectionFailure(exitCode: error.exitCode, message: String(describing: error))
        } catch {
            return failureResult(.requestFailed, String(describing: error), .requestFailed)
        }
    }

    /// Maps the app's typed outcome to the process result.
    private static func render(
        _ outcome: ResolveOutcome,
        workingDirectory: String,
        app: AppConnection
    ) async -> (stdout: String, stderr: String, exitCode: ExitCode) {
        switch outcome {
        case .decided(let reply):
            // The wire contract from the issue: the payload is the reply.
            let json = jsonString(Envelope(result: EncodableResult(reply)))
            switch reply {
            case .cancelled:
                // Exit 7 like a rejected review and a declined ask — but the
                // envelope still carries the cancelled reply, `"ok":true`.
                // The JSON is the contract, the exit code is the signal.
                let human = "[error] human_declined: the resolve was cancelled; nothing was staged\n"
                return (json, human, .humanDeclined)
            case .resolutions:
                // The reply says what the human chose; the INDEX says whether
                // the repository is still blocked. Re-check through the app's
                // own conflicts command — 0 when clean, 8 when anything
                // remains, either way with the reply as the payload.
                do {
                    let remaining = try await countRemainingConflicts(
                        app: app, workingDirectory: workingDirectory)
                    if remaining > 0 {
                        let human = "[error] blocked_on_conflicts: \(remaining) conflicted path(s) remain\n"
                        return (json, human, .blockedOnConflicts)
                    }
                    return (json, "", .success)
                } catch let error as AppConnectionError {
                    return connectionFailure(exitCode: error.exitCode, message: String(describing: error))
                } catch {
                    return failureResult(
                        .requestFailed,
                        "the conflicts re-check after the reply failed: \(error)",
                        .requestFailed)
                }
            }
        case .timedOut:
            return failureResult(
                .timedOut,
                "no resolve reply arrived in time",
                .timedOut)
        case .superseded:
            return failureResult(
                .requestFailed,
                "the resolve request was superseded by a newer request for the same repository; no reply was received",
                .requestFailed)
        }
    }

    /// Counts the repository's still-conflicted paths, by asking the app to
    /// run its own `conflicts` command. The generous deadline is a bound,
    /// not a wait — the reply lands as soon as git answers (Rule 7c: under
    /// suite load a git subprocess can stall for tens of seconds, and a
    /// 5 s deadline would measure the machine, not the repository).
    ///
    /// Every conflicted path counts, not just the request's pathspec scope:
    /// the repository is what stays blocked (a commit over unmerged entries
    /// refuses), so "any conflict remains" is the fact the exit code carries.
    static func countRemainingConflicts(
        app: AppConnection,
        workingDirectory: String
    ) async throws -> Int {
        let (stdout, exitCode) = try await app.perform(
            arguments: ["conflicts"],
            workingDirectory: workingDirectory,
            timeout: .seconds(30))
        guard exitCode == 0 else {
            throw CountFailure.commandFailed(exitCode: exitCode)
        }
        let object = try JSONSerialization.jsonObject(with: stdout)
        guard let dictionary = object as? [String: Any],
              let entries = dictionary["result"] as? [[String: Any]] else {
            throw CountFailure.malformedEnvelope
        }
        return entries.count
    }

    enum CountFailure: Error, CustomStringConvertible {
        case commandFailed(exitCode: Int32)
        case malformedEnvelope

        var description: String {
            switch self {
            case let .commandFailed(exitCode):
                "the app's conflicts command exited \(exitCode)"
            case .malformedEnvelope:
                "the app's conflicts command replied without a result array"
            }
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
