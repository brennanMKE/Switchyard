// main.swift

import Foundation
import YardCommands
import YardKit

/// Printed before anything else on `--help` -- this binary links the engine
/// in-process for development and demonstration; it is not the shipping
/// CLI. `switchyard` is the real CLI and talks to the app over XPC, and once
/// the app exists the two will not always agree.
let harnessHeader = """
yard-engine is a development harness, not the shipping CLI. It links the
engine in-process and runs commands directly, with no app and no XPC.
`switchyard` is the real CLI: it talks to Switchyard.app over XPC, and once
that app exists, the two will not always agree.

"""

let arguments = Array(CommandLine.arguments.dropFirst())
let workingDirectory = FileManager.default.currentDirectoryPath

if arguments.first == "--help" {
    FileHandle.standardOutput.write(Data(harnessHeader.utf8))
}

let result = runEngineCommand(arguments: arguments, workingDirectory: workingDirectory)
    ?? runYard(arguments: arguments)

if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
    fflush(stderr)
}

FileHandle.standardOutput.write(Data(result.stdout.utf8))
fflush(stdout)

exit(Int32(result.exitCode.rawValue))
