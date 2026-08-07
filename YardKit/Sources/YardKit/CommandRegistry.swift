// CommandRegistry.swift

import Foundation

/// The registry of every `yard` command.
///
/// Pure data: a `static let` containing the `CommandSpec` for every command
/// that `runYard` knows about. No mutable store, no `Atomic`, no global
/// singletons — callers look up a spec by name or iterate `.all` to build
/// help, schema, and tests.
public enum CommandRegistry {

    /// All known `yard` command specifications in the order they should be
    /// rendered in help output.
    public static let all: [CommandSpec] = [switchyardSpec, noopSpec]

    // MARK: - The switchyard spec — rendered by `yard --help`

    static let switchyardSpec = CommandSpec(
        name: "switchyard",
        summary: "\(ServiceNames.cliName) CLI — version, help, and command schema.",
        flags: [
            FlagSpec(long: "help", short: "h", argument: nil, help: "Show this help text and exit."),
            FlagSpec(long: "version", short: "v", argument: nil, help: "Print the CLI version and exit."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "Help or version text was printed."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments or unknown subcommand."),
        ],
        schemaName: "switchyard"
    )

    // MARK: - The noop spec — echoes a success envelope.

    static let noopSpec = CommandSpec(
        name: "noop",
        summary: "A no-op command that returns a success envelope.",
        flags: [
            FlagSpec(long: "help", short: "h", argument: nil, help: "Show this command's help and exit."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The command completed successfully."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments or unknown subcommand."),
        ],
        schemaName: "noop"
    )

    /// Look up a `CommandSpec` by its name, returning nil if the spec is not in
    /// the registry. This lets callers (and tests) branch on "do we know it?"
    /// without reaching into `.all`. If a caller wants every spec, they can
    /// still iterate `CommandRegistry.all` — this helper only provides a single lookup.
    public static func lookup(name: String) -> CommandSpec? {
        all.first(where: { $0.name == name })
    }

}
