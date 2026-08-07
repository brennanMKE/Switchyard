// CommandSpec.swift

import Foundation

/// Declarative description of a `yard` command: its name, summary, flags,
/// exit codes, and the name of its response schema. One file, one type's
/// worth of data — no behaviour, no registry, no rendering.
public struct CommandSpec: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let flags: [FlagSpec]
    public let exitCodes: [ExitCodeSpec]
    public let schemaName: String

    public init(name: String, summary: String, flags: [FlagSpec], exitCodes: [ExitCodeSpec], schemaName: String) {
        self.name = name
        self.summary = summary
        self.flags = flags
        self.exitCodes = exitCodes
        self.schemaName = schemaName
    }
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
