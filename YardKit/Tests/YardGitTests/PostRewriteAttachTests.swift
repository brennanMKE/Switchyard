// PostRewriteAttachTests.swift — attaching an own-invocation rewrite mapping
// to its in-flight journal entry, end to end (#0221)
//
// The fixture is a real `switchyard`-run rewrite, not a synthesized
// `Decision`: `Fixup.run` (#0039) rebases inside `JournalCheckpoint.around`,
// so the rebase step's `git` subprocess is the checkpoint-scoped one and real
// `post-rewrite` invocations fire with `GitProcess.entryVariable` set in
// their environment. Measured (git 2.50.1, this file's fixture): an
// autosquash rebase fires the hook **twice** — a mid-rebase `amend` for the
// internal fixup application, then a final `rebase` invocation whose mapping
// repeats that pair alongside the rest, matching the shape
// `JournalObserved.swift`'s own doc comment already describes for the
// foreign path. The final invocation is treated as authoritative here for
// the same reason. The hook glue that would read the hook's environment
// inside a real `post-rewrite` script is #0217's to build; this test plays
// that role by hand, reading the same log a hook would have written.

import Foundation
import Testing
@testable import YardGit

private let git = GitProcess()
private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

/// Installs a `post-rewrite` hook that logs, for one invocation: the hook's
/// argument, `GitProcess.entryVariable`'s value (empty line when unset),
/// `GitProcess.markerVariable`'s value (empty line when unset), then stdin
/// verbatim. The hooks directory is resolved through
/// `WorktreeContext.path(for:)` — `git rev-parse --git-path hooks` — never
/// by string concatenation onto `.git/`.
private func installLoggingPostRewriteHook(in repo: FixtureRepository, loggingTo log: URL) throws {
    let context = try WorktreeContext.resolve(path: repo.url.path)
    let hooksDir = try context.path(for: "hooks")
    try FileManager.default.createDirectory(
        atPath: hooksDir, withIntermediateDirectories: true)
    let hookPath = hooksDir + "/post-rewrite"
    let script = """
    #!/bin/sh
    printf '=I= %s\\n' "$1" >> "\(log.path)"
    printf '=E= %s\\n' "${\(GitProcess.entryVariable):-}" >> "\(log.path)"
    printf '=M= %s\\n' "${\(GitProcess.markerVariable):-}" >> "\(log.path)"
    cat >> "\(log.path)"
    exit 0
    """
    try script.write(toFile: hookPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: hookPath)
}

private struct LoggedInvocation {
    let source: String
    /// `nil` when `GitProcess.entryVariable` was unset in the hook's
    /// environment — an own invocation whose git subprocess ran outside any
    /// `JournalCheckpoint.around`.
    let entryID: String?
    let marker: String?
    let stdin: Data
}

/// Parses every invocation the log holds, in order. Measured: an autosquash
/// rebase fires `post-rewrite` **twice** — a mid-rebase `amend` for the
/// internal fixup application (old oid an intermediate commit that never
/// existed pre-rewrite) and a final `rebase` invocation whose mapping
/// repeats that pair alongside the rest — the same shape
/// `JournalObserved.swift`'s own doc comment describes for the foreign path.
/// `=I=` starts a new block; `=E=`/`=M=` are that block's next two lines;
/// everything after is that block's stdin, up to the next `=I=` or EOF.
private func allInvocations(in log: URL) throws -> [LoggedInvocation] {
    let text = try String(contentsOf: log, encoding: .utf8)
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }

    var result: [LoggedInvocation] = []
    var index = 0
    while index < lines.count {
        guard lines[index].hasPrefix("=I= ") else {
            Issue.record("expected =I= at line \(index): \(lines[index])")
            break
        }
        let source = String(lines[index].dropFirst(4))
        let entryID = String(lines[index + 1].dropFirst(4))
        let marker = String(lines[index + 2].dropFirst(4))
        index += 3
        var stdinLines: [String] = []
        while index < lines.count, !lines[index].hasPrefix("=I= ") {
            stdinLines.append(lines[index])
            index += 1
        }
        result.append(LoggedInvocation(
            source: source,
            entryID: entryID.isEmpty ? nil : entryID,
            marker: marker.isEmpty ? nil : marker,
            stdin: Data((stdinLines.map { $0 + "\n" }.joined()).utf8)))
    }
    return result
}

