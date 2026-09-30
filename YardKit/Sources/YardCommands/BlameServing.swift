// BlameServing.swift — the `blame` arm in `runEngineCommand`
// (guide §11 decisions 39 and 43)

import Foundation
import YardGit
import YardKit

/// The `blame` payload: one `BlameLine` per line of the file (or of the
/// `--lines` range), in file order.
struct BlamePayload: Encodable, Sendable, Equatable {
    /// The path asked about, repository-relative.
    let path: String
    /// The revision blamed; absent for the working tree, where a line not in
    /// any commit carries the all-zero oid.
    let revision: String?
    let lines: [BlameLine]
}

/// `switchyard blame <path> [--revision <rev>] [--lines <start>,<end>]` —
/// `git blame --porcelain` over `blameFile`, the Blame half of the app's file
/// inspector. Without `--revision` it blames the working tree's file, and a
/// line not yet committed has the oid `0000…0000`. `--lines` bounds the work
/// as well as the output (1-based, inclusive; `start` ≤ `end`). Read-only.
func runBlame(arguments: [String], workingDirectory: String) -> EngineReply {
    let parsed: FileArguments
    switch parseFileArguments("blame", Array(arguments.dropFirst()), valueFlags: ["--revision", "--lines"]) {
    case let .success(value): parsed = value
    case let .failure(usage): return engineUsage(usage.text)
    }
    var lines: ClosedRange<Int>?
    if let text = parsed.values["--lines"] {
        guard let range = parseLineRange(text) else {
            return engineUsage("blame's --lines takes <start>,<end>, two positive integers with start ≤ end; got '\(text)'.")
        }
        lines = range
    }
    let revision = parsed.values["--revision"]
    do {
        let top = try repositoryTop(workingDirectory)
        let blamed: [BlameLine] = try blameFile(at: top, file: parsed.path, lines: lines, revision: revision)
        return engineSuccess(BlamePayload(path: parsed.path, revision: revision, lines: blamed))
    } catch {
        return engineFailure(error)
    }
}

/// `"3,7"` → `3...7`; bare ASCII digits only (no sign, no space), both at
/// least 1, `start` ≤ `end`. Anything else is nil.
func parseLineRange(_ text: String) -> ClosedRange<Int>? {
    let parts = text.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 2,
          parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }),
          let start = Int(parts[0]), let end = Int(parts[1]),
          start >= 1, start <= end else { return nil }
    return start...end
}
