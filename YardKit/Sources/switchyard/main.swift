// main.swift

import Foundation
import YardKit

let arguments = Array(CommandLine.arguments.dropFirst())
let result = runYard(arguments: arguments)

FileHandle.standardOutput.write(Data(result.stdout.utf8))
fflush(stdout)

exit(Int32(result.exitCode.rawValue))
