// ExitCode.swift

import Foundation

/// Exit codes for the `yard` CLI.
///
/// Defined as a closed enum so a caller can branch on them without guessing,
/// and codes 2-5 match RemoteControl exactly so agents that know one tool do
/// not have to learn a different numbering for the other. See guide §6 "Exit
/// codes". Nothing here owns stdout formatting — that is the envelope's job.
public enum ExitCode: Int, Sendable {

    /// The command completed successfully and the JSON envelope carries
    /// `"ok":true`.
    case success = 0

    /// The caller passed invalid arguments, an unknown subcommand, or a flag
    /// in the wrong position. The message is a usage hint; no structured
    /// error envelope is required because the caller already knows what went
    /// wrong by how they invoked us. Still emits `{"ok":false,...}` because a
    /// caller parsing stdout should never have to also parse stderr.
    case usage = 1

    /// The broker Mach service could not be contacted. Only reachable
    /// through XPC, so it never fires for pure-read commands. Callers that
    /// need the app can retry after a short backoff — it is almost always a
    /// timing issue at launch.
    case brokerUnreachable = 2

    /// The command requires the Switchyard app (`review --wait`, `ask`,
    /// `resolve --interactive`, `watch`) but it is not running. `yard` does
    /// not silently fall back to a non-interactive path here, because an
    /// agent proceeding without the human decision it was asked for would be
    /// a bug.
    case appUnavailable = 3

    /// A request to the broker failed for a reason unrelated to reachability
    /// or termination — bad payload, unhandled path, etc.
    case requestFailed = 4

    /// The XPC session was terminated by the app.
    case sessionTerminated = 5

    /// The repository is in a state the command cannot work with: not a
    /// repository, detached HEAD on a rebase in progress, ref format the
    /// engine does not yet handle.
    case repositoryError = 6

    /// The human rejected the request in an interactive command (`review`,
    /// `ask`). Same exit code as RemoteControl so agents do not have to guess.
    case humanDeclined = 7

    /// A mutating command cannot proceed because the worktree has unmerged
    /// conflicts. The caller is expected to surface them, not silently pass.
    case blockedOnConflicts = 8

    /// Signing failed: SSH key not found, gpg invocation returned non-zero,
    /// signature format mismatch. Carries enough detail for the agent to
    /// correct the config without retrying the same thing.
    case signingFailed = 9

    /// Maps the `Int32` exit code the app returns over XPC (`NSXPCInterface`
    /// will not carry a Swift enum, so the wire uses `Int32` — see guide §11
    /// decision 15 and ``AppServiceProtocol/perform(arguments:workingDirectory:reply:)``)
    /// to a known case.
    ///
    /// A value this build does not recognize — an older CLI talking to a
    /// newer app that has grown a case this build predates — lands on
    /// `.requestFailed` rather than trapping on `ExitCode(rawValue:)!`.
    public init(fromAppReply value: Int32) {
        self = ExitCode(rawValue: Int(value)) ?? .requestFailed
    }

    /// Stable string value used in error envelopes and test assertions.
    public var codeLabel: String {
        switch self {
        case .success: return "ok"
        case .usage: return "usage"
        case .brokerUnreachable: return "broker_unreachable"
        case .appUnavailable: return "app_unavailable"
        case .requestFailed: return "request_failed"
        case .sessionTerminated: return "session_terminated"
        case .repositoryError: return "repository_error"
        case .humanDeclined: return "human_declined"
        case .blockedOnConflicts: return "blocked_on_conflicts"
        case .signingFailed: return "signing_failed"
        }
    }

}
