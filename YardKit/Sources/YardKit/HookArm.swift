// HookArm.swift — the `hook` arm the installed observer wrappers exec (#0154)

import Foundation

/// The `switchyard hook <handler> …` arm: the thin process #0041's installed
/// wrapper execs on every ref update (`HookInstall.script(for:)` runs
/// `switchyard hook ref-txn "$@" <payload>` with stdout/stderr discarded and
/// `|| :`).
///
/// **Local, never remote.** Like `--help`, the arm is answered by this
/// process: `hook` is in `localCommandNames`, so `route` classifies it
/// `.local` and it never enters `CommandRegistry.all` — it must never be
/// offered to the app as a subcommand. `dispatch` intercepts it before
/// `runYard` because it is not pure: it reads stdin and reaches the app over
/// XPC.
///
/// **Over XPC, like every other command (guide §11 decision 22).** The arm
/// connects with `AppConnection.connect(launchIfNeeded: false)` and forwards
/// state + environment + stdin bytes to `performReferenceTransactionHook`,
/// whose app-side body (`runReferenceTransactionHook` in `YardCommands`) runs
/// the decision core, `ReferenceTransaction.decide`. The CLI does not link
/// `YardGit` (layering), so the decision itself never runs here.
///
/// **`launchIfNeeded: false`, always.** The hook fires on every ref update by
/// every tool — a background `git fetch` in a terminal must never launch a
/// GUI application. When the app is not running, connect fails fast and the
/// arm exits 0.
///
/// **The consequence, decided knowingly (decision 22):** ref transactions
/// made while Switchyard.app is closed are **not journalled**. Journal
/// completeness is a function of whether the app is running. That is the
/// accepted cost of never launching the app from a hook; it must not read as
/// an oversight.
///
/// **Exit 0 in every case.** #0042's totality invariant, preserved at the
/// process boundary: a non-zero exit in the `prepared` state aborts the
/// user's transaction (`fatal: ref updates aborted by hook`), and a journal
/// that cannot record must never be able to break somebody's commit.
/// Unreachable app, garbage stdin on `committed`, missing state argument —
/// all exit 0. The arm never exits the app's replied code either: the reply
/// is `Decision.exitCode`, which is 0 by construction, and even a future
/// non-total reply could not turn into a non-zero process exit here.
public enum HookArm {

    /// The subcommand name #0041's script invokes.
    static let commandName = "hook"

    /// The handler name the `reference-transaction` wrapper passes
    /// (`ObservedHook.handlerName`). The `post-rewrite` handler's arm lands
    /// with #0160's machinery; until then it is refused with a logged line
    /// and exit 0, never a non-zero.
    static let referenceTransactionHandler = "ref-txn"

    /// How long the arm waits for the app to answer the decision request.
    ///
    /// **A judgement, not a measurement.** The app-side body does real work —
    /// resolving the repository and writing an observed entry shell out to
    /// git — so the bound must sit comfortably above that (~a few hundred ms
    /// worst case) or ordinary recording would be cut off. Two seconds is an
    /// order of magnitude above it while still being nothing a human notices
    /// on a ref update; #0043 Givens 5 measured the process spawn (~8 ms) as
    /// the dominant handler cost, so a *reachable* app answering within the
    /// bound costs a transaction nothing measurable. An *unreachable* app
    /// never reaches this deadline at all: connect fails at the mach layer
    /// immediately (measured ~0 ms for a bootstrap lookup that cannot
    /// resolve; `broker.appEndpoint` also replies instantly when no app has
    /// registered).
    static let appTimeout: Duration = .seconds(2)

    /// What the gate decided to do with one invocation.
    enum Gate: Equatable {

        /// A foreign `committed` `ref-txn` invocation: forward these to the
        /// app. `standardInput` is the bytes the gate drained, already read.
        case forward(state: String, standardInput: Data)

        /// Nothing to record — `prepared`/`aborted`/an unrecognized state, or
        /// Switchyard's own transaction (marker present and non-empty). The
        /// normal no-op path: exit 0, silently, exactly like `decide`'s
        /// policy for every non-`committed` state.
        case nothingToRecord

        /// A malformed invocation: missing state argument, or a handler this
        /// build has no arm for. Logged to stderr (the wrapper discards it,
        /// but a manual run sees it), and still exit 0.
        case refused(String)
    }

