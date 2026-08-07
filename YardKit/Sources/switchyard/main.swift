// main.swift

import Foundation
import YardKit

let arguments = Array(CommandLine.arguments.dropFirst())
let result = runYard(arguments: arguments)

if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
    fflush(stderr)
}

FileHandle.standardOutput.write(Data(result.stdout.utf8))
fflush(stdout)

exit(Int32(result.exitCode.rawValue))
