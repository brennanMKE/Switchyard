// Envelope.swift

import Foundation

/// The single JSON shape every `yard` command emits, success or failure.
///
/// Human-readable output is the courtesy; JSON on stdout is the contract.
/// Agents branch on `"ok"` and `"error.code"`. Every response carries a
/// `schemaVersion` so an agent can detect when the shape changes. See guide
/// §6 "Design principles".
///
/// The envelope is declared once and reused by every command, so adding one
/// flag to a command does not require inventing a new error shape for it.

public enum EnvelopeSchema: Int, Sendable {
    case v1 = 1
}

public struct Envelope: Encodable {
    public let schemaVersion: Int
    public let ok: Bool

    public let result: EncodableResult?

    /// A success envelope. The `result` field is the command's actual payload,
    /// whose concrete type varies per command. Pass `nil` when a command has no
    /// interesting data to return — `checkpoint`, for instance.
    public init(result: EncodableResult? = nil) {
        self.schemaVersion = EnvelopeSchema.v1.rawValue
        self.ok = true
        self.result = result
    }

    public init(ok: Bool) {
        self.schemaVersion = EnvelopeSchema.v1.rawValue
        self.ok = ok
        if ok {
            self.result = EncodableResult()
        } else {
            self.result = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: _EnvelopeKey.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(ok, forKey: .ok)
        if let result {
            try container.encode(result, forKey: .result)
        }
    }

    private enum _EnvelopeKey: String, CodingKey {
        case schemaVersion = "schemaVersion"
        case ok = "ok"
        case result = "result"
    }

}

/// A wrapper that makes any `Encodable` value `Sendable`.
public struct EncodableResult: Sendable, Encodable {
    public let value: any (Encodable & Sendable)

    public init(_ value: some (Encodable & Sendable)) {
        self.value = value
    }

    public func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }

    private struct EmptyResult: Encodable, Sendable {}

    public init() {
        self.value = EmptyResult()
    }
}

/// The closed set of error codes `yard` emits in its JSON failure envelope.
///
/// Every value also maps to an `ExitCode` so the same code appears both in the
/// JSON output and as the process exit status — an agent can branch on either.
public enum EnvelopeErrorCode: String, Sendable, CaseIterable {

    /// A command completed successfully — paired with `ExitCode.success`.
    case ok = "ok"

    /// Invalid arguments, unknown subcommand, or mis-positioned flag.
    case usage = "usage"

    /// The broker Mach service could not be contacted.
    case brokerUnreachable = "broker_unreachable"

    /// The Switchyard app is not running, and the command requires it.
    case appUnavailable = "app_unavailable"

    /// A request to the broker failed for a reason unrelated to reachability
    /// or termination — bad payload, unhandled path, etc.
    case requestFailed = "request_failed"

    /// The XPC session was terminated by the app.
    case sessionTerminated = "session_terminated"

    /// The repository is in a state the command cannot work with.
    case repositoryError = "repository_error"

    /// The human rejected the request in an interactive command.
    case humanDeclined = "human_declined"

    /// The worktree has unmerged conflicts blocking a mutating command.
    case blockedOnConflicts = "blocked_on_conflicts"

    /// Signing failed: SSH key not found, gpg invocation returned non-zero,
    /// signature format mismatch.
    case signingFailed = "signing_failed"

    /// Stable string value used in error envelopes and test assertions. The
    /// mapping mirrors `ExitCode.codeLabel` one-to-one so the two surfaces of
    /// failure always agree.
    public var codeLabel: String { rawValue }

    // MARK: - CodingKey conformance (so the JSON encoder writes the string
    // value of each case)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)

        switch raw {
        case "ok": self = .ok
        case "usage": self = .usage
        case "broker_unreachable": self = .brokerUnreachable
        case "app_unavailable": self = .appUnavailable
        case "request_failed": self = .requestFailed
        case "session_terminated": self = .sessionTerminated
        case "repository_error": self = .repositoryError
        case "human_declined": self = .humanDeclined
        case "blocked_on_conflicts": self = .blockedOnConflicts
        case "signing_failed": self = .signingFailed
        default: throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unknown EnvelopeErrorCode: \(raw)")
        )
        }
    }

    // MARK: - Encodable conformance (so the JSON encoder writes the string
    // value of each case)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Maps this envelope error code back to the matching `ExitCode` value.
    public var exitCode: ExitCode {
        switch self {
        case .ok: return .success
        case .usage: return .usage
        case .brokerUnreachable: return .brokerUnreachable
        case .appUnavailable: return .appUnavailable
        case .requestFailed: return .requestFailed
        case .sessionTerminated: return .sessionTerminated
        case .repositoryError: return .repositoryError
        case .humanDeclined: return .humanDeclined
        case .blockedOnConflicts: return .blockedOnConflicts
        case .signingFailed: return .signingFailed
        }
    }
}

public struct EnvelopeError: Sendable, Encodable {
    public let code: EnvelopeErrorCode
    public let message: String

    /// Optional hint to help an agent recover — usually a pointer at the user
    /// config or action that would fix it. Left empty when there is nothing to
    /// suggest beyond the message.

    public let hint: String?

    public init(code: EnvelopeErrorCode, message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: _ErrorKey.self)
        try container.encode(code.rawValue, forKey: .code)
        try container.encode(message, forKey: .message)
        if let hint {
            try container.encode(hint, forKey: .hint)
        }
    }

    private enum _ErrorKey: String, CodingKey {
        case code = "code"
        case message = "message"
        case hint = "hint"
    }

    public func matchExitCode() -> ExitCode { code.exitCode }
}


public struct EnvelopeFail: Sendable, Encodable {
    public let schemaVersion: Int
    public let ok: Bool
    public let error: EnvelopeError

    public init(code: EnvelopeErrorCode, message: String, hint: String? = nil) {
        self.schemaVersion = EnvelopeSchema.v1.rawValue
        self.ok = false
        self.error = EnvelopeError(code: code, message: message, hint: hint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: _FailKey.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(ok, forKey: .ok)
        try container.encode(error, forKey: .error)
    }

    private enum _FailKey: String, CodingKey {
        case schemaVersion = "schemaVersion"
        case ok = "ok"
        case error = "error"
    }

    /// Writes a failure envelope to stdout and the human-readable line to
    /// stderr. stdout carries exactly one thing: the JSON envelope. The caller
    /// decides whether and how the process exits — `write` focuses solely on
    /// emitting the JSON contract.
    public func write() {
        let human = "[error] \(error.code.rawValue): \(error.message)\n"
        if let data = human.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }

        let data = try! JSONEncoder().encode(self)
        FileHandle.standardOutput.write(data)
        fflush(stdout)
    }

    /// Writes a failure envelope to stdout and exits with the matching exit code.
    public func terminate() -> Never {
        write()
        exit(Int32(error.matchExitCode().rawValue))
    }
}
