// main.swift - Entry point for the yard CLI.

import Foundation

func printHelp() {
    print("yard — Switchyard, a structured git frontend.\n")
    print("Usage: yard <command> [options]\n")

    var prevGroup: String?
    for cmd in listCommands().sorted(by: { $0.command.rawValue < $1.command.rawValue }) {
        if let g = cmd.group?.rawValue, g != prevGroup { print("\n\(g)!"); prevGroup = g }
        let helpStr = String(cmd.help)
        print("  \(helpStr)")
    }

    print("\nGlobal flags:")
    print("  --help, -h                Show this message")
}

// MARK: Main

let args = CommandLine.arguments.dropFirst()

if ["--help", "-h"].contains(args.first!) {
    printHelp(); exit(0)
}

guard let cmdName = args.first, let _ = commandByName(cmdName) else {
    if !args.isEmpty { print("Unknown command: \(args.first ?? "")"); exit(1) }
    else { printHelp(); exit(0) }
}
