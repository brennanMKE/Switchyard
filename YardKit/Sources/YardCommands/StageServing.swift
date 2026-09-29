// StageServing.swift — the `stage` and `unstage` arms in `runEngineCommand`
// (guide §11 decision 37)

import Foundation
import YardGit
import YardKit

/// What `stage`, `unstage` and `discard` act on: whole paths, or hunks by
/// the stable id `switchyard hunks` prints. Exactly one form per call.
enum ChangeSelection: Equatable {
    case paths([String])
    case hunks([String])
}

/// The payload of `stage`, `unstage` and `discard`: what was acted on,
/// echoed back. Exactly one key is present — `paths` for the path form,
/// `hunks` for `--hunk`.
struct ChangeSelectionPayload: Encodable, Sendable, Equatable {
    let paths: [String]?
    let hunks: [String]?

    init(_ selection: ChangeSelection) {
        switch selection {
        case let .paths(paths): self.paths = paths; hunks = nil
        case let .hunks(ids): paths = nil; hunks = ids
        }
    }
}

/// Parses `(<path>... | --hunk <id>...)`: one or more positionals, or one or
/// more `--hunk <id>` pairs, never both. A token after `--` is always a
/// path, so a file named `--hunk` can still be staged. Returns the
/// selection, or the usage message.
func parseChangeSelection(
    _ tail: [String], command: String
) -> Result<ChangeSelection, UsageMessage> {
    var paths: [String] = []
    var hunks: [String] = []
    var index = 0
    var literal = false
    while index < tail.count {
        let token = tail[index]
        if literal {
            paths.append(token)
        } else if token == "--" {
            literal = true
        } else if token == "--hunk" {
            guard index + 1 < tail.count else {
                return .failure(UsageMessage("\(command)'s --hunk requires a hunk id; got none."))
            }
            hunks.append(tail[index + 1])
            index += 1
        } else if token.hasPrefix("-") {
            return .failure(UsageMessage(
                "\(command) takes one or more <path> arguments or --hunk <id> flags; "
                    + "got the unknown flag '\(token)'."))
        } else {
            paths.append(token)
        }
        index += 1
    }
    switch (paths.isEmpty, hunks.isEmpty) {
    case (false, true): return .success(.paths(paths))
    case (true, false): return .success(.hunks(hunks))
    case (false, false):
        return .failure(UsageMessage("\(command) takes paths or --hunk ids, not both."))
    case (true, true):
        return .failure(UsageMessage(
            "\(command) requires one or more <path> arguments or --hunk <id> flags; got none."))
    }
}

/// A usage refusal's message, as a `Result` failure.
struct UsageMessage: Error, Equatable {
    let text: String
    init(_ text: String) { self.text = text }
}

/// `switchyard stage` and `switchyard unstage`. Paths are repository-
/// relative and literal (`--literal-pathspecs`); hunk ids come from
/// `switchyard hunks --unstaged` (stage) or `--staged` (unstage). One
/// journal entry per call, operation `stage` or `unstage`.
func runStage(arguments: [String], workingDirectory: String) -> EngineReply {
    let command = arguments.first ?? "stage"
    let selection: ChangeSelection
    switch parseChangeSelection(Array(arguments.dropFirst()), command: command) {
    case let .success(parsed): selection = parsed
    case let .failure(usage): return engineUsage(usage.text)
    }
    do {
        let top = try repositoryTop(workingDirectory)
        switch (command, selection) {
        case let ("stage", .paths(paths)):
            try stagePaths(paths, at: top)
        case let ("stage", .hunks(ids)):
            try stageHunks(ids: ids, at: top)
        case let (_, .paths(paths)):
            try unstagePaths(withRenameSources(paths, at: top), at: top)
        case let (_, .hunks(ids)):
            try unstageHunks(ids: ids, at: top)
        }
        return engineSuccess(ChangeSelectionPayload(selection))
    } catch {
        return engineFailure(error)
    }
}

/// `paths` plus the original path of every staged rename among them: `git
/// status` reports a rename as one record named by its new path, and
/// resetting only that leaves the old path staged as a deletion (#0439).
private func withRenameSources(_ paths: [String], at top: String) throws -> [String] {
    let requested = Set(paths)
    let sources = try gitStatus(at: top).entries.compactMap { entry in
        requested.contains(entry.path) ? entry.originalPath : nil
    }
    return paths + sources.filter { !requested.contains($0) }
}