    /// Decides what one hook invocation does, from argv and the environment.
    ///
    /// This is #0042's closure contract at the process boundary: the state
    /// argument and the environment are checked **before** `readStandardInput`
    /// is ever called, so stdin is drained only when it will be shipped. The
    /// reader is called at most once, and only on `.forward`.
    ///
    /// - Parameters:
    ///   - arguments: the process arguments after the executable name —
    ///     `["hook", handler, state, …]`, where the tail is whatever git
    ///     passed (refnames) and is ignored here.
    ///   - environment: the hook process's environment, verbatim. Git
    ///     propagates its own environment to hooks, so `switchyard`'s own
    ///     transactions carry the marker (`ServiceNames
    ///     .yardInvocationMarkerVariable`) non-empty; empty counts as foreign,
    ///     the documented escape hatch for tests.
    ///   - markerVariable: the environment variable naming our own
    ///     transactions. Defaults to `ServiceNames`' constant, which
    ///     `YardWireTests` pins equal to `GitProcess.markerVariable` — the
    ///     CLI cannot read the engine's constant directly (layering).
    ///   - readStandardInput: called at most once, and only when the verdict
    ///     is `.forward`.
    static func gate(
        arguments: [String],
        environment: [String: String],
        markerVariable: String = ServiceNames.yardInvocationMarkerVariable,
        readStandardInput: () -> Data
    ) -> Gate {
        guard arguments.count >= 2, arguments[0] == commandName else {
            return .refused("not a hook invocation (expected 'hook <handler> <state>')")
        }
        guard arguments[1] == referenceTransactionHandler else {
            return .refused("no handler installed for '\(arguments[1])'")
        }
        // The state argument is checked before stdin is drained — #0042's
        // readStandardInput contract, preserved at the process boundary.
        guard arguments.count >= 3 else {
            return .refused("missing state argument")
        }
        let state = arguments[2]
        guard state == "committed" else {
            // prepared, aborted, or anything a future git adds: nothing to
            // record, and nothing to read. Silent — this is the normal path
            // most invocations take.
            return .nothingToRecord
        }
        if let marker = environment[markerVariable], !marker.isEmpty {
            // Switchyard's own transaction: the decision core would skip it.
            // Skip draining stdin too.
            return .nothingToRecord
        }
        return .forward(state: state, standardInput: readStandardInput())
    }

    /// Runs the arm: gate, then forward, then exit 0 — in every case.
    ///
    /// - Parameters:
    ///   - arguments: the process arguments after the executable name.
    ///   - workingDirectory: the hook process's cwd — the invoking worktree's
    ///     top, per #0041's script. The app resolves the repository from it.
    ///   - environment: the hook process's environment. Defaults to this
    ///     process's, which is the production reading.
    ///   - connect: injectable so `dispatch`-level tests can run the arm
    ///     without a broker, launch agent, or app. Production uses
    ///     `AppConnection.connect(launchIfNeeded: false)` — see the type
    ///     comment for why the launch flag must never be true here.
    static func run(
        arguments: [String],
        workingDirectory: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        connect: () async throws -> AppConnection = {
            try await AppConnection.connect(launchIfNeeded: false)
        }
    ) async -> (stdout: String, stderr: String, exitCode: ExitCode) {
        switch gate(arguments: arguments, environment: environment, readStandardInput: {
            FileHandle.standardInput.readDataToEndOfFile()
        }) {
        case .nothingToRecord:
            return ("", "", .success)

        case .refused(let message):
            return ("", "[switchyard hook] refusing: \(message)\n", .success)

        case .forward(let state, let standardInput):
            do {
                let app = try await connect()
                defer { app.close() }
                // The reply is Decision.exitCode — 0 by #0042's construction.
                // It is deliberately not trusted as the process exit: the
                // exit-0 invariant below is the arm's own, not the app's.
                _ = try await app.performReferenceTransactionHook(
                    state: state,
                    environment: environment,
                    standardInput: standardInput,
                    workingDirectory: workingDirectory,
                    timeout: appTimeout)
                return ("", "", .success)
            } catch {
                // Unreachable app, broker, or timeout — the documented
                // consequence of decision 22: the transaction succeeded and
                // is simply not journalled. Exit 0, always.
                return ("", "[switchyard hook] app unavailable; ref transaction not journalled\n", .success)
            }
        }
    }
}
