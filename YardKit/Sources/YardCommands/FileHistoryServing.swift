// FileHistoryServing.swift — the `file-history` arm in `runEngineCommand`
// (guide §11 decisions 39 and 43)

import Foundation
import YardGit
import YardKit

/// One commit that changed the file, newest first.
struct FileHistoryCommitPayload: Encodable, Sendable, Equatable {
    let oid: String
    let author: String
    /// Author date, seconds since 1970.
    let authorTime: Int
    let subject: String
    /// `M`, `A`, `D`, `R`, `C` or `T`: what this commit did to the file.
    let status: String
    /// The file's path in this commit (after a rename, the new one).
    let path: String
    /// For a rename or copy, the path before it; absent otherwise.
    let previousPath: String?

    init(_ entry: FileHistory.Entry) {
        oid = entry.oid
        author = entry.author
        authorTime = entry.authorTime
        subject = entry.subject
        status = entry.status
        path = entry.path
        previousPath = entry.previousPath
    }
}

/// The `file-history` payload.
struct FileHistoryPayload: Encodable, Sendable, Equatable {
    /// The path asked about, repository-relative.
    let path: String
    /// The revision the walk started from (`HEAD` unless `--revision`).
    let revision: String
    let commits: [FileHistoryCommitPayload]
}

/// A file-taking command's parsed tail: one repository-relative path and the
/// values of its value flags.
struct FileArguments: Equatable {
    let path: String
    let values: [String: String]
}

/// Parses `<path> [--flag <value>]...` for `file-history` and `blame`: exactly
/// one path, each of `valueFlags` at most once and never with a value that
/// starts with `-` (git would read it as an option), `--` ending the flags so
/// a path starting with `-` can be named. Anything else is a usage message.
func parseFileArguments(
    _ command: String, _ tail: [String], valueFlags: [String]
) -> Result<FileArguments, UsageMessage> {
    var paths: [String] = []
    var values: [String: String] = [:]
    var index = 0
    var flagsEnded = false
    let grammar = (["<path>"] + valueFlags.map { "[\($0) <\($0.dropFirst(2))>]" }).joined(separator: " ")
    while index < tail.count {
        let token = tail[index]
        if !flagsEnded, token == "--" {
            flagsEnded = true
        } else if !flagsEnded, valueFlags.contains(token) {
            guard values[token] == nil else {
                return .failure(UsageMessage("\(command) takes at most one \(token) flag."))
            }
            guard index + 1 < tail.count, !tail[index + 1].hasPrefix("-") else {
                return .failure(UsageMessage("\(command)'s \(token) requires a value that does not start with '-'."))
            }
            values[token] = tail[index + 1]
            index += 1
        } else if !flagsEnded, token.hasPrefix("-") {
            return .failure(UsageMessage("\(command) takes \(grammar); got the flag '\(token)'."))
        } else {
            paths.append(token)
        }
        index += 1
    }
    guard paths.count == 1, !paths[0].isEmpty else {
        let received = paths.isEmpty ? "none" : "'\(paths.joined(separator: " "))'"
        return .failure(UsageMessage("\(command) requires exactly one repository-relative <path>; got \(received)."))
    }
    return .success(FileArguments(path: paths[0], values: values))
}

/// `switchyard file-history <path> [--revision <rev>]` — the commits that
/// changed one file, newest first, following renames (`git log --follow`,
/// the History half of the app's file inspector). Read-only: no journal
/// entry. The path is repository-relative, as `status` prints it; a path no
/// commit touched is an empty list, not an error.
func runFileHistory(arguments: [String], workingDirectory: String) -> EngineReply {
    let parsed: FileArguments
    switch parseFileArguments("file-history", Array(arguments.dropFirst()), valueFlags: ["--revision"]) {
    case let .success(value): parsed = value
    case let .failure(usage): return engineUsage(usage.text)
    }
    let revision = parsed.values["--revision"] ?? "HEAD"
    do {
        let top = try repositoryTop(workingDirectory)
        let entries: [FileHistory.Entry] = try FileHistory.run(path: top, file: parsed.path, revision: revision)
        return engineSuccess(FileHistoryPayload(
            path: parsed.path, revision: revision, commits: entries.map(FileHistoryCommitPayload.init)))
    } catch {
        return engineFailure(error)
    }
}
