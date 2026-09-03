import Foundation
import YardGit
import YardKit

/// Runs a command that needs the engine, returning the rendered envelope and
/// the exit code — the same pair `runYard` returns, so the app can try this
/// first and fall back to `runYard` for the commands that need no repository.
///
/// Returning `nil` means "not one of mine": it is what lets the app compose
/// this with `runYard` without either side enumerating the other's commands.
public func runEngineCommand(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode)? {
    guard let command = arguments.first else { return nil }

    switch command {
    case "whereami":
        return runWhereAmI(workingDirectory: workingDirectory)
    case "status":
        return runStatus(workingDirectory: workingDirectory)
    case "conflicts":
        return runConflicts(workingDirectory: workingDirectory)
    case "hunks":
        // A one-flag command: `switchyard hunks --staged` arrives as
        // `["hunks", "--staged"]`. The arm parses the area tail itself so a
        // missing or unknown flag is a usage envelope with exit 1 — never a
        // default guess and never a silent ignore (#0345).
        return runHunks(arguments: arguments, workingDirectory: workingDirectory)
    case "log":
        // Zero or more range arguments: `switchyard log` and
        // `switchyard log main..HEAD` both pass their tail through as
        // `rangeArguments`. No option flags exist on this surface (#0346) —
        // any `-`-prefixed token is refused with a usage envelope, before any
        // repository access, so a flag is never silently ignored and never a
        // default guess.
        return runLog(arguments: arguments, workingDirectory: workingDirectory)
    case "graph":
        // One optional flag: `switchyard graph --limit 20` arrives as
        // `["graph", "--limit", "20"]`. The arm parses the tail itself so a
        // malformed or unknown flag is a usage envelope with exit 1 — never
        // a default guess and never a silent ignore (#0347).
        return runGraph(arguments: arguments, workingDirectory: workingDirectory)
    case "wt":
        // A two-token command: `switchyard wt list` arrives as
        // `["wt", "list"]`. Dispatch on the second token so #0228's
        // `wt where` lands beside `wt list` as one more case. A missing or
        // unknown subcommand returns nil so the app's `runYard` fallback
        // answers with its own usage envelope.
        guard arguments.count >= 2 else { return nil }
        switch arguments[1] {
        case "list":
            return runWorktreeList(workingDirectory: workingDirectory)
        case "where":
            return runWorktreeWhere(workingDirectory: workingDirectory)
        default:
            return nil
        }
    default:
        return nil
    }
}

/// `switchyard whereami` — resolves `WorktreeContext` for the **caller's**
/// working directory first, before calling `whereAmI`.
///
/// Measured on this branch (mutation 1, round 1): dropping this explicit
/// call does **not** make the not-a-repository test fail any more, because
/// `whereAmI` itself now resolves `WorktreeContext` internally as of #0140
/// (`WhereAmI.swift:149`) — the `do`/`catch` below already catches that. The
/// original justification here ("`whereAmI` does not throw outside a
/// repository") is stale; it predates #0140 and was corrected in the issue's
/// Given 2 on 2026-08-17.
///
/// The call stays anyway: it is still correct per CLAUDE.md ("every path
/// lookup goes through `WorktreeContext`"), and it documents the gate at
/// this call site for a reader who has not read `whereAmI`'s internals —
/// it is just not load-bearing today, since `whereAmI` would throw on its
/// own either way.
private func runWhereAmI(
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        let result = try whereAmI(path: workingDirectory)
        let envelope = Envelope(result: EncodableResult(result))
        return (stdout: encodeJSON(envelope), stderr: "", exitCode: .success)
    } catch {
        let message = String(describing: error)
        let fail = EnvelopeFail(code: .repositoryError, message: message)
        let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
        return (stdout: encodeJSON(fail), stderr: human, exitCode: .repositoryError)
    }
}

/// `switchyard status` — resolves `WorktreeContext` for the **caller's**
/// working directory first, before calling `gitStatus`. The passed path is
/// the caller's, never `FileManager.default.currentDirectoryPath`, which is
/// the app's.
///
/// `includeIgnored` stays at its default (`false`) — a flag surface is
/// #0010/#0011's, not this issue's.
private func runStatus(
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        let result = try gitStatus(at: workingDirectory)
        let envelope = Envelope(result: EncodableResult(result))
        return (stdout: encodeJSON(envelope), stderr: "", exitCode: .success)
    } catch {
        let message = String(describing: error)
        let fail = EnvelopeFail(code: .repositoryError, message: message)
        let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
        return (stdout: encodeJSON(fail), stderr: human, exitCode: .repositoryError)
    }
}

