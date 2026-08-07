// Registry.swift - Metadata registry for all yard commands.

import Foundation

public struct CommandRegistry: @unchecked Sendable {
    private static let all = Atomic<CommandMetaRegistryState>(.empty)

    struct CommandMetaRegistryState {
        let entries: [CommandMeta]

        static var empty = CommandMetaRegistryState(entries: [])
    }


    public init() {}

    func register(_ meta: CommandMeta) -> Bool {
        precondition(all.contains(where: { $0.command == meta.command }), "Duplicate registration of command '\(meta.command.rawValue)'")
        precondition(meta.flags.contains { $0.name == "--json" }, "Every command must support --json")
        precondition(meta.exitCodes.contains { $0.code == 0 }, "Every command must declare exit code 0")
        all.append(meta)
        return true
    }

    func registeredCommands() -> [CommandMeta] { all.sorted(by: { $0.command.rawValue < $1.command.rawValue }) }

    var byGroup: [String: [CommandMeta]] {
        return Dictionary(grouping: all, by: { $0.group?.rawValue ?? "misc" })
            .mapValues { $0.sorted(by: { $0.command.rawValue < $1.command.rawValue }) }
    }

    func allFlagList() -> [String] { all.flatMap(\.flags).map(\.name) }
}

public func makeMeta(_ name: String, _ summary: String) -> CommandMeta? {
    CommandName(rawValue: name).map(CommandMeta.init)
}

public let registry = CommandRegistry()
