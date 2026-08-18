// CommandSpec.swift

import Foundation

/// Declarative description of a `yard` command: its name, summary, flags,
/// exit codes, the name of its response schema, and (#0194) the shape of its
/// success payload. One file, one type's worth of data — no behaviour, no
/// registry, no rendering.
///
/// ## The `payload` field (#0194)
///
/// `payload` is `nil` for a command whose result shape has not been recorded
/// yet — including a genuinely payload-less command like `noop`, which never
/// has a shape to record. `SchemaEmitter` renders the historical
/// self-reference (`"result": {"schema": "<schemaName>"}`) in that case, and
/// a real field list (`"result": {"fields": [...]}`) when `payload` is set.
/// A command is expected to arrive in `CommandRegistry` **with** its payload
/// shape from now on — see `issues/0115.md`'s per-command pattern — so `nil`
/// should only ever describe a command that has none.
///
/// Design, and its limits, per #0194:
///
/// - Each `PayloadField` states the wire key exactly as encoded (see
///   `WhereAmI`'s `CodingKeys` for why the two must match), its JSON scalar
///   type, whether the key is **absent** — never `null` — when there is
///   nothing to report, and a prose `description` for the facts a schema
///   cannot express structurally (`WhereAmI.headOID` being the seven-character
///   short form is exactly this kind of fact).
/// - A closed string enum is expressed as `type: .string` plus a non-empty
///   `enumCases`, the same pattern `SchemaEmitter` already uses for
///   `error.code`. There is no separate `.enum` case on `PayloadFieldType`.
/// - `PayloadShape` is flat, declarative data — an array of `PayloadField`,
///   nothing more. It runs no reflection over `Mirror` and has no behaviour
///   of its own; a hand-written shape can still drift from the type it
///   describes, which is why the wire test binds the generated schema file
///   back to the type's actual encoded keys instead of trusting this by hand.
/// - **Nested objects and arrays are not supported.** Every field here is a
///   top-level scalar (or a scalar enum). A command whose payload needs
///   nesting is its own issue; do not half-build nesting to fit it in here.
public struct CommandSpec: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let flags: [FlagSpec]
    public let exitCodes: [ExitCodeSpec]
    public let schemaName: String
    public let payload: PayloadShape?

    public init(
        name: String,
        summary: String,
        flags: [FlagSpec],
        exitCodes: [ExitCodeSpec],
        schemaName: String,
        payload: PayloadShape? = nil
    ) {
        self.name = name
        self.summary = summary
        self.flags = flags
        self.exitCodes = exitCodes
        self.schemaName = schemaName
        self.payload = payload
    }
}

/// The shape of a command's success payload: a flat list of fields. See
/// `CommandSpec`'s doc comment for the design and its limits — flat only, no
/// nesting, declarative data with no behaviour of its own.
public struct PayloadShape: Sendable, Equatable {
    public let fields: [PayloadField]

    public init(fields: [PayloadField]) {
        self.fields = fields
    }
}

/// One field of a command's success payload.
public struct PayloadField: Sendable, Equatable {
    /// The wire key, exactly as `Encodable` writes it — copy it from the
    /// type's `CodingKeys`, do not paraphrase it.
    public let name: String

    /// The JSON scalar type of the value. A closed string enum is `.string`
    /// with a non-empty `enumCases`, not a distinct case here.
    public let type: PayloadFieldType

    /// True when the key is **absent** from the JSON — never `null` — when
    /// there is nothing to report. Matches `Envelope`'s own rule for a nil
    /// `result` and `WhereAmI`'s optionals.
    public let optional: Bool

    /// The closed set of string values this field takes, when it is a closed
    /// enum. Empty for every other field.
    public let enumCases: [String]

    /// The fact a schema cannot express structurally: units, the exact
    /// source command, truncation, or anything else an agent needs and the
    /// type alone does not say.
    public let description: String

    public init(
        name: String,
        type: PayloadFieldType,
        optional: Bool = false,
        enumCases: [String] = [],
        description: String
    ) {
        self.name = name
        self.type = type
        self.optional = optional
        self.enumCases = enumCases
        self.description = description
    }
}

/// The JSON scalar types a payload field can declare. Deliberately just the
/// three JSON scalars — a closed enum is `.string` plus non-empty
/// `enumCases`, not a fourth case here (see `CommandSpec`'s doc comment).
public enum PayloadFieldType: String, Sendable, Equatable {
    case string
    case int
    case bool
}

/// A single flag on a command, describing how it appears to the user and whether it takes an argument.
public struct FlagSpec: Sendable, Equatable {
    public let long: String
    public let short: Character?
    public let argument: String?     // nil means boolean flag
    public let help: String

    public init(long: String, short: Character? = nil, argument: String? = nil, help: String) {
        self.long = long
        self.short = short
        self.argument = argument
        self.help = help
    }
}

/// A single documented exit code for a command.
public struct ExitCodeSpec: Sendable, Equatable {
    public let code: Int32
    public let meaning: String

    public init(code: Int32, meaning: String) {
        self.code = code
        self.meaning = meaning
    }
}