/// `switchyard conflicts` — resolves `WorktreeContext` for the **caller's**
/// working directory first, before calling `conflictedFiles`. The passed path
/// is the caller's, never `FileManager.default.currentDirectoryPath`, which
/// is the app's.
private func runConflicts(
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        let result = try conflictedFiles(at: workingDirectory)
        let envelope = Envelope(result: EncodableResult(result))
        return (stdout: encodeJSON(envelope), stderr: "", exitCode: .success)
    } catch {
        let message = String(describing: error)
        let fail = EnvelopeFail(code: .repositoryError, message: message)
        let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
        return (stdout: encodeJSON(fail), stderr: human, exitCode: .repositoryError)
    }
}

/// `switchyard wt list` — resolves `WorktreeContext` for the **caller's**
/// working directory first, before calling `worktreeList`. The passed path
/// is the caller's, never `FileManager.default.currentDirectoryPath`, which
/// is the app's. Entry paths may contain newlines; the arm renders JSON
/// only, so porcelain's human-readable form is never involved.
private func runWorktreeList(
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        let result = try worktreeList(path: workingDirectory)
        let envelope = Envelope(result: EncodableResult(result))
        return (stdout: encodeJSON(envelope), stderr: "", exitCode: .success)
    } catch {
        let message = String(describing: error)
        let fail = EnvelopeFail(code: .repositoryError, message: message)
        let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
        return (stdout: encodeJSON(fail), stderr: human, exitCode: .repositoryError)
    }
}

/// `switchyard wt where` — resolves `WorktreeContext` for the **caller's**
/// working directory first, before calling `yardWhere`. The passed path is
/// the caller's, never `FileManager.default.currentDirectoryPath`, which is
/// the app's. `yardWhere` resolves `WorktreeContext` internally as well (and
/// throws outside a repository on its own), so the explicit call here is the
/// same documentation gate the other engine arms keep, not the only check.
private func runWorktreeWhere(
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        let result = try yardWhere(path: workingDirectory)
        let envelope = Envelope(result: EncodableResult(result))
        return (stdout: encodeJSON(envelope), stderr: "", exitCode: .success)
    } catch {
        let message = String(describing: error)
        let fail = EnvelopeFail(code: .repositoryError, message: message)
        let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
        return (stdout: encodeJSON(fail), stderr: human, exitCode: .repositoryError)
    }
}

/// `switchyard hunks` — parses the required area flag, then resolves
/// `WorktreeContext` for the **caller's** working directory before calling
/// `listHunks`. The passed path is the caller's, never
/// `FileManager.default.currentDirectoryPath`, which is the app's.
///
/// `area` is required with no default: exactly one of `--staged` or
/// `--unstaged` maps to `DiffArea.staged`/`.unstaged`. A missing,
/// unparseable, or duplicated flag — any argument tail that is not exactly
/// one known area flag — is refused the way `runYard`'s unknown-subcommand
/// path refuses (`EnvelopeFail(code: .usage, …)`, the human-readable line on
/// stderr, exit 1), and the refusal happens before any repository access, so
/// it does not depend on where the command was run. A thrown engine error is
/// a repository failure at exit 6, like every other arm here.
private func runHunks(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let tail = Array(arguments.dropFirst())
    let area: DiffArea? = {
        guard tail.count == 1 else { return nil }
        switch tail[0] {
        case "--staged": return .staged
        case "--unstaged": return .unstaged
        default: return nil
        }
    }()
    guard let area else {
        let received = tail.isEmpty ? "no area flag" : "'\(tail.joined(separator: " "))'"
        let fail = EnvelopeFail(
            code: .usage,
            message: "hunks requires exactly one area flag, --staged or --unstaged; got \(received).")
        let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
        return (stdout: encodeJSON(fail), stderr: human, exitCode: .usage)
    }

    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        let result = try listHunks(at: workingDirectory, area: area)
        let envelope = Envelope(result: EncodableResult(result))
        return (stdout: encodeJSON(envelope), stderr: "", exitCode: .success)
    } catch {
        let message = String(describing: error)
        let fail = EnvelopeFail(code: .repositoryError, message: message)
        let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
        return (stdout: encodeJSON(fail), stderr: human, exitCode: .repositoryError)
    }
}

