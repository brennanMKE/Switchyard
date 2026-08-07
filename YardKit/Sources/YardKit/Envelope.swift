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
    /// Present only when `ok == true`. Commands place their payload here as a
    /// concrete value; the envelope does not try to model it generically.

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

public struct EnvelopeError: Sendable, Encodable {
    public let code: String
    public let message: String
    /// Optional hint to help an agent recover — usually a pointer at the user
    /// config or action that would fix it. Left empty when there is nothing to
    /// suggest beyond the message.

    public let hint: String?

    public init(code: String, message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: _ErrorKey.self)
        try container.encode(code, forKey: .code)
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
}

public struct EnvelopeFail: Sendable, Encodable {
    public let schemaVersion: Int
    public let ok: Bool
    public let error: EnvelopeError

    public init(code: String, message: String, hint: String? = nil) {
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
}
