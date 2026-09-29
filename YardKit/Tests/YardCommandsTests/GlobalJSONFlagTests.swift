// GlobalJSONFlagTests.swift

import Foundation
import Testing
@testable import YardCommands
@testable import YardKit

/// #0420: `--json` is accepted by every command (CLAUDE.md, "The agent
/// surface"). One valid argv per registered command; appending `--json`
/// must produce exactly what the argv produces without it.
///
/// Engine and local commands go through the composition the app and
/// `yard-engine` both use, `runEngineCommand ?? runYard`, in a directory
/// that is not a repository: every parser runs before repository access,
/// so a valid argv ends in a repository or request failure (or success, for
/// `noop` and `schema`) and never in usage. The four arms that only
/// `dispatch` answers (`review`, `ask`, `resolve`, `watch`) go through
/// `dispatch` with connectors that throw, so a valid argv ends at exit 3.
struct GlobalJSONFlagTests {

    /// A valid argv for every name in `CommandRegistry.all` except the
    /// top-level `switchyard` spec, which is the program, not a command.
    static let composedArgv: [String: [String]] = [
        "noop": ["noop"],
        "skill": ["skill"],
        "whereami": ["whereami"],
        "status": ["status"],
        "conflicts": ["conflicts"],
        "wt": ["wt", "list"],
        "wt where": ["wt", "where"],
        "hunks": ["hunks", "--staged"],
        "log": ["log"],
        "graph": ["graph", "--limit", "5"],
        "verify": ["verify", "HEAD"],
        "absorb": ["absorb", "--dry-run"],
        "split": ["split", "HEAD", "h", "--first", "m"],
        "reword": ["reword", "HEAD", "--message", "m"],
        "drop": ["drop", "HEAD"],
        "reorder": ["reorder", "HEAD", "--after", "HEAD"],
        "revert": ["revert", "HEAD"],
        "cherry-pick": ["cherry-pick", "HEAD"],
        "merge": ["merge", "main", "--ff-only"],
        "rewrite-diff": ["rewrite-diff", "0123456789ABCDEFGHJKMNPQRS"],
        "rerere": ["rerere", "status"],
        "tag": ["tag", "v1", "HEAD"],
        "branch": ["branch", "create", "b", "HEAD"],
        "rebase-onto": ["rebase-onto", "HEAD"],
        "set-tip": ["set-tip", "HEAD"],
        "stage": ["stage", "a.txt"],
        "unstage": ["unstage", "a.txt"],
    ]

    static let dispatchArgv: [String: [String]] = [
        "review": ["review", "--staged", "--wait"],
        "ask": ["ask", "Ship it?", "--options", "yes,no"],
        "resolve": ["resolve", "--wait"],
        "watch": ["watch"],
    ]

    /// A command added to the registry without a row here fails this test,
    /// so the sweep below cannot silently skip it.
    @Test func everyRegisteredCommandHasAnArgv() {
        let registered = Set(CommandRegistry.all.map(\.name)).subtracting(["switchyard"])
        let covered = Set(Self.composedArgv.keys).union(Self.dispatchArgv.keys)
        #expect(registered == covered)
    }

    @Test(arguments: composedArgv.keys.sorted())
    func jsonFlagChangesNothingThroughTheComposition(command: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-json-flag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let argv = try #require(Self.composedArgv[command])

        func run(_ arguments: [String]) -> (stdout: String, stderr: String, exitCode: ExitCode) {
            runEngineCommand(arguments: arguments, workingDirectory: directory.path)
                ?? runYard(arguments: arguments)
        }
        let plain = run(argv)
        let flagged = run(argv + ["--json"])

        #expect(plain.exitCode != .usage, "the table's argv for \(command) must be valid")
        #expect(flagged.exitCode == plain.exitCode, "\(command) --json: \(flagged.stdout)")
        #expect(flagged.stdout == plain.stdout)
    }

    @Test(arguments: dispatchArgv.keys.sorted())
    func jsonFlagChangesNothingThroughDispatch(command: String) async throws {
        let argv = try #require(Self.dispatchArgv[command])

        func run(_ arguments: [String]) async -> (stdout: String, stderr: String, exitCode: ExitCode) {
            await dispatch(
                arguments: arguments,
                workingDirectory: "/",
                connect: { throw AppConnectionError.appUnavailable },
                connectHook: { throw AppConnectionError.appUnavailable },
                connectReview: { throw AppConnectionError.appUnavailable },
                connectAsk: { throw AppConnectionError.appUnavailable },
                connectResolve: { throw AppConnectionError.appUnavailable },
                connectWatch: { _ in throw AppConnectionError.appUnavailable },
                emitWatch: nil)
        }
        let plain = await run(argv)
        let flagged = await run(argv + ["--json"])

        #expect(plain.exitCode == .appUnavailable, "the table's argv for \(command) must parse")
        #expect(flagged.exitCode == plain.exitCode, "\(command) --json: \(flagged.stdout)")
    }

    /// `yard-engine --json` reaches `runYard` with the flag still in place
    /// (`runEngineCommand` returns nil for it), so `runYard` must remove it
    /// too: the bare flag is the bare invocation, not an unknown subcommand.
    @Test func aBareJSONFlagIsTheBareInvocation() {
        let flagged = runEngineCommand(arguments: ["--json"], workingDirectory: "/")
            ?? runYard(arguments: ["--json"])
        #expect(flagged.exitCode == .success)
        #expect(flagged.stdout == runYard(arguments: []).stdout)
    }

    @Test func aFlagValueThatIsLiterallyJSONIsKept() {
        #expect(removingGlobalJSONFlag(["reword", "HEAD", "--message", "--json"])
            == ["reword", "HEAD", "--message", "--json"])
        #expect(removingGlobalJSONFlag(["--json", "graph", "--json", "--limit", "5", "--json"])
            == ["graph", "--limit", "5"])
        #expect(removingGlobalJSONFlag(["hook", "ref-txn", "--json"]) == ["hook", "ref-txn", "--json"])
    }
}