/// `switchyard log` — refuses any option flag, then resolves
/// `WorktreeContext` for the **caller's** working directory before calling
/// `CommitLog.run`. The passed path is the caller's, never
/// `FileManager.default.currentDirectoryPath`, which is the app's.
///
/// The argument tail is zero or more range arguments (e.g. `main..HEAD`);
/// an empty tail is the engine's own default (explicit `HEAD`).
/// `CommitLogOptions` stays engine-side: there are no option flags on this
/// surface (#0346), so any `-`-prefixed token — anywhere in the tail — is
/// refused the way `runYard`'s unknown-subcommand path refuses
/// (`EnvelopeFail(code: .usage, …)`, the human-readable line on stderr,
/// exit 1). The refusal happens before any repository access, so it does not
/// depend on where the command was run. A thrown engine error is a
/// repository failure at exit 6, like every other arm here.
private func runLog(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let tail = Array(arguments.dropFirst())
    if let flag = tail.first(where: { $0.hasPrefix("-") }) {
        let fail = EnvelopeFail(
            code: .usage,
            message: "log takes only range arguments (e.g. main..HEAD); got the flag '\(flag)'.")
        let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
        return (stdout: encodeJSON(fail), stderr: human, exitCode: .usage)
    }

    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        let result = try CommitLog.run(path: workingDirectory, rangeArguments: tail)
        let envelope = Envelope(result: EncodableResult(result))
        return (stdout: encodeJSON(envelope), stderr: "", exitCode: .success)
    } catch {
        let message = String(describing: error)
        let fail = EnvelopeFail(code: .repositoryError, message: message)
        let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
        return (stdout: encodeJSON(fail), stderr: human, exitCode: .repositoryError)
    }
}

/// `switchyard graph` — parses the optional limit flag, then resolves
/// `WorktreeContext` for the **caller's** working directory before calling
/// `graphRows`. The passed path is the caller's, never
/// `FileManager.default.currentDirectoryPath`, which is the app's.
///
/// The argument grammar is strict: the only accepted tails are `[]` and
/// `["--limit", "<positive int>"]`. The value must be bare ASCII digits —
/// `Int("+3")` and `Int("-1")` both parse, and a sign, whitespace, or a
/// decimal point is refused before `Int` ever sees it; zero and a digit run
/// too long for `Int` are refused too. The joined form
/// `--limit=3` is refused: one token, not the flag-then-value shape this
/// surface accepts. A duplicated flag, a missing value, or any other token
/// (e.g. `--all` — the app's graph view grows its own revision surface, not
/// this command, #0347) is refused the way `runYard`'s unknown-subcommand
/// path refuses (`EnvelopeFail(code: .usage, …)`, the human-readable line on
/// stderr, exit 1). The refusal happens before any repository access, so it
/// does not depend on where the command was run. `revisions` stays at the
/// engine's default `["HEAD"]`. A thrown engine error is a repository
/// failure at exit 6, like every other arm here.
private func runGraph(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let tail = Array(arguments.dropFirst())
    var limit: Int?
    var usageMessage: String?
    switch tail.count {
    case 0:
        break
    case 2 where tail[0] == "--limit":
        let value = tail[1]
        if !value.isEmpty,
           value.allSatisfy({ ("0"..."9").contains($0) }),
           let parsed = Int(value), parsed > 0 {
            limit = parsed
        } else {
            usageMessage = "graph's --limit takes a positive integer value; got '\(value)'."
        }
    default:
        usageMessage = "graph takes at most one optional --limit <n> flag; got '\(tail.joined(separator: " "))'."
    }
    if let usageMessage {
        let fail = EnvelopeFail(code: .usage, message: usageMessage)
        let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
        return (stdout: encodeJSON(fail), stderr: human, exitCode: .usage)
    }

    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        let result = try graphRows(at: workingDirectory, limit: limit)
        let envelope = Envelope(result: EncodableResult(result))
        return (stdout: encodeJSON(envelope), stderr: "", exitCode: .success)
    } catch {
        let message = String(describing: error)
        let fail = EnvelopeFail(code: .repositoryError, message: message)
        let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
        return (stdout: encodeJSON(fail), stderr: human, exitCode: .repositoryError)
    }
}

/// Mirrors `CommandLineRunner.jsonString(_:)`, which is `internal` to
/// `YardKit` and so not reachable from this target.
private func encodeJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting.insert(.sortedKeys)
    guard let data = try? encoder.encode(value),
          let text = String(data: data, encoding: .utf8) else {
        return #"{"schemaVersion":1,"ok":false,"error":{"code":"request_failed","message":"Failed to encode the response."}}"#
    }
    return text
}