/// The authoritative invocation for a rewrite that ran inside one
/// `JournalCheckpoint.around` — the last one logged, matching the "final
/// invocation alone is authoritative" rule `JournalObserved.swift` already
/// documents for the foreign path.
private func finalInvocation(in log: URL) throws -> LoggedInvocation {
    try #require(try allInvocations(in: log).last)
}

/// Builds a three-commit fixture with `staged.txt` staged, ready for
/// `Fixup.run(target: "c2", ...)`. Returns the repo and `c2`'s oid.
private func fixupFixture() throws -> (repo: FixtureRepository, target: String) {
    var repo = try FixtureRepository()
    try repo.build([.init("c1"), .init("c2"), .init("c3")])
    let target = try #require(repo.oids["c2"])
    try repo.writeUntracked(["staged.txt": "staged content\n"])
    try git.run(["add", "-A"], workingDirectory: repo.url.path)
    return (repo, target)
}

@Suite("Attaching an own rewrite mapping to its in-flight entry")
struct PostRewriteAttachTests {

    @Test func attachingAnOwnFixupRebaseMappingLandsOnTheInFlightEntry() throws {
        let (repo, target) = try fixupFixture()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let log = repo.url.appendingPathComponent("post-rewrite.log")
        try installLoggingPostRewriteHook(in: repo, loggingTo: log)

        #expect(try JournalAnchor.list(in: context).isEmpty)

        _ = try Fixup.run(target: target, at: repo.url.path, extraEnvironment: hermetic)

        // Exactly one checkpoint entry for the whole fixup (#0212) — the one
        // `around` wrote is the in-flight entry the id must have been
        // exported for.
        let entries = try JournalAnchor.list(in: context)
        #expect(entries.count == 1)
        let checkpointEntry = try #require(entries.first)

        let logged = try allInvocations(in: log)
        #expect(logged.count == 2, "a mid-rebase amend, then the authoritative final rebase")
        let invocation = try #require(logged.last)
        #expect(invocation.source == "rebase")
        let entryIDString = try #require(
            invocation.entryID,
            "the rebase ran through the checkpoint-scoped GitProcess and must export the entry id")
        #expect(entryIDString == checkpointEntry.id.string)
        let markerValue = try #require(
            invocation.marker, "switchyard's own invocation must still carry the marker")

        let beforeAttach = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: checkpointEntry.id, in: context))
        #expect(beforeAttach.rewrite == nil)

        let decision = PostRewrite.decide(
            sourceArgument: invocation.source,
            environment: [GitProcess.markerVariable: markerValue],
            readStandardInput: { invocation.stdin })
        #expect(decision.isOwnInvocation)
        #expect(!decision.rewrites.isEmpty, "the rebase must have rewritten at least one commit")

        let entryID = try #require(JournalEntryID(entryIDString))
        let attached = try #require(
            try JournalCheckpoint.attachRewrite(decision, entryID: entryID, in: context))
        #expect(attached.id == checkpointEntry.id)

        let after = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: checkpointEntry.id, in: context))
        let mapping = try #require(after.rewrite)
        #expect(mapping.source == "rebase")
        #expect(mapping.rewrites == decision.rewrites)

        // Every other field comes back byte-identical: comparing the
        // re-read metadata to the pre-attach value with the mapping added
        // by hand (rather than through `attachRewrite` again) proves the
        // persisted bytes, not just the in-memory value, carry every
        // untouched field forward.
        #expect(after == beforeAttach.attachingRewrite(mapping))

        // The rest of the anchor's tree -- everything but metadata.json --
        // and the commit's parents are unchanged, byte for byte.
        let oldTreeLines = try git.run(
            ["ls-tree", checkpointEntry.commit], workingDirectory: repo.url.path
        ).lines.filter { !$0.hasSuffix("\tmetadata.json") }
        let newTreeLines = try git.run(
            ["ls-tree", attached.commit], workingDirectory: repo.url.path
        ).lines.filter { !$0.hasSuffix("\tmetadata.json") }
        #expect(!oldTreeLines.isEmpty)
        #expect(newTreeLines == oldTreeLines)

        let oldParents = try git.run(
            ["cat-file", "-p", checkpointEntry.commit], workingDirectory: repo.url.path
        ).lines.filter { $0.hasPrefix("parent ") }
        let newParents = try git.run(
            ["cat-file", "-p", attached.commit], workingDirectory: repo.url.path
        ).lines.filter { $0.hasPrefix("parent ") }
        #expect(oldParents == newParents)
    }

    /// The honest options for an own invocation with no entry id are
    /// "record nothing" and "fall back to an observed entry" (#0221's
    /// Expected behavior). This picks "record nothing": an own invocation
    /// with no id is one that took no `JournalCheckpoint.around`, so there
    /// is no in-flight entry to attach to, and routing it to an observed
    /// entry would misrepresent it as foreign-sourced -- exactly the
    /// distinction `JournalObserved.Metadata.kind` exists to preserve
    /// (#0220). Nothing is invented and nothing throws; the `nil` return is
    /// the documented, tested signal, not a swallowed failure.
    @Test func noEntryIDRecordsNothingRatherThanInventingOrFallingBackToObserved() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let decision = PostRewrite.decide(
            sourceArgument: "amend",
            environment: [GitProcess.markerVariable: "1"],
            readStandardInput: {
                Data("\(String(repeating: "a", count: 40)) \(String(repeating: "b", count: 40))\n".utf8)
            })
        #expect(decision.isOwnInvocation)

        let attached = try JournalCheckpoint.attachRewrite(decision, entryID: nil, in: context)
        #expect(attached == nil)
        #expect(try JournalAnchor.list(in: context).isEmpty)
        #expect(try JournalObserved.list(in: context).isEmpty)
    }

    /// Attach must target the entry named by `entryID`, never "the newest
    /// entry" -- a later, unrelated checkpoint sits on top of the fixup's
    /// entry by the time attach runs, and only the fixup's own entry may
    /// come back carrying the mapping.
    @Test func attachTargetsTheEntryNamedByIDNotTheNewestEntry() throws {
        let (repo, target) = try fixupFixture()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let log = repo.url.appendingPathComponent("post-rewrite.log")
        try installLoggingPostRewriteHook(in: repo, loggingTo: log)

        _ = try Fixup.run(target: target, at: repo.url.path, extraEnvironment: hermetic)

        let invocation = try finalInvocation(in: log)
        let fixupEntryID = try #require(
            invocation.entryID.flatMap(JournalEntryID.init))
        let markerValue = try #require(invocation.marker)

        let newer = try JournalCheckpoint.checkpoint(operation: "unrelated", in: context)
        #expect(newer.id > fixupEntryID, "the unrelated checkpoint must be the newest entry")

        let decision = PostRewrite.decide(
            sourceArgument: invocation.source,
            environment: [GitProcess.markerVariable: markerValue],
            readStandardInput: { invocation.stdin })

        let attached = try #require(
            try JournalCheckpoint.attachRewrite(decision, entryID: fixupEntryID, in: context))
        #expect(attached.id == fixupEntryID)

        let fixupMetadata = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: fixupEntryID, in: context))
        #expect(fixupMetadata.rewrite != nil)

        let newerMetadata = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: newer.id, in: context))
        #expect(newerMetadata.rewrite == nil, "the unrelated newer entry must be untouched")
    }

    /// The own-path mirror of `JournalObservedTests`'
    /// `aMidRebaseAmendDoesNotProduceItsOwnObservedEntry`: a mid-rebase
    /// `amend` decision, own-sourced and carrying a real in-flight entry id,
    /// attaches nothing (#0233). Before this issue the gate in
    /// `JournalObserved.record(_ decision:)` sat after `guard
    /// !decision.isOwnInvocation`, so it was structurally unreachable here —
    /// `attachRewrite` had no equivalent check at all, and a probe that
    /// routed a real own autosquash's mid-rebase invocation through
    /// `attachRewrite` attached the intermediate, never-existed-before-the-
    /// rewrite mapping. `finalInvocation` (`logged.last`) is not exercised
    /// here on purpose: the production code must do the selecting, not the
    /// test picking the authoritative invocation for it.
    @Test func aMidRebaseAmendAttachesNothingToItsInFlightEntry() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let checkpointEntry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: context)
        let beforeAttach = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: checkpointEntry.id, in: context))
        #expect(beforeAttach.rewrite == nil)

        let rebaseMergePath = try context.path(for: "rebase-merge")
        try FileManager.default.createDirectory(
            atPath: rebaseMergePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: rebaseMergePath) }

        let decision = PostRewrite.decide(
            sourceArgument: "amend",
            environment: [GitProcess.markerVariable: "1"],
            readStandardInput: {
                Data("\(String(repeating: "a", count: 40)) \(String(repeating: "b", count: 40))\n".utf8)
            })
        #expect(decision.isOwnInvocation)

        let attached = try JournalCheckpoint.attachRewrite(
            decision, entryID: checkpointEntry.id, in: context)
        #expect(attached == nil, "a mid-rebase amend must not attach to its in-flight entry")

        let after = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: checkpointEntry.id, in: context))
        #expect(after.rewrite == nil, "the entry's metadata must still carry no rewrite mapping")
    }

    // MARK: - The compare-and-swap guard

    /// `updateRefCommand`'s literal output, old oid included. `update-ref
    /// --stdin`'s `update` verb treats `<old>` as optional -- a line with
    /// only `<ref>` and `<new>` is valid input and means "write
    /// unconditionally" -- so this is not incidental formatting: dropping
    /// the third field silently downgrades a guarded write to an unguarded
    /// one, with no parse error to catch it. Pinned the same way every other
    /// wire-shaped literal in this codebase is.
    @Test func updateRefCommandIncludesTheOldOidAsTheCompareAndSwap() {
        // `JournalAnchor.refPrefix`, not a hardcoded literal -- ServiceNames
        // owns that string (`ServiceNamesTests.noOtherSwiftSourceHardcodesTheIdentifiers`).
        let ref = JournalAnchor.refPrefix + "01K1H8R100W7CBVX5TRJJEDDVM"
        let command = JournalAnchor.updateRefCommand(
            ref: ref,
            new: String(repeating: "1", count: 40),
            old: String(repeating: "2", count: 40))
        #expect(command ==
            "update \(ref) \(String(repeating: "1", count: 40)) \(String(repeating: "2", count: 40))\n")
    }

    /// The real race the compare-and-swap exists for, reproduced with actual
    /// git state rather than mocked or relying on thread scheduling to land
    /// it (AGENTS.md Rule 7c: this suite runs seventy suites in parallel and
    /// scheduling is not a fact to depend on, so a real concurrent-task race
    /// would be flaky rather than deterministic here).
    ///
    /// Two writers both read the entry's original commit as `current`. One
    /// applies its update first through the real `updateMetadata` path,
    /// moving the ref forward. The other -- built here from
    /// `updateRefCommand` using the same stale `current` the first writer
    /// started from, exactly what a second concurrent writer would have
    /// sent -- must be rejected by git itself, not silently applied, and the
    /// ref must still point at the winner's commit afterward.
    @Test func aStaleCompareAndSwapLosesRatherThanSilentlyOverwriting() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: context)
        let staleCurrent = entry.commit

        let winner = try JournalAnchor.updateMetadata(
            Data(#"{"writer":"first"}"#.utf8), for: entry.id, in: context)
        #expect(winner.commit != staleCurrent, "the winner must have actually moved the ref")

        let ref = JournalAnchor.refPrefix + entry.id.string
        let loserCommand = JournalAnchor.updateRefCommand(
            ref: ref, new: staleCurrent, old: staleCurrent)
        let loserResult = try git.capture(
            ["update-ref", "--stdin"], workingDirectory: repo.url.path,
            standardInput: Data(loserCommand.utf8))
        #expect(loserResult.exitCode != 0,
                "a compare-and-swap against a stale old value must be rejected")

        let final = try git.run(
            ["rev-parse", "--verify", ref], workingDirectory: repo.url.path
        ).lines.first
        #expect(final == winner.commit, "the ref must still point at whoever actually won")
    }
}
