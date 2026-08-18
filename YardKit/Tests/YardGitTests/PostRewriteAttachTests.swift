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

    /// The honest options for an own invocation with no entry id anywhere
    /// are "record nothing" and "fall back to an observed entry" (#0221's
    /// Expected behavior). This picks "record nothing": with no
    /// `entryVariable` in the environment and no `inFlightEntryIDRelativePath`
    /// file on disk either (#0237, guide §11 decision 19), there is no
    /// in-flight entry to attach to, and routing it to an observed entry
    /// would misrepresent it as foreign-sourced -- exactly the distinction
    /// `JournalObserved.Metadata.kind` exists to preserve (#0220). Nothing is
    /// invented and nothing throws; the `nil` return is the documented,
    /// tested signal, not a swallowed failure.
    @Test func noEntryIDAndNoFileRecordsNothingRatherThanInventingOrFallingBackToObserved() throws {
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

    /// A file naming a pruned or fabricated entry id must degrade to
    /// today's no-attach behaviour, not attach to whatever else this
    /// worktree happens to have recorded -- "the part most likely to be got
    /// wrong" per #0237's own issue text. Written by hand at
    /// `RepositoryLayout.inFlightEntryIDRelativePath`, resolved exactly the
    /// way `JournalCheckpoint.around` resolves it, rather than through
    /// `around` itself, so the fixture can plant an id that is guaranteed
    /// never to have existed.
    @Test func aStaleFileAttachesNothingAndIsRemoved() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let fabricated = try #require(JournalEntryID(String(repeating: "0", count: JournalEntryID.length)))
        let pendingPath = try context.path(for: RepositoryLayout.inFlightEntryIDRelativePath)
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: pendingPath).deletingLastPathComponent().path,
            withIntermediateDirectories: true)
        try fabricated.string.write(toFile: pendingPath, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: pendingPath))
        #expect(try JournalAnchor.list(in: context).isEmpty, "the fabricated id must name nothing real")

        let decision = PostRewrite.decide(
            sourceArgument: "amend",
            environment: [GitProcess.markerVariable: "1"],
            readStandardInput: {
                Data("\(String(repeating: "a", count: 40)) \(String(repeating: "b", count: 40))\n".utf8)
            })
        #expect(decision.isOwnInvocation)

        let attached = try JournalCheckpoint.attachRewrite(decision, entryID: nil, in: context)
        #expect(attached == nil, "a stale file must attach nothing, never an unrelated entry")
        #expect(try JournalAnchor.list(in: context).isEmpty)
        #expect(try JournalObserved.list(in: context).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pendingPath),
                "the stale file must be removed once it is found unresolvable")
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

    /// #0237's own probe, made a test: a conflicting `Fixup.run(target:)`
    /// stops with the rebase in progress -- `Fixup.run`'s scoped `GitProcess`
    /// stops existing at the throw -- and whatever runs `git rebase
    /// --continue` afterwards is a brand new, unscoped `GitProcess`: an own
    /// invocation with no `entryVariable` in its environment. Before this
    /// issue that quadrant attached nothing anywhere (probed with c1/c2/c3
    /// all touching `f.txt`, staged content that conflicts on replay --
    /// `FixupTests.conflictBlocksAndLeavesTheRebaseResumable`'s own fixture
    /// shape). Now the mapping must land on the entry `around` wrote before
    /// the rebase started, found through the file at
    /// `RepositoryLayout.inFlightEntryIDRelativePath` rather than the
    /// environment.
    @Test func aConflictingFixupResolvedAndContinuedAttachesToItsPreOperationEntry() throws {
        var repo = try FixtureRepository()
        try repo.build([
            .init("c1", files: ["f.txt": "a\n"]),
            .init("c2", files: ["f.txt": "b\n"]),
            .init("c3", files: ["f.txt": "c\n"]),
        ])
        defer { repo.destroy() }
        let target = try #require(repo.oids["c2"])
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let log = repo.url.appendingPathComponent("post-rewrite.log")
        try installLoggingPostRewriteHook(in: repo, loggingTo: log)

        let headBefore = try #require(
            git.run(["rev-parse", "HEAD"], workingDirectory: repo.url.path).lines.first)

        try repo.writeUntracked(["f.txt": "z\n"])
        try git.run(["add", "-A"], workingDirectory: repo.url.path)

        let thrown = #expect(throws: FixupError.self) {
            _ = try Fixup.run(target: target, at: repo.url.path, extraEnvironment: hermetic)
        }
        guard case .blockedOnConflicts = try #require(thrown) else {
            Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
            return
        }
        #expect(repo.isMidRebase, "the rebase must be left resumable, not aborted")

        // Exactly one entry -- the one `around` wrote before the rebase
        // started, and the one the in-flight file must now be pointing at.
        let entries = try JournalAnchor.list(in: context)
        #expect(entries.count == 1)
        let checkpointEntry = try #require(entries.first)
        let beforeAttach = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: checkpointEntry.id, in: context))
        #expect(beforeAttach.rewrite == nil)

        // Resolve and continue through a brand new, UNSCOPED GitProcess --
        // the exact process boundary #0237 is about. The autosquash reorders
        // the fixup right after its target, so this fixture's conflicting
        // content conflicts twice on replay (the squash, then `c3`'s own
        // diff against the squashed tree) -- loop until the rebase reports
        // done, bounded so a real failure to converge fails loudly rather
        // than hanging.
        let continueGit = GitProcess()
        let continueEnvironment = hermetic.merging(["GIT_EDITOR": "true"]) { _, new in new }
        for _ in 0..<5 where repo.isMidRebase {
            if repo.hasConflicts {
                try repo.writeUntracked(["f.txt": "resolved\n"])
                try git.run(["add", "-A"], workingDirectory: repo.url.path)
            }
            _ = try continueGit.capture(
                ["rebase", "--continue"], workingDirectory: repo.url.path,
                extraEnvironment: continueEnvironment)
        }
        #expect(!repo.isMidRebase, "the continue loop must have finished the rebase")

        // Only the final invocation is replayed, exactly as
        // `attachingAnOwnFixupRebaseMappingLandsOnTheInFlightEntry` above
        // replays a successful autosquash: `isMidRebaseAmend`'s check is a
        // LIVE read of whether `rebase-merge` exists right now, which only
        // answers correctly at the moment each hook actually fires. Replayed
        // after the whole rebase has finished and torn that directory down,
        // the mid-rebase `amend` would misclassify as foreign-to-rebase and
        // consume the in-flight file itself, starving the authoritative
        // final invocation of the very id it needs -- a replay artifact, not
        // a claim about production, where the mid-rebase invocation fires
        // while the directory is still live and is filtered correctly.
        let invocation = try finalInvocation(in: log)
        #expect(invocation.source == "rebase")
        #expect(invocation.entryID == nil,
                "the continue ran through an unscoped GitProcess and must export no entry id")
        let decision = PostRewrite.decide(
            sourceArgument: invocation.source,
            environment: [GitProcess.markerVariable: invocation.marker ?? ""],
            readStandardInput: { invocation.stdin })
        #expect(decision.isOwnInvocation, "the marker must still be set on our own continue")
        _ = try #require(try JournalCheckpoint.attachRewrite(decision, entryID: nil, in: context))

        let after = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: checkpointEntry.id, in: context))
        let mapping = try #require(
            after.rewrite, "the mapping must be findable, attached to the pre-operation entry")

        let head = try #require(
            git.run(["rev-parse", "HEAD"], workingDirectory: repo.url.path).lines.first)
        let fromHeadBefore = try #require(
            mapping.rewrites.first(where: { $0.oldOid == headBefore }),
            "the entry's snapshot HEAD must be reachable through the stored mapping")
        #expect(fromHeadBefore.newOid == head)

        #expect(try JournalObserved.list(in: context).isEmpty,
                "the mapping belongs on the journal entry that captured pre-operation state, not as an observed one")
    }

    /// #0234's own test: `Fixup.run(source:target:)` (#0214's existing-commit
    /// mode) fires **three** `post-rewrite` invocations for one operation — a
    /// standalone `amend` (`headBefore → mid`), a mid-rebase `amend` that
    /// #0233 already filters, and the final `rebase` (`mid → head`, plus
    /// `target`'s own rewrite). Attaching each invocation as it arrives must
    /// leave the entry's pre-checkpoint `HEAD` reachable through the stored
    /// mapping — the assertion this issue exists for, not merely that the
    /// mapping is non-empty.
    @Test func attachingAnExistingCommitFixupMappingKeepsThePreCheckpointHeadReachable() throws {
        var repo = try FixtureRepository()
        try repo.build([.init("c1"), .init("c2"), .init("c3")])
        defer { repo.destroy() }
        let target = try #require(repo.oids["c2"])
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let log = repo.url.appendingPathComponent("post-rewrite.log")
        try installLoggingPostRewriteHook(in: repo, loggingTo: log)

        let headBefore = try #require(
            git.run(["rev-parse", "HEAD"], workingDirectory: repo.url.path).lines.first)

        #expect(try JournalAnchor.list(in: context).isEmpty)

        let result = try Fixup.run(
            source: "HEAD", target: target, at: repo.url.path, extraEnvironment: hermetic)

        let entries = try JournalAnchor.list(in: context)
        #expect(entries.count == 1)
        let checkpointEntry = try #require(entries.first)

        let logged = try allInvocations(in: log)
        #expect(logged.count == 3,
                "a standalone amend, a mid-rebase amend, then the authoritative final rebase")

        // Attach every invocation in order, exactly as the real hook would
        // fire them across the lifetime of one operation.
        for invocation in logged {
            let decision = PostRewrite.decide(
                sourceArgument: invocation.source,
                environment: [GitProcess.markerVariable: invocation.marker ?? ""],
                readStandardInput: { invocation.stdin })
            let entryIDString = try #require(invocation.entryID)
            let entryID = try #require(JournalEntryID(entryIDString))
            #expect(entryID == checkpointEntry.id)
            _ = try JournalCheckpoint.attachRewrite(decision, entryID: entryID, in: context)
        }

        let after = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: checkpointEntry.id, in: context))
        let mapping = try #require(after.rewrite)
        #expect(!mapping.rewrites.isEmpty)

        // The assertion that matters: the entry's pre-checkpoint HEAD must
        // be reachable through the stored mapping, chained to the operation's
        // actual result — not merely present somewhere, and not lost behind
        // the intermediate commit the mid-rebase amend named.
        let fromHeadBefore = try #require(
            mapping.rewrites.first(where: { $0.oldOid == headBefore }),
            "headBefore must be reachable through the stored mapping")
        #expect(fromHeadBefore.newOid == result.head)
    }

    // MARK: - #0241: the in-flight file names an in-progress operation

    /// #0241's first probe, made a test: a fixup whose signing fails
    /// *during the rebase* runs `git rebase --abort` and throws
    /// (`Fixup.classifiedRebaseFailure`'s signing branch, the same arm
    /// `FixupTests.signingSucceedsForTheFixupCommitThenFailsDuringTheRebase`
    /// exercises). Before this issue, `JournalCheckpoint.around` wrote the
    /// in-flight file unconditionally before `body` ran and only ever
    /// removed it on a normal return, so the abort left the file behind
    /// naming the abandoned fixup's own entry. A later, unrelated own
    /// rewrite -- here a plain `git commit --amend` with signing turned back
    /// off -- would then read that stale file back and attach to an entry
    /// that has nothing to do with it. Now the file must never exist at all
    /// once the abort has run, and the later rewrite must attach nothing.
    @Test func anAbandonedFixupAbortLeavesNoFileAndALaterUnrelatedRewriteAttachesNothing() throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }
        try repo.build([.init("c1"), .init("c2"), .init("c3")])
        let target = try #require(repo.oids["c2"])
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let log = repo.url.appendingPathComponent("post-rewrite.log")
        try installLoggingPostRewriteHook(in: repo, loggingTo: log)

        try git.run(["config", "commit.gpgsign", "true"], workingDirectory: repo.url.path)
        try git.run(["config", "gpg.format", "openpgp"], workingDirectory: repo.url.path)
        // Succeeds once (the `git commit --fixup=` step), then fails every
        // call after (the rebase's own signature attempt) -- the same shape
        // `FixupTests.succeedThenFailGpgScript(succeedingCalls: 1)` uses, to
        // land inside `classifiedRebaseFailure`'s signing/abort branch
        // rather than `classifiedCommitFailure`, which never touches the
        // sequencer at all.
        let gpgScript = """
        #!/bin/sh
        cat > /dev/null
        count_file="gpg-call-count.txt"
        count=0
        if [ -f "$count_file" ]; then count=$(wc -c < "$count_file" | tr -d ' '); fi
        printf 'x' >> "$count_file"
        if [ "$count" -lt 1 ]; then
            printf '[GNUPG:] SIG_CREATED D\\n' >&2
            printf -- '-----BEGIN PGP SIGNATURE-----\\n\\nfakefakefakefake\\n-----END PGP SIGNATURE-----\\n'
            exit 0
        else
            echo "gpg: signing failed: No secret key" >&2
            exit 2
        fi
        """
        try repo.writeUntracked(["fake-gpg.sh": gpgScript])
        let gpgPath = repo.url.appendingPathComponent("fake-gpg.sh").path
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gpgPath)
        try git.run(["config", "gpg.program", gpgPath], workingDirectory: repo.url.path)

        try repo.writeUntracked(["staged.txt": "staged content\n"])
        try git.run(["add", "-A"], workingDirectory: repo.url.path)

        let thrown = #expect(throws: FixupError.self) {
            _ = try Fixup.run(target: target, signing: .config, at: repo.url.path, extraEnvironment: hermetic)
        }
        guard case .signingFailed = try #require(thrown) else {
            Issue.record("expected .signingFailed, got \(String(describing: thrown))")
            return
        }
        #expect(!repo.isMidRebase, "the signing failure must abort the rebase, not leave it resumable")

        let pendingPath = try context.path(for: RepositoryLayout.inFlightEntryIDRelativePath, git: git)
        #expect(!FileManager.default.fileExists(atPath: pendingPath),
                "an operation that aborted before throwing must leave no in-flight file")

        let entries = try JournalAnchor.list(in: context)
        #expect(entries.count == 1, "just the pre-operation checkpoint for the abandoned fixup")
        let abandoned = try #require(entries.first)

        // A later, unrelated own rewrite -- signing turned back off, since
        // the fake gpg above only ever succeeds once.
        try git.run(["config", "commit.gpgsign", "false"], workingDirectory: repo.url.path)
        try git.run(
            ["commit", "--amend", "--no-edit"], workingDirectory: repo.url.path,
            extraEnvironment: hermetic.merging(["GIT_EDITOR": "true"]) { _, new in new })

        let invocation = try finalInvocation(in: log)
        #expect(invocation.source == "amend")
        #expect(invocation.entryID == nil, "the amend ran through an unscoped GitProcess")
        let markerValue = try #require(invocation.marker)
        let decision = PostRewrite.decide(
            sourceArgument: invocation.source,
            environment: [GitProcess.markerVariable: markerValue],
            readStandardInput: { invocation.stdin })
        #expect(decision.isOwnInvocation)

        let attached = try JournalCheckpoint.attachRewrite(decision, entryID: nil, in: context)
        #expect(attached == nil, "an abandoned entry must never capture a later, unrelated rewrite")

        let after = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: abandoned.id, in: context))
        #expect(after.rewrite == nil, "the abandoned fixup's own entry must stay untouched")
    }

    /// #0241's second probe, made a test: a conflicting fixup leaves the
    /// in-flight file naming its own entry; a wholly unrelated, fully
    /// successful `JournalCheckpoint.around` call runs in between; then the
    /// rebase is resolved and continued. Before this issue `around` wrote
    /// the file unconditionally at the start of *every* call and removed it
    /// on every normal return, so the unrelated call clobbered the fixup's
    /// entry on the way in and erased it on the way out -- by the time the
    /// continue ran, there was nothing left to attach to. The unrelated
    /// call must now touch neither the file's presence nor its contents.
    @Test func anUnrelatedSuccessfulOperationBetweenAConflictAndItsContinueDoesNotClobberTheSlot() throws {
        var repo = try FixtureRepository()
        try repo.build([
            .init("c1", files: ["f.txt": "a\n"]),
            .init("c2", files: ["f.txt": "b\n"]),
            .init("c3", files: ["f.txt": "c\n"]),
        ])
        defer { repo.destroy() }
        let target = try #require(repo.oids["c2"])
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let log = repo.url.appendingPathComponent("post-rewrite.log")
        try installLoggingPostRewriteHook(in: repo, loggingTo: log)

        try repo.writeUntracked(["f.txt": "z\n"])
        try git.run(["add", "-A"], workingDirectory: repo.url.path)

        let thrown = #expect(throws: FixupError.self) {
            _ = try Fixup.run(target: target, at: repo.url.path, extraEnvironment: hermetic)
        }
        guard case .blockedOnConflicts = try #require(thrown) else {
            Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
            return
        }
        #expect(repo.isMidRebase, "the rebase must be left resumable, not aborted")

        let entries = try JournalAnchor.list(in: context)
        #expect(entries.count == 1)
        let fixupEntry = try #require(entries.first)

        let pendingPath = try context.path(for: RepositoryLayout.inFlightEntryIDRelativePath, git: git)
        let beforeContents = try #require(
            try? String(contentsOfFile: pendingPath, encoding: .utf8),
            "the conflict must leave the in-flight file naming the fixup's own entry")
        #expect(beforeContents.trimmingCharacters(in: .whitespacesAndNewlines) == fixupEntry.id.string)

        // A wholly unrelated, fully successful `around` in the same
        // worktree -- must not touch the fixup's slot at all.
        _ = try JournalCheckpoint.around(operation: "unrelated", at: repo.url.path, git: git) { _ in 0 }

        let afterUnrelated = try #require(try? String(contentsOfFile: pendingPath, encoding: .utf8))
        #expect(afterUnrelated == beforeContents,
                "a successful unrelated operation must not overwrite or remove the fixup's in-flight file")

        let entriesAfterUnrelated = try JournalAnchor.list(in: context)
        #expect(entriesAfterUnrelated.count == 2, "the unrelated operation checkpoints its own entry too")

        let continueGit = GitProcess()
        let continueEnvironment = hermetic.merging(["GIT_EDITOR": "true"]) { _, new in new }
        for _ in 0..<5 where repo.isMidRebase {
            if repo.hasConflicts {
                try repo.writeUntracked(["f.txt": "resolved\n"])
                try git.run(["add", "-A"], workingDirectory: repo.url.path)
            }
            _ = try continueGit.capture(
                ["rebase", "--continue"], workingDirectory: repo.url.path,
                extraEnvironment: continueEnvironment)
        }
        #expect(!repo.isMidRebase, "the continue loop must have finished the rebase")

        let invocation = try finalInvocation(in: log)
        #expect(invocation.source == "rebase")
        #expect(invocation.entryID == nil,
                "the continue ran through an unscoped GitProcess and must export no entry id")
        let decision = PostRewrite.decide(
            sourceArgument: invocation.source,
            environment: [GitProcess.markerVariable: invocation.marker ?? ""],
            readStandardInput: { invocation.stdin })
        #expect(decision.isOwnInvocation)

        let attached = try #require(try JournalCheckpoint.attachRewrite(decision, entryID: nil, in: context))
        #expect(attached.id == fixupEntry.id,
                "the mapping must land on the fixup's own entry, not the unrelated one")

        let unrelatedID = try #require(
            entriesAfterUnrelated.first(where: { $0.id != fixupEntry.id })?.id)
        let unrelatedMetadata = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: unrelatedID, in: context))
        #expect(unrelatedMetadata.rewrite == nil, "the unrelated entry must stay untouched")
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

    // MARK: - Three `attachRewrite` decisions nothing pinned (#0255)

    /// A dummy rewrite pair, shaped like real hex object names -- these
    /// three tests never inspect the mapping's content, only which entry (if
    /// any) it landed on.
    private static let dummyOldOid = String(repeating: "a", count: 40)
    private static let dummyNewOid = String(repeating: "b", count: 40)

    /// **1 of 3.** Deleting `guard decision.isOwnInvocation else { return
    /// nil }` from `attachRewrite` left the whole suite green (#0255's
    /// Finding 1) -- the mirror of `JournalObservedTests
    /// .anOwnInvocationDecisionWritesNothing`, which pins the opposite half
    /// of this same boundary (#0220) for `JournalObserved.record`.
    ///
    /// A **foreign** decision, with the in-flight file present and naming a
    /// live entry, must attach nothing -- `entryID` is `nil`, so without the
    /// guard the file alone is enough to resolve an id and attach to it.
    ///
    /// The file names a real `checkpoint` entry sitting behind a genuinely
    /// live rebase (an empty `rebase-merge` directory, which is all
    /// `SequencerSnapshot.capture` checks for). That is deliberate, not
    /// incidental: #0253 is landing at the same time and will make
    /// `inFlightEntryID` require `SequencerSnapshot.capture(in:) != nil`
    /// before trusting the file at all. Without a live rebase here, a
    /// mutant that reads the file anyway would find `inFlightEntryID`
    /// answering `nil` regardless -- for the wrong reason -- and this test
    /// would redden today and pass again, silently, the moment #0253 lands.
    /// With a live rebase, the mutant's file read succeeds either way, so
    /// the guard is what this test is actually pinned to.
    @Test func aForeignDecisionWithALiveFilePresentAttachesNothing() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let liveEntry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: context)
        let pendingPath = try context.path(for: RepositoryLayout.inFlightEntryIDRelativePath)
        try liveEntry.id.string.write(toFile: pendingPath, atomically: true, encoding: .utf8)

        let rebaseMergePath = try context.path(for: "rebase-merge")
        try FileManager.default.createDirectory(
            atPath: rebaseMergePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: rebaseMergePath) }

        let decision = PostRewrite.decide(
            sourceArgument: "rebase",
            environment: [:],
            readStandardInput: {
                Data("\(Self.dummyOldOid) \(Self.dummyNewOid)\n".utf8)
            })
        #expect(!decision.isOwnInvocation, "the whole point of this test is a foreign decision")

        let attached = try JournalCheckpoint.attachRewrite(decision, entryID: nil, in: context)
        #expect(attached == nil, "a foreign decision must attach nothing, however live the file is")

        #expect(FileManager.default.fileExists(atPath: pendingPath),
                "a foreign decision must never even reach, let alone remove, the in-flight file")

        let after = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: liveEntry.id, in: context))
        #expect(after.rewrite == nil, "the live entry the file named must stay untouched")
    }

    /// **2 of 3.** Inverting `entryID ?? inFlightEntryID(...)` so the file
    /// beats the environment left the suite green (#0255's Finding 2). Both
    /// an environment id and a file are present here, and -- the part that
    /// makes this observable at all -- they name **two different live
    /// entries**: `environmentEntry` (passed as `entryID:`, as the
    /// checkpoint-scoped `GitProcess` would export it) and `fileEntry`
    /// (written to the in-flight file, as `around` would leave it behind).
    /// If both named the same entry, the mapping would land in the right
    /// place under either precedence and this would pin nothing -- the exact
    /// vacuity #0255 exists to remove.
    ///
    /// The file sits behind a genuinely live rebase for the same #0253
    /// reason as the test above: under the *correct* precedence the
    /// environment id is read eagerly and the file is never even opened
    /// (`??`'s right side is an autoclosure), so this fixture's liveness
    /// only matters for the mutant, which does open it -- and must find a
    /// real, resolvable entry there both today and after #0253 lands, or
    /// the mutant would wrongly fall through to the environment id anyway
    /// and this test would stop catching the swap.
    @Test func precedenceLandsOnTheEnvironmentEntryNotTheFileEntryWhenBothNameLiveEntries() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let environmentEntry = try JournalCheckpoint.checkpoint(
            operation: "environment-entry", in: context)
        let fileEntry = try JournalCheckpoint.checkpoint(operation: "file-entry", in: context)
        #expect(environmentEntry.id != fileEntry.id, "the two entries must be genuinely different")

        let pendingPath = try context.path(for: RepositoryLayout.inFlightEntryIDRelativePath)
        try fileEntry.id.string.write(toFile: pendingPath, atomically: true, encoding: .utf8)

        let rebaseMergePath = try context.path(for: "rebase-merge")
        try FileManager.default.createDirectory(
            atPath: rebaseMergePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: rebaseMergePath) }

        let decision = PostRewrite.decide(
            sourceArgument: "rebase",
            environment: [GitProcess.markerVariable: "1"],
            readStandardInput: {
                Data("\(Self.dummyOldOid) \(Self.dummyNewOid)\n".utf8)
            })
        #expect(decision.isOwnInvocation)

        let attached = try #require(
            try JournalCheckpoint.attachRewrite(decision, entryID: environmentEntry.id, in: context))
        #expect(attached.id == environmentEntry.id,
                "the environment id must win over the file when both name live entries")

        let environmentAfter = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: environmentEntry.id, in: context))
        #expect(environmentAfter.rewrite != nil, "the environment's entry must carry the mapping")

        let fileAfter = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: fileEntry.id, in: context))
        #expect(fileAfter.rewrite == nil, "the file's entry must stay untouched")
    }

    /// **3 of 3.** Deleting `try? fileManager.removeItem(atPath:
    /// pendingPath)` from the end of `attachRewrite` left the suite green
    /// (#0255's Finding 3). After a successful attach resolved through the
    /// file (not the environment -- `entryID: nil`), the file must be gone,
    /// or a slot outlives its own successful attach, exactly the
    /// stale-file hazard #0253 and #0254 are about.
    ///
    /// As in the two tests above, the file sits behind a genuinely live
    /// `rebase-merge` directory so this attach still resolves through the
    /// file once #0253 tightens `inFlightEntryID` to require a live
    /// resumable operation -- without it, this test would stop exercising
    /// the removal at all and would pass for the wrong reason.
    @Test func aSuccessfulAttachThroughTheFileRemovesIt() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let liveEntry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: context)
        let pendingPath = try context.path(for: RepositoryLayout.inFlightEntryIDRelativePath)
        try liveEntry.id.string.write(toFile: pendingPath, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: pendingPath))

        let rebaseMergePath = try context.path(for: "rebase-merge")
        try FileManager.default.createDirectory(
            atPath: rebaseMergePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: rebaseMergePath) }

        let decision = PostRewrite.decide(
            sourceArgument: "rebase",
            environment: [GitProcess.markerVariable: "1"],
            readStandardInput: {
                Data("\(Self.dummyOldOid) \(Self.dummyNewOid)\n".utf8)
            })
        #expect(decision.isOwnInvocation)

        let attached = try #require(
            try JournalCheckpoint.attachRewrite(decision, entryID: nil, in: context))
        #expect(attached.id == liveEntry.id, "the file must have resolved to the live entry")

        #expect(!FileManager.default.fileExists(atPath: pendingPath),
                "the in-flight file must be removed once its attach succeeds")
    }
}
