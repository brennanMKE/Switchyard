// main.swift

import Foundation
import YardGit
import YardKit

// Placeholder entry point. The command surface, its metadata-driven help, and
// the JSON envelope arrive in #0010 and #0011; this exists so the executable
// target builds and links against both libraries from the start.

let version = YardGit.libgit2Version
print("yard \(YardKit.version) (libgit2 \(version.major).\(version.minor).\(version.revision))")
