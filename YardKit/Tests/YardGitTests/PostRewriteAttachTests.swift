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

/// A distinct, otherwise-uninteresting error an `around` body can throw to
/// simulate an unrelated switchyard operation failing for reasons that have
/// nothing to do with any sequencer -- used by the foreign-rebase probes
/// below.
private struct ProbeFailure: Error {}

/// Resolves the entry-id file inside whichever sequencer directory is live
/// right now (guide §11 decision 24, #0273) -- `RepositoryLayout
/// .sequencerEntryIDFileName` joined onto `SequencerSnapshot.capture`'s own
/// layout, resolved through `WorktreeContext.path(for:)`, never by
/// concatenating onto `.git/`. `nil` when no sequencer is live.
private func liveEntryIDPath(in context: WorktreeContext) throws -> String? {
    guard let sequencer = try SequencerSnapshot.capture(in: context, git: git) else { return nil }
    return try context.path(
        for: sequencer.layout.rawValue + "/" + RepositoryLayout.sequencerEntryIDFileName, git: git)
}

/// Reads the entry id `around`'s catch wrote inside the currently live
/// sequencer directory, trimmed -- `nil` when no sequencer is live or no
/// file exists there yet.
///
/// The content never changes for as long as the operation stays open (only
/// `around`'s catch ever writes it, once, and only git's own `--continue`
/// or `--abort` ever removes it), so a fixture may read it at any point
/// during that window and carry the value forward. This stands in for what
/// a real, synchronous `post-rewrite` hook (#0217) would read before git
/// tears the directory down once the operation concludes -- the same
/// synchronous-capture requirement `LoggedInvocation.resumable` exists for,
/// captured by the hook script itself rather than recomputed later.
private func currentInFlightEntryID(in context: WorktreeContext) throws -> String? {
    guard let path = try liveEntryIDPath(in: context),
          let contents = try? String(contentsOfFile: path, encoding: .utf8)
    else { return nil }
    return contents.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Runs `git` through a raw `Foundation.Process`, with every `SWITCHYARD_*`
/// marker variable stripped from its environment -- genuinely foreign, the
/// way a human or an agent running `git rebase` directly in a terminal is
/// foreign to switchyard. `GitProcess` exports `GitProcess.markerVariable`
/// on every invocation it makes (own-marked) and cannot reproduce this; see
/// #0264's own text. Returns the child's exit code; stdout/stderr are
/// drained to EOF, which is safe for a *subprocess's* pipe (the child exits
/// and closes the write end) -- the hazard AGENTS.md warns about is `dup2`
/// on the test runner's own `STDOUT_FILENO`, not this.
@discardableResult
private func runForeignGit(_ arguments: [String], at path: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: git.executablePath)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: GitProcess.markerVariable)
    environment.removeValue(forKey: GitProcess.entryVariable)
    for (key, value) in hermetic { environment[key] = value }
    environment["GIT_EDITOR"] = "true"
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    _ = pipe.fileHandleForReading.readDataToEndOfFile()
    return process.terminationStatus
}

/// Creates a live, empty `rebase-merge` directory, so a fixture can plant a
/// `RepositoryLayout.sequencerEntryIDFileName` file inside it without
/// driving a real rebase to a stop. Returns the directory's path so the
/// caller can `defer` its removal.
@discardableResult
private func makeLiveRebaseMerge(in context: WorktreeContext) throws -> String {
    let rebaseMergePath = try context.path(for: "rebase-merge")
    try FileManager.default.createDirectory(
        atPath: rebaseMergePath, withIntermediateDirectories: true)
    return rebaseMergePath
}

/// Installs a `post-rewrite` hook that logs, for one invocation: the hook's
/// argument, `GitProcess.entryVariable`'s value (empty line when unset),
/// `GitProcess.markerVariable`'s value (empty line when unset), whether a
/// resumable rebase is present *at the instant the hook fires* (#0253; see
/// `LoggedInvocation.resumable`), then stdin verbatim. The hooks directory is
/// resolved through `WorktreeContext.path(for:)` — `git rev-parse
/// --git-path hooks` — never by string concatenation onto `.git/`.
private func installLoggingPostRewriteHook(in repo: FixtureRepository, loggingTo log: URL) throws {
    let context = try WorktreeContext.resolve(path: repo.url.path)
    let hooksDir = try context.path(for: "hooks")
    try FileManager.default.createDirectory(
        atPath: hooksDir, withIntermediateDirectories: true)
    let hookPath = hooksDir + "/post-rewrite"
    // The sequencer check mirrors `SequencerSnapshot.capture`'s own two
    // layouts (rebase-merge, rebase-apply), resolved through `git rev-parse
    // --git-path` exactly as the Swift side resolves it -- never string
    // concatenation onto `.git/`. This runs *inside* the hook's own
    // subprocess, which git spawns and waits on before it tears down the
    // sequencer directory (measured, git 2.50.1: `rebase-merge` is still
    // present when the hook fires, for both the mid-rebase `amend` and the
    // final `rebase` invocation; it is gone only after the hook returns and
    // the owning `git rebase --continue` process exits). A check made later,
    // from Swift code running after that process has already exited, can
    // never observe this -- the directory is provably gone by then, no
    // matter how quickly Swift asks (measured with a direct `FileManager`
    // probe on this exact fixture). `=S=` exists so a test can assert the
    // hook really did fire while the sequencer was still open, the
    // precondition that makes `JournalCheckpoint.attachRewrite`'s own
    // synchronous read (guide §11 decision 24, #0273) legitimate.
    let script = """
    #!/bin/sh
    printf '=I= %s\\n' "$1" >> "\(log.path)"
    printf '=E= %s\\n' "${\(GitProcess.entryVariable):-}" >> "\(log.path)"
    printf '=M= %s\\n' "${\(GitProcess.markerVariable):-}" >> "\(log.path)"
    rm=$(git rev-parse --path-format=absolute --git-path rebase-merge 2>/dev/null)
    ra=$(git rev-parse --path-format=absolute --git-path rebase-apply 2>/dev/null)
    if { [ -n "$rm" ] && [ -d "$rm" ]; } || { [ -n "$ra" ] && [ -d "$ra" ]; }; then
        printf '=S= 1\\n' >> "\(log.path)"
    else
        printf '=S= 0\\n' >> "\(log.path)"
    fi
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
    /// Whether `rebase-merge` or `rebase-apply` was present *at the instant
    /// this invocation's hook fired* — captured by the hook script itself,
    /// synchronously, inside the git process that owns the sequencer
    /// directory. Replaying this later (as every test in this file does)
    /// cannot recompute it: by replay time the owning git process has
    /// already exited and, for a rebase that finished or was aborted, the
    /// directory is already gone. This is the precondition that makes a
    /// real `post-rewrite` hook's own synchronous read of
    /// `JournalCheckpoint.attachRewrite` legitimate (guide §11 decision 24,
    /// #0273) -- asserted here as documentation of that precondition, not
    /// threaded into `attachRewrite` itself, which re-derives it fresh.
    let resumable: Bool
    let stdin: Data
}

/// Parses every invocation the log holds, in order. Measured: an autosquash
/// rebase fires `post-rewrite` **twice** — a mid-rebase `amend` for the
/// internal fixup application (old oid an intermediate commit that never
/// existed pre-rewrite) and a final `rebase` invocation whose mapping
/// repeats that pair alongside the rest — the same shape
/// `JournalObserved.swift`'s own doc comment describes for the foreign path.
/// `=I=` starts a new block; `=E=`/`=M=`/`=S=` are that block's next three
/// lines; everything after is that block's stdin, up to the next `=I=` or
/// EOF.
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
        let resumable = String(lines[index + 3].dropFirst(4))
        index += 4
        var stdinLines: [String] = []
        while index < lines.count, !lines[index].hasPrefix("=I= ") {
            stdinLines.append(lines[index])
            index += 1
        }
        result.append(LoggedInvocation(
            source: source,
            entryID: entryID.isEmpty ? nil : entryID,
            marker: marker.isEmpty ? nil : marker,
            resumable: resumable == "1",
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

        // A non-nil `command`/`agent` on the checkpoint entry, so there is
        // something for the attach below to carry through or lose (#0303).
        // No in-tree caller passes either to `around` today -- that is
        // M3's CLI's job -- so `Fixup.run` (which has no parameter for
        // either) is bypassed here in favor of calling `around` directly
        // with the same two git invocations `Fixup.run` makes internally:
        // `commit --fixup=`, then the non-interactive autosquash rebase
        // (Fixup.swift's `performFixup`/`autosquashRebase`, no `-i`, no
        // sequence editor needed on git 2.50.1).
        let agent = JournalEntryMetadata.Agent(name: "claude-code", session: "session-0303")
        _ = try JournalCheckpoint.around(
            operation: "fixup", at: repo.url.path,
            command: "switchyard fixup \(target)", agent: agent
        ) { scoped in
            try scoped.run(
                ["commit", "--fixup=\(target)"], workingDirectory: repo.url.path,
                extraEnvironment: hermetic)
            try scoped.run(
                ["rebase", "--autosquash", "\(target)^"], workingDirectory: repo.url.path,
                extraEnvironment: hermetic)
        }

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

        // Every other field comes back unchanged -- pinned against
        // `beforeAttach`'s own stored values field by field, never by
        // calling `attachingRewrite` on `beforeAttach` a second time: that
        // runs the exact function under test on both sides of `==`, so a
        // field dropped *inside* `attachingRewrite` would be dropped
        // identically on both sides and the comparison could never notice
        // (#0303). `command` and `agent` are non-nil above (asserted again
        // just below) so there is something here to lose; a mutation that
        // blanks either now reddens on the matching line.
        //
        // `guardRefs` and `traversal` are pinned too, but honestly: no
        // in-tree writer ever populates `guardRefs` (it stays `[:]` on
        // every real entry today), and `traversal` is set only on
        // undo/redo entries, which never rewrite a commit and so never
        // reach `attachRewrite`. No fixture in this file can put a
        // non-default value in either field ahead of a real attach, so
        // these two assertions pin "stays at its received value" rather
        // than "survives being non-default" -- the mutation that blanks
        // all five fields at once still reddens, but through `command`/
        // `agent`, not through these two.
        #expect(beforeAttach.command != nil, "must be non-nil or the pin below proves nothing")
        #expect(beforeAttach.agent != nil, "must be non-nil or the pin below proves nothing")
        #expect(after.schemaVersion == beforeAttach.schemaVersion)
        #expect(after.id == beforeAttach.id)
        #expect(after.operation == beforeAttach.operation)
        #expect(after.command == beforeAttach.command)
        #expect(after.label == beforeAttach.label)
        #expect(after.timestamp == beforeAttach.timestamp)
        #expect(after.worktree == beforeAttach.worktree)
        #expect(after.captured == beforeAttach.captured)
        #expect(after.guardRefs == beforeAttach.guardRefs)
        #expect(after.agent == beforeAttach.agent)
        #expect(after.traversal == beforeAttach.traversal)

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

    // MARK: - Guide §11 decision 24 (#0273): the file's own lifetime is the
    // staleness check

    /// Decision 24's own claim, pinned directly rather than inferred through
    /// `currentInFlightEntryID`'s indirection the way every other test in
    /// this file exercises it: `around`'s catch writes the entry id
    /// **inside** the live sequencer directory, at
    /// `<layout>/RepositoryLayout.sequencerEntryIDFileName`, resolved
    /// through `WorktreeContext.path(for:)` -- never beside it, at the old,
    /// pre-decision-24 `RepositoryLayout.stateDirectoryName` location.
    @Test func theInFlightEntryIDFileLivesInsideTheSequencerDirectoryNotBesideIt() throws {
        var repo = try FixtureRepository()
        try repo.build([
            .init("c1", files: ["f.txt": "a\n"]),
            .init("c2", files: ["f.txt": "b\n"]),
            .init("c3", files: ["f.txt": "c\n"]),
        ])
        defer { repo.destroy() }
        let target = try #require(repo.oids["c2"])
        let context = try WorktreeContext.resolve(path: repo.url.path)

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

        let entry = try #require(try JournalAnchor.list(in: context).first)

        // The exact resolved path decision 24 specifies: the live layout's
        // own directory, joined with the filename, through
        // `WorktreeContext.path(for:)`.
        let sequencer = try #require(try SequencerSnapshot.capture(in: context, git: git))
        let insidePath = try context.path(
            for: sequencer.layout.rawValue + "/" + RepositoryLayout.sequencerEntryIDFileName,
            git: git)
        let insideContents = try #require(try? String(contentsOfFile: insidePath, encoding: .utf8))
        #expect(insideContents.trimmingCharacters(in: .whitespacesAndNewlines) == entry.id.string,
                "the file must land inside the live sequencer directory, at the decision-24 path")

        // The mutation this test exists to catch: writing beside the
        // sequencer -- the file's location before decision 24 -- instead of
        // inside it.
        let besidePath = try context.path(
            for: RepositoryLayout.stateDirectoryName + "/" + RepositoryLayout.sequencerEntryIDFileName,
            git: git)
        #expect(!FileManager.default.fileExists(atPath: besidePath),
                "the file must never be written beside the sequencer directory")
    }

    /// #0263's own gap, reopened by this issue and closed here: every other
    /// test in this file drives the `-i`/`--merge` backend through `Fixup`,
    /// which never touches `rebase-apply/` at all. `around`'s catch and
    /// `attachRewrite`'s read both resolve the entry-id file from
    /// *whatever layout `SequencerSnapshot.capture` reports live*, joined
    /// through `WorktreeContext.path(for:)` -- never a hardcoded
    /// `"rebase-merge/"`. Nothing in this file pinned that claim for the
    /// `--apply` backend, so a mutant that hardcodes `"rebase-merge/"` on
    /// the read side passed the full suite silently -- the exact shape
    /// #0263 already named once, for `WorktreeDisturbance`.
    ///
    /// `git rebase --apply main` (the `git am`-backed engine) only ever
    /// stops mid-sequence on a genuinely conflicting patch (measured, same
    /// as `WorktreeDisturbanceTests.aMidRebaseApplySiblingIsNamedAsADisturbance`,
    /// whose fixture this mirrors), so `around`'s body must hit a real
    /// conflict, not a clean stop, to leave `rebase-apply/` live.
    @Test func aConflictingApplyBackendRebaseWritesAndReadsTheEntryIDFromRebaseApply() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }

        // c1, on main: f = "a"
        try "a\n".write(to: repo.url.appendingPathComponent("f"),
                        atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "c1"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        // A side branch off c1.
        try git.run(["checkout", "-qb", "side"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        // c2, back on main: f = "b" -- main moves past c1 on the same line.
        try git.run(["checkout", "-q", "main"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)
        try "b\n".write(to: repo.url.appendingPathComponent("f"),
                        atomically: true, encoding: .utf8)
        try git.run(["commit", "-qam", "c2"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        // c3, on side: f = "c" -- a conflicting edit to the same line.
        try git.run(["checkout", "-q", "side"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)
        try "c\n".write(to: repo.url.appendingPathComponent("f"),
                        atomically: true, encoding: .utf8)
        try git.run(["commit", "-qam", "c3"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        let context = try WorktreeContext.resolve(path: repo.url.path)

        // `--apply` replays c3 onto main's c2, conflicts on f, and stops --
        // `around`'s body throws a real `GitProcess.Failure`, exactly as an
        // unresolved `-i` conflict does for `Fixup`.
        #expect(throws: GitProcess.Failure.self) {
            _ = try JournalCheckpoint.around(operation: "apply-backend", at: repo.url.path) { scoped in
                try scoped.run(["rebase", "--apply", "main"], workingDirectory: repo.url.path,
                               extraEnvironment: hermetic)
            }
        }

        // Confirm the fixture actually reached the `--apply` backend and
        // not `-i`'s `rebase-merge` -- through `WorktreeContext.path(for:)`,
        // never by concatenating onto `.git/`, the same check #0263's own
        // test makes before trusting anything else.
        let applyHeadName = try context.path(for: "rebase-apply/head-name")
        #expect(FileManager.default.fileExists(atPath: applyHeadName))
        let mergeHeadName = try context.path(for: "rebase-merge/head-name")
        #expect(!FileManager.default.fileExists(atPath: mergeHeadName))

        let entry = try #require(try JournalAnchor.list(in: context).first)

        // Write side: `around`'s catch must have resolved the LIVE layout
        // (`rebase-apply`), not assumed `rebase-merge`.
        let applyEntryIDPath = try context.path(
            for: "rebase-apply/" + RepositoryLayout.sequencerEntryIDFileName)
        let writtenContents = try #require(
            try? String(contentsOfFile: applyEntryIDPath, encoding: .utf8))
        #expect(writtenContents.trimmingCharacters(in: .whitespacesAndNewlines) == entry.id.string,
                "the entry id must be written to rebase-apply/, not rebase-merge/")

        // Read side: `attachRewrite`, with no environment id, must resolve
        // the same file back through the live layout too.
        let decision = PostRewrite.decide(
            sourceArgument: "rebase",
            environment: [GitProcess.markerVariable: "1"],
            readStandardInput: {
                Data("\(String(repeating: "a", count: 40)) \(String(repeating: "b", count: 40))\n".utf8)
            })
        #expect(decision.isOwnInvocation)
        let attached = try #require(
            try JournalCheckpoint.attachRewrite(decision, entryID: nil, in: context))
        #expect(attached.id == entry.id,
                "attachRewrite must read the id back from rebase-apply/, not rebase-merge/")
    }

    /// The honest options for an own invocation with no entry id anywhere
    /// are "record nothing" and "fall back to an observed entry" (#0221's
    /// Expected behavior). This picks "record nothing": with no
    /// `entryVariable` in the environment and no sequencer live at all (so
    /// no `RepositoryLayout.sequencerEntryIDFileName` file can exist
    /// anywhere -- guide §11 decision 24, #0273), there is no in-flight
    /// entry to attach to, and routing it to an observed entry would
    /// misrepresent it as foreign-sourced -- exactly the distinction
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
    /// wrong" per #0237's own issue text.
    ///
    /// Under guide §11 decision 24 (#0273) the file only exists inside a
    /// live sequencer directory, so the fixture must make one live
    /// (`makeLiveRebaseMerge`, without driving a real rebase to a stop) and
    /// write the fabricated id at
    /// `<rebase-merge>/RepositoryLayout.sequencerEntryIDFileName` -- the
    /// same path `JournalCheckpoint.around`'s catch resolves, by hand rather
    /// than through `around` itself, so the fixture can plant an id that is
    /// guaranteed never to have existed.
    @Test func aStaleFileAttachesNothingAndIsRemoved() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let fabricated = try #require(JournalEntryID(String(repeating: "0", count: JournalEntryID.length)))
        let rebaseMergePath = try makeLiveRebaseMerge(in: context)
        defer { try? FileManager.default.removeItem(atPath: rebaseMergePath) }
        let pendingPath = rebaseMergePath + "/" + RepositoryLayout.sequencerEntryIDFileName
        try fabricated.string.write(toFile: pendingPath, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: pendingPath))
        #expect(try JournalAnchor.list(in: context).isEmpty, "the fabricated id must name nothing real")

        // `sourceArgument: "rebase"`, not `"amend"` -- an `amend` decision
        // with a live `rebase-merge` present is `isMidRebaseAmend` (#0233)
        // and returns early, before ever reaching the file this test means
        // to exercise. `"rebase"` reaches the file-read path the same way
        // the other live-sequencer fixtures below do.
        let decision = PostRewrite.decide(
            sourceArgument: "rebase",
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
    /// the rebase started, found through the file inside the live sequencer
    /// directory rather than the environment (guide §11 decision 24,
    /// #0273).
    ///
    /// **Why this test reads the file itself instead of letting
    /// `attachRewrite` do it.** Under decision 24 the file lives *inside*
    /// `rebase-merge`, and git removes that whole directory the moment the
    /// continue loop below finishes the rebase -- so by the time this test
    /// resumes control, the file is provably gone (the same reason
    /// `invocation.resumable` above can only be captured by the hook script
    /// itself, synchronously, never recomputed after the fact). A real
    /// `post-rewrite` hook (#0217) reads the file from *inside* the still-
    /// live process, then hands the resolved id to `attachRewrite` exactly
    /// as the environment-carried case already does; this test plays that
    /// role by reading the file right after the conflict, while
    /// `repo.isMidRebase` is still true, and carrying the value forward --
    /// legitimate because the file's content never changes for as long as
    /// the operation stays open (`currentInFlightEntryID`'s own doc
    /// comment).
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

        // Captured now, while the sequencer is still genuinely live -- see
        // this test's own doc comment for why it cannot be read after the
        // continue loop below finishes the rebase.
        let inFlightID = try #require(
            try currentInFlightEntryID(in: context),
            "the conflict must leave the in-flight file naming its own entry")
        #expect(inFlightID == checkpointEntry.id.string)

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
        // The fact that makes attaching through the file legitimate at all
        // -- the hook script captured it synchronously, inside the same
        // `git rebase --continue` process that still held `rebase-merge`
        // open at that instant. Swift-level code asking the same question
        // now, after that process has already exited and
        // `!repo.isMidRebase` above confirmed the directory gone, cannot
        // recover this answer -- it can only be carried forward from the
        // moment it was true, exactly as `inFlightID` was above.
        #expect(invocation.resumable,
                "the hook fired while the rebase it was concluding was still live")
        let decision = PostRewrite.decide(
            sourceArgument: invocation.source,
            environment: [GitProcess.markerVariable: invocation.marker ?? ""],
            readStandardInput: { invocation.stdin })
        #expect(decision.isOwnInvocation, "the marker must still be set on our own continue")
        // `entryID:` carries the id read from the file while it was still
        // live, exactly as a real #0217 hook glue would supply it --
        // `attachRewrite`'s own internal file read (guide §11 decision 24)
        // has nothing left to find once the rebase has fully concluded.
        _ = try #require(try JournalCheckpoint.attachRewrite(
            decision, entryID: try #require(JournalEntryID(inFlightID)), in: context))

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

    // MARK: - #0253: the read side must require the operation still be in progress

    /// #0253's own probe, made a test — Finding 1 of #0160's fourth umbrella
    /// review, then updated for guide §11 decision 24 (#0273). A conflicting
    /// `Fixup.run(target:)` leaves the in-flight file naming its own
    /// pre-operation entry, exactly as
    /// `aConflictingFixupResolvedAndContinuedAttachesToItsPreOperationEntry`
    /// above sets up. But here the caller does not resolve and continue --
    /// it runs `git rebase --abort` directly, **out of band**, the
    /// documented alternative `FixupError.blockedOnConflicts`'s doc comment
    /// names.
    ///
    /// **Before decision 24, the file lived beside the sequencer and
    /// survived this abort**, naming an entry whose operation had already
    /// ended; a later, wholly unrelated own rewrite would read that stale
    /// file back and wrongly attach to the abandoned entry. **Decision 24
    /// removes the failure mode at its root**: the file now lives *inside*
    /// the sequencer directory, and `git rebase --abort` deletes that whole
    /// directory, our file included -- so there is no stale file left for a
    /// later rewrite to consume in the first place. This test now pins that
    /// removal directly, then confirms the unrelated rewrite attaches
    /// nothing, which follows trivially once nothing is left to misread.
    @Test func anOutOfBandAbortLeavesAStaleFileThatALaterUnrelatedRewriteMustNotConsume() throws {
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
        #expect(entries.count == 1, "just the pre-operation checkpoint for the fixup")
        let abandoned = try #require(entries.first)

        let beforeContents = try #require(
            try currentInFlightEntryID(in: context),
            "the conflict must leave the in-flight file naming the fixup's own entry")
        #expect(beforeContents == abandoned.id.string)
        let pendingPath = try #require(try liveEntryIDPath(in: context))

        // Out of band: the caller aborts directly, not through `Fixup`.
        // Under decision 24 the whole `rebase-merge` directory -- our file
        // included -- is removed by git itself, not left behind for
        // switchyard-side code to clear.
        _ = try git.run(["rebase", "--abort"], workingDirectory: repo.url.path)
        #expect(!repo.isMidRebase, "the abort must have ended the rebase")
        #expect(!FileManager.default.fileExists(atPath: pendingPath),
                "decision 24: the abort removes the whole sequencer directory, our file included")
        #expect(try SequencerSnapshot.capture(in: context, git: git) == nil,
                "nothing is live once the abort has run")

        // A later, wholly unrelated own rewrite -- touches nothing the
        // fixup touched.
        try git.run(
            ["commit", "--amend", "--no-edit"], workingDirectory: repo.url.path,
            extraEnvironment: hermetic.merging(["GIT_EDITOR": "true"]) { _, new in new })

        let invocation = try finalInvocation(in: log)
        #expect(invocation.source == "amend")
        #expect(invocation.entryID == nil, "the amend ran through an unscoped GitProcess")
        #expect(!invocation.resumable,
                "the abort tore down the sequencer before this hook ever fired")
        let markerValue = try #require(invocation.marker)
        let decision = PostRewrite.decide(
            sourceArgument: invocation.source,
            environment: [GitProcess.markerVariable: markerValue],
            readStandardInput: { invocation.stdin })
        #expect(decision.isOwnInvocation)

        let attached = try JournalCheckpoint.attachRewrite(
            decision, entryID: nil, in: context)
        #expect(attached == nil,
                "with no sequencer live and no file to find, the unrelated rewrite must attach nothing")

        let after = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: abandoned.id, in: context))
        #expect(after.rewrite == nil, "the abandoned fixup's own entry must stay untouched")
        #expect(try JournalObserved.list(in: context).isEmpty)
    }

    /// #0234's own test: `Fixup.run(source:target:)` (#0214's existing-commit
    /// mode) fires **three** `post-rewrite` invocations for one operation — a
    /// standalone `amend` (`headBefore → mid`), a mid-rebase `amend` that
    /// #0233 already filters, and the final `rebase` (`mid → head`, plus
    /// `target`'s own rewrite). Attaching each invocation as it arrives must
    /// leave the entry's pre-checkpoint `HEAD` reachable through the stored
    /// mapping — the assertion this issue exists for, not merely that the
    /// mapping is non-empty.
    ///
    /// **#0317: this loop replays all three invocations, unfiltered** —
    /// unlike a live `JournalCheckpoint.attachRewrite`, which asks
    /// `isMidRebaseAmend` a question only answerable *while the rebase's own
    /// sequencer directory is still open*, and so filters the mid-rebase
    /// `amend` out in production. By the time this loop runs the whole
    /// operation has already finished and that directory is gone, so the
    /// live check no longer sees what it would have seen synchronously —
    /// measured: `attachRewrite` composes all three here, and one harmless
    /// artifact of that is `target`'s pair getting recorded twice, once
    /// repeated verbatim by the final `rebase` invocation and once left
    /// over from the mid-rebase `amend` this loop never actually filtered.
    /// The invariant below is stated as "no `oldOid` maps to two
    /// *different* `newOid`s" rather than flat uniqueness of `oldOid`,
    /// which that harmless, identical-valued duplicate would otherwise
    /// trip for no real reason.
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
        #expect(mapping.source == "rebase",
                "the final, authoritative invocation is the rebase; its source must survive composing")

        // #0317: pin `composing(with:)`'s `chainedFrom` invariant directly,
        // rather than trusting that a broken bookkeeping happens to surface
        // only as a missing `headBefore` pair below. Two properties, not one
        // literal pin — the fixture's oids are not stable across runs, and a
        // literal pin would need updating every time they change:
        //
        // 1. No `oldOid` resolves to two *different* `newOid`s. A regressed
        //    `chainedFrom` (this issue's own mutation:
        //    `chainedFrom.insert(index)` -> `insert(-1)`) stops marking a
        //    chained `self` pair as consumed, so it is re-emitted alongside
        //    the pair that correctly chained through it -- exactly the
        //    `headBefore -> mid` / `headBefore -> head` split the issue
        //    describes. (Grouped into a set per `oldOid`, rather than a flat
        //    uniqueness check on `oldOid` itself, because this loop's own
        //    replay of all three invocations, unfiltered, already and
        //    harmlessly repeats `target`'s pair with an *identical* `newOid`
        //    both times -- see the doc comment above.)
        // 2. Every stored `newOid` is reachable from the post-rewrite
        //    `HEAD` -- the property that actually matters to a reader of
        //    the mapping: a pair pointing at a commit no ref reaches is
        //    exactly the wrongness #0233 and #0234 exist to eliminate.
        var newOidsByOldOid: [String: Set<String>] = [:]
        for rewrite in mapping.rewrites {
            newOidsByOldOid[rewrite.oldOid, default: []].insert(rewrite.newOid)
        }
        for (oldOid, newOids) in newOidsByOldOid {
            #expect(newOids.count == 1,
                    "\(oldOid) must resolve to exactly one newOid, not \(newOids)")
        }
        for rewrite in mapping.rewrites {
            let ancestor = try git.capture(
                ["merge-base", "--is-ancestor", rewrite.newOid, "HEAD"],
                workingDirectory: repo.url.path)
            #expect(ancestor.exitCode == 0,
                    "\(rewrite.oldOid) -> \(rewrite.newOid): newOid must be reachable in the post-rewrite history")
        }

        // The assertion the doc comment above already promised: the entry's
        // pre-checkpoint HEAD must be reachable through the stored mapping,
        // chained to the operation's actual result -- not merely present
        // somewhere, and not lost behind the intermediate commit the
        // mid-rebase amend named.
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

        // `Fixup`'s own abort ran before `around`'s catch ever saw a live
        // sequencer to write a file into (guide §11 decision 24, #0273) --
        // there is no worktree-wide slot left to check, only "is anything
        // live at all".
        #expect(try SequencerSnapshot.capture(in: context, git: git) == nil,
                "an operation that aborted before throwing must leave no live sequencer, and so no file")

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

        let beforeContents = try #require(
            try currentInFlightEntryID(in: context),
            "the conflict must leave the in-flight file naming the fixup's own entry")
        #expect(beforeContents == fixupEntry.id.string)

        // A wholly unrelated, fully successful `around` in the same
        // worktree -- must not touch the fixup's slot at all.
        _ = try JournalCheckpoint.around(operation: "unrelated", at: repo.url.path, git: git) { _ in 0 }

        let afterUnrelated = try currentInFlightEntryID(in: context)
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
        // Captured by the hook script itself, synchronously, while the
        // concluding `git rebase --continue` process still held
        // `rebase-merge` open -- see the sibling assertion's comment in
        // `aConflictingFixupResolvedAndContinuedAttachesToItsPreOperationEntry`
        // for why this cannot be recomputed after the fact.
        #expect(invocation.resumable,
                "the hook fired while the rebase it was concluding was still live")
        let decision = PostRewrite.decide(
            sourceArgument: invocation.source,
            environment: [GitProcess.markerVariable: invocation.marker ?? ""],
            readStandardInput: { invocation.stdin })
        #expect(decision.isOwnInvocation)

        // `entryID:` carries the id captured above, from `beforeContents`,
        // while the sequencer was still genuinely live -- the file itself
        // is gone by now, exactly as
        // `aConflictingFixupResolvedAndContinuedAttachesToItsPreOperationEntry`'s
        // own doc comment explains.
        let attached = try #require(try JournalCheckpoint.attachRewrite(
            decision, entryID: try #require(JournalEntryID(beforeContents)), in: context))
        #expect(attached.id == fixupEntry.id,
                "the mapping must land on the fixup's own entry, not the unrelated one")

        let unrelatedID = try #require(
            entriesAfterUnrelated.first(where: { $0.id != fixupEntry.id })?.id)
        let unrelatedMetadata = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: unrelatedID, in: context))
        #expect(unrelatedMetadata.rewrite == nil, "the unrelated entry must stay untouched")
    }

    /// #0254's own probe, made a test — Finding 2 of #0160's fourth umbrella
    /// review, 2026-08-17. A conflicting `Fixup.run(target:)` leaves the
    /// in-flight file naming its own entry, exactly as
    /// `aConflictingFixupResolvedAndContinuedAttachesToItsPreOperationEntry`
    /// above sets up. Here the SECOND caller is not an unrelated successful
    /// operation (as
    /// `anUnrelatedSuccessfulOperationBetweenAConflictAndItsContinueDoesNotClobberTheSlot`
    /// covers) but a second `Fixup.run(target:)` against the same
    /// still-conflicted repository: measured, `git commit --fixup=` refuses
    /// with "Committing is not possible because you have unmerged files"
    /// (exit 128) before any rebase of its own ever starts, so its own
    /// `around` call throws while the FIRST call's rebase is what the
    /// sequencer check finds still live. Before this issue that read as
    /// "yes, write", and the second call's entry id clobbered the first's
    /// slot -- the uncovered quadrant the sibling test above cannot reach,
    /// since most operations that run mid-rebase fail rather than succeed.
    @Test func aSecondConflictingFixupCannotClobberTheFirstsInFlightSlot() throws {
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

        let firstThrown = #expect(throws: FixupError.self) {
            _ = try Fixup.run(target: target, at: repo.url.path, extraEnvironment: hermetic)
        }
        guard case .blockedOnConflicts = try #require(firstThrown) else {
            Issue.record("expected .blockedOnConflicts, got \(String(describing: firstThrown))")
            return
        }
        #expect(repo.isMidRebase, "the first rebase must be left resumable, not aborted")

        let entries = try JournalAnchor.list(in: context)
        #expect(entries.count == 1)
        let firstEntry = try #require(entries.first)

        let slotAfterFirst = try #require(
            try currentInFlightEntryID(in: context),
            "the first conflict must leave the in-flight file naming its own entry")
        #expect(slotAfterFirst == firstEntry.id.string)

        // A second `Fixup.run` against the SAME repository: `around` writes
        // its own checkpoint entry before `body` runs, then `body` throws --
        // `git commit --fixup=` refuses the still-unmerged index left by the
        // first conflict, so no second rebase ever starts. `around`'s catch
        // still finds a live sequencer (the FIRST rebase), and must not
        // claim the slot with this second entry's id.
        #expect(throws: GitProcess.Failure.self) {
            _ = try Fixup.run(target: target, at: repo.url.path, extraEnvironment: hermetic)
        }
        #expect(repo.isMidRebase, "still only the first rebase -- the second never started one")

        let entriesAfterSecond = try JournalAnchor.list(in: context)
        #expect(entriesAfterSecond.count == 2,
                "the second call's own pre-operation checkpoint is still written")
        let secondEntry = try #require(entriesAfterSecond.first { $0.id != firstEntry.id })

        let slotAfterSecond = try #require(try currentInFlightEntryID(in: context))
        #expect(slotAfterSecond == firstEntry.id.string,
                "first-writer-wins: the second call's throw must not clobber the first entry's slot")
        #expect(slotAfterSecond != secondEntry.id.string)

        // Resolve and continue the one rebase that is actually in progress
        // -- the first's. Autosquash reorders the fixup right after its
        // target, so this fixture's conflicting content conflicts twice on
        // replay, exactly as
        // `aConflictingFixupResolvedAndContinuedAttachesToItsPreOperationEntry`
        // above loops for.
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
        #expect(invocation.resumable,
                "the hook fired while the rebase it was concluding was still live")
        let decision = PostRewrite.decide(
            sourceArgument: invocation.source,
            environment: [GitProcess.markerVariable: invocation.marker ?? ""],
            readStandardInput: { invocation.stdin })
        #expect(decision.isOwnInvocation, "the marker must still be set on our own continue")

        // `entryID:` carries `slotAfterSecond`, captured while the sequencer
        // was still live -- see
        // `aConflictingFixupResolvedAndContinuedAttachesToItsPreOperationEntry`'s
        // own doc comment for why the file cannot be re-read after the
        // continue loop above has finished the rebase.
        let attached = try #require(try JournalCheckpoint.attachRewrite(
            decision, entryID: try #require(JournalEntryID(slotAfterSecond)), in: context))
        #expect(attached.id == firstEntry.id,
                "the mapping must land on the FIRST entry, whose slot the second call could not steal")

        let afterFirst = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: firstEntry.id, in: context))
        let mapping = try #require(
            afterFirst.rewrite, "the mapping must be findable, attached to the first entry")
        let head = try #require(
            git.run(["rev-parse", "HEAD"], workingDirectory: repo.url.path).lines.first)
        let fromHeadBefore = try #require(
            mapping.rewrites.first(where: { $0.oldOid == headBefore }),
            "the first entry's pre-operation HEAD must be reachable through the stored mapping")
        #expect(fromHeadBefore.newOid == head)

        let afterSecond = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: secondEntry.id, in: context))
        #expect(afterSecond.rewrite == nil, "the second entry must stay untouched -- it never had a slot")

        #expect(try JournalObserved.list(in: context).isEmpty,
                "the mapping belongs on the journal entry that captured pre-operation state, not as an observed one")
    }

    // MARK: - #0261: a stale in-flight slot must not divert a later,
    // unrelated operation's rewrite

    /// #0261's original reproduction, kept and updated for guide §11
    /// decision 24 (#0273): a first `Fixup.run` conflicts and leaves its own
    /// entry's id in the in-flight slot; the caller aborts that rebase
    /// **directly** with `git rebase --abort`, not through `Fixup`. A
    /// second, wholly unrelated `Fixup.run` then conflicts on its own and
    /// leaves its own rebase live.
    ///
    /// **Before #0261's original fix, `around`'s first-writer-wins check
    /// (#0254) could not tell a stale reference from a genuinely live one**
    /// -- the file lived beside the sequencer, survived the abort, and
    /// `JournalAnchor.list` still contained entry A -- so the second call's
    /// catch refused to claim the slot, and the eventual `post-rewrite` hook
    /// attached the second operation's mapping to the FIRST, unrelated
    /// entry. #0261's fix was to clear a stale slot at the *start* of
    /// `around`, before the second checkpoint was even written.
    ///
    /// **Decision 24 removes the failure mode at its root, the same way it
    /// does for the sibling abort test above**: the file now lives *inside*
    /// the sequencer directory, so the out-of-band abort in step 2 deletes
    /// it along with the rest of `rebase-merge` -- there is no stale slot
    /// left for `around`'s start-of-call clear to find, because nothing
    /// survives the abort for it to clear. B's own conflict in step 4
    /// creates a brand-new sequencer directory with no file in it yet, so
    /// B's `around` catch writes into empty ground for the ordinary reason
    /// (`sequencerWasLiveBefore == false`), not because of any special
    /// clearing step. This test still pins the end-to-end outcome -- B's
    /// mapping lands on B, never on the long-gone A -- as a regression check
    /// that the new mechanism gets the historical #0261 scenario right too.
    @Test func anOutOfBandAbortsStaleSlotMustNotDivertALaterUnrelatedOperationsRewrite() throws {
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

        // 1. A first `Fixup.run` conflicts, leaving its own entry's id in
        //    the in-flight slot.
        try repo.writeUntracked(["f.txt": "z\n"])
        try git.run(["add", "-A"], workingDirectory: repo.url.path)

        let firstThrown = #expect(throws: FixupError.self) {
            _ = try Fixup.run(target: target, at: repo.url.path, extraEnvironment: hermetic)
        }
        guard case .blockedOnConflicts = try #require(firstThrown) else {
            Issue.record("expected .blockedOnConflicts, got \(String(describing: firstThrown))")
            return
        }
        #expect(repo.isMidRebase, "the first rebase must be left resumable, not aborted")

        let entries = try JournalAnchor.list(in: context)
        #expect(entries.count == 1)
        let entryA = try #require(entries.first)

        let slotAfterA = try #require(
            try currentInFlightEntryID(in: context),
            "the first conflict must leave the in-flight file naming its own entry")
        #expect(slotAfterA == entryA.id.string)
        let pendingPathForA = try #require(try liveEntryIDPath(in: context))

        // 2. Out of band: the caller aborts directly, not through `Fixup`.
        //    Decision 24: the whole `rebase-merge` directory -- our file
        //    included -- is removed by git itself, so there is no stale
        //    reference to entry A left behind for anything to clear.
        _ = try git.run(["rebase", "--abort"], workingDirectory: repo.url.path)
        #expect(!repo.isMidRebase, "the abort must have ended the first rebase")
        #expect(!FileManager.default.fileExists(atPath: pendingPathForA),
                "decision 24: the abort removes the whole sequencer directory, our file included")

        // 3. Before operation B starts, nothing is live -- the abort tore
        //    down the only sequencer this worktree had.
        #expect(try SequencerSnapshot.capture(in: context, git: git) == nil)

        // 4. A second, wholly unrelated `Fixup.run` -- its own staged
        //    change, same target, and it conflicts on its own (the abandoned
        //    fixup commit from step 1 is still sitting on `HEAD`, and
        //    replaying its diff onto `target` conflicts the same way it did
        //    the first time). This is a genuinely new operation, not a retry
        //    of the first: the abort left no unmerged index behind for `git
        //    commit --fixup=` to refuse.
        try repo.writeUntracked(["f.txt": "y\n"])
        try git.run(["add", "-A"], workingDirectory: repo.url.path)

        let secondThrown = #expect(throws: FixupError.self) {
            _ = try Fixup.run(target: target, at: repo.url.path, extraEnvironment: hermetic)
        }
        guard case .blockedOnConflicts = try #require(secondThrown) else {
            Issue.record("expected .blockedOnConflicts, got \(String(describing: secondThrown))")
            return
        }
        #expect(repo.isMidRebase, "the second operation must leave its own rebase live")

        let entriesAfterB = try JournalAnchor.list(in: context)
        #expect(entriesAfterB.count == 2, "B's own pre-operation checkpoint is written alongside A's")
        let entryB = try #require(entriesAfterB.first { $0.id != entryA.id })

        // B's own conflict created a brand-new sequencer directory (A's is
        // long gone), so B's `around` catch writes into it for the ordinary
        // reason -- nothing was live when B's own body started -- not
        // because of any special stale-slot clearing.
        let slotAfterB = try #require(try currentInFlightEntryID(in: context))
        #expect(slotAfterB == entryB.id.string,
                "B must claim its own, freshly created slot -- there is no stale reference to A left to steal")

        // 5. Resolve and continue -- the only rebase live is B's.
        let continueGit = GitProcess()
        let continueEnvironment = hermetic.merging(["GIT_EDITOR": "true"]) { _, new in new }
        for _ in 0..<10 where repo.isMidRebase {
            if repo.hasConflicts {
                try repo.writeUntracked(["f.txt": "resolved\n"])
                try git.run(["add", "-A"], workingDirectory: repo.url.path)
            }
            _ = try continueGit.capture(
                ["rebase", "--continue"], workingDirectory: repo.url.path,
                extraEnvironment: continueEnvironment)
        }
        #expect(!repo.isMidRebase, "the continue loop must have finished B's rebase")

        let invocation = try finalInvocation(in: log)
        #expect(invocation.source == "rebase")
        #expect(invocation.entryID == nil,
                "the continue ran through an unscoped GitProcess and must export no entry id")
        #expect(invocation.resumable,
                "the hook fired while the rebase it was concluding was still live")
        let decision = PostRewrite.decide(
            sourceArgument: invocation.source,
            environment: [GitProcess.markerVariable: invocation.marker ?? ""],
            readStandardInput: { invocation.stdin })
        #expect(decision.isOwnInvocation, "the marker must still be set on our own continue")

        // `entryID:` carries `slotAfterB`, captured while B's sequencer was
        // still live -- see
        // `aConflictingFixupResolvedAndContinuedAttachesToItsPreOperationEntry`'s
        // own doc comment for why the file cannot be re-read after the
        // continue loop above has finished B's rebase.
        let attached = try #require(try JournalCheckpoint.attachRewrite(
            decision, entryID: try #require(JournalEntryID(slotAfterB)), in: context))
        #expect(attached.id == entryB.id,
                "B's mapping must land on B's OWN entry, not the long-gone, unrelated A")

        let afterB = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: entryB.id, in: context))
        #expect(afterB.rewrite != nil, "B's own entry must carry B's own mapping")

        let afterA = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: entryA.id, in: context))
        #expect(afterA.rewrite == nil,
                "entry A must stay untouched -- it never ran the operation now being recorded")

        #expect(try JournalObserved.list(in: context).isEmpty)
    }

    // MARK: - #0264: the sequencer must belong to THIS call before its slot
    // can be claimed

    /// #0264's Route 1 probe, made permanent -- Finding of #0160's fifth
    /// umbrella review, 2026-08-18. A genuinely **foreign** rebase (raw
    /// `Process`, no `SWITCHYARD_*` marker -- the ordinary case this whole
    /// mechanism exists for: an agent or a human running `git rebase`
    /// directly in a terminal) stops on a conflict and stays live. Before
    /// this issue, an UNRELATED switchyard operation failing while that
    /// foreign rebase was live would read `SequencerSnapshot.capture(in:) !=
    /// nil`, find the slot empty, and claim it for its own entry -- even
    /// though nothing about that entry's operation ever touched the
    /// sequencer. A later own-invocation conclusion of the foreign rebase
    /// would then read the slot back and attach the foreign rewrite to the
    /// wrong, unrelated entry. The fix: `around`'s catch now also requires
    /// `!sequencerWasLiveBefore` -- a sequencer already live before this
    /// call's own body ran can never be this call's to claim.
    @Test func aForeignRebaseAndAnUnrelatedFailingOperationAttachNothing() throws {
        var repo = try FixtureRepository()
        try repo.build([
            .init("c1", files: ["f.txt": "a\n"]),
            .init("c2", files: ["f.txt": "b\n"]),
            .init("c3", files: ["f.txt": "c\n"]),
        ])
        defer { repo.destroy() }
        let c1 = try #require(repo.oids["c1"])
        let c2 = try #require(repo.oids["c2"])
        let context = try WorktreeContext.resolve(path: repo.url.path)

        // A genuinely foreign rebase -- dropping c2 and replaying c3 onto
        // c1 conflicts, since c3's diff expects c2's content as its base.
        let status = try runForeignGit(["rebase", "--onto", c1, c2], at: repo.url.path)
        #expect(status != 0, "the foreign rebase must stop on a conflict")
        #expect(repo.isMidRebase, "a live foreign rebase is the whole premise of this probe")
        #expect(try JournalAnchor.list(in: context).isEmpty, "no switchyard code has run yet")
        // The foreign rebase's own directory is live, but nothing switchyard
        // owns has written a `RepositoryLayout.sequencerEntryIDFileName`
        // file into it (guide §11 decision 24, #0273) -- resolved only now,
        // after the foreign rebase exists, since the path depends on which
        // sequencer layout is live.
        let pendingPath = try #require(try liveEntryIDPath(in: context))
        #expect(!FileManager.default.fileExists(atPath: pendingPath))

        // An unrelated switchyard operation runs while the foreign rebase is
        // live, and its own body throws for reasons that have nothing to do
        // with any rebase.
        #expect(throws: ProbeFailure.self) {
            _ = try JournalCheckpoint.around(operation: "unrelated", at: repo.url.path, git: git) { _ in
                throw ProbeFailure()
            }
        }
        let entries = try JournalAnchor.list(in: context)
        #expect(entries.count == 1, "the unrelated operation's own pre-operation checkpoint is still written")
        let unrelated = try #require(entries.first)

        // The fix under test: a sequencer already live before this call
        // started must never be claimed as this call's own.
        #expect(!FileManager.default.fileExists(atPath: pendingPath),
                "the foreign rebase's slot must never be claimed on the unrelated operation's behalf")

        // Simulate the foreign rebase eventually concluding through
        // switchyard (marker present, exactly as `PostRewrite.decide` would
        // classify a real own conclusion) -- even then, nothing was ever
        // claimed for it to resolve to.
        let decision = PostRewrite.decide(
            sourceArgument: "rebase",
            environment: [GitProcess.markerVariable: "1"],
            readStandardInput: {
                Data("\(String(repeating: "a", count: 40)) \(String(repeating: "b", count: 40))\n".utf8)
            })
        #expect(decision.isOwnInvocation)
        let attached = try JournalCheckpoint.attachRewrite(decision, entryID: nil, in: context)
        #expect(attached == nil, "nothing was ever claimed for the foreign rebase -- there is nothing to attach")

        let unrelatedAfter = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: unrelated.id, in: context))
        #expect(unrelatedAfter.rewrite == nil,
                "the unrelated entry must never receive the foreign rebase's mapping")
    }

    /// #0264's Route 2 probe, updated for guide §11 decision 24 (#0273) --
    /// Finding 1 of #0160's sixth umbrella review, 2026-08-18, and the
    /// **permanent test the issue's own probe becomes**: entry A conflicts,
    /// an out-of-band `git rebase --abort`, then a foreign rebase **from the
    /// same tip** -- no manufactured divergence -- attaches to neither
    /// entry.
    ///
    /// **Why #0264's own fix (the `orig-head` stamp) did not hold**: `git
    /// rebase --abort` restores `HEAD` to exactly the commit the operation
    /// started from, so a retry from the same tip -- the ordinary thing a
    /// caller does after an abort -- carries the identical stamp, and the
    /// slot from the abandoned operation was trusted again. #0264's own
    /// accepted test papered over this by manufacturing an extra commit
    /// between the abort and the foreign rebase, purely so the two
    /// `orig-head`s could never coincide -- which is exactly the kind of
    /// proxy for operation identity decision 24 replaces.
    ///
    /// **Decision 24 needs no such trick.** The file now lives *inside* the
    /// sequencer directory, so A's abort in step 2 deletes A's file along
    /// with the rest of `rebase-merge` -- there is no stale reference left
    /// to survive, coincidental tip or not. The foreign rebase in step 3
    /// gets a brand-new directory with no file in it, so `attachRewrite` in
    /// step 5 finds nothing regardless of which tip either rebase started
    /// from.
    @Test func aStaleSlotPlusAForeignRebaseAttachesToNeitherEntry() throws {
        var repo = try FixtureRepository()
        try repo.build([
            .init("c1", files: ["f.txt": "a\n"]),
            .init("c2", files: ["f.txt": "b\n"]),
            .init("c3", files: ["f.txt": "c\n"]),
        ])
        defer { repo.destroy() }
        let target = try #require(repo.oids["c2"])
        let c1 = try #require(repo.oids["c1"])
        let context = try WorktreeContext.resolve(path: repo.url.path)

        // 1. A conflicting `Fixup.run` (own, via switchyard) leaves slot =
        //    entry A, rebase A live.
        try repo.writeUntracked(["f.txt": "z\n"])
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        let firstThrown = #expect(throws: FixupError.self) {
            _ = try Fixup.run(target: target, at: repo.url.path, extraEnvironment: hermetic)
        }
        guard case .blockedOnConflicts = try #require(firstThrown) else {
            Issue.record("expected .blockedOnConflicts, got \(String(describing: firstThrown))")
            return
        }
        #expect(repo.isMidRebase, "rebase A must be left resumable, not aborted")

        let entries = try JournalAnchor.list(in: context)
        #expect(entries.count == 1)
        let entryA = try #require(entries.first)
        let slotAfterA = try #require(
            try currentInFlightEntryID(in: context),
            "the first conflict must leave the in-flight file naming its own entry")
        #expect(slotAfterA == entryA.id.string)
        let pendingPathForA = try #require(try liveEntryIDPath(in: context))

        // 2. Out of band: the caller aborts A directly, not through Fixup.
        //    Decision 24: the whole `rebase-merge` directory -- our file
        //    included -- is removed by git itself, whatever tip the next
        //    rebase happens to start from.
        _ = try git.run(["rebase", "--abort"], workingDirectory: repo.url.path)
        #expect(!repo.isMidRebase, "the abort must have ended rebase A")
        #expect(try SequencerSnapshot.capture(in: context, git: git) == nil,
                "nothing is live before the foreign rebase starts")
        #expect(!FileManager.default.fileExists(atPath: pendingPathForA),
                "decision 24: the abort removes the whole sequencer directory, our file included")

        // 3. Before any further switchyard operation runs, a genuinely
        //    FOREIGN rebase -- raw Process, no SWITCHYARD_* marker -- goes
        //    live from the EXACT SAME tip the abort left behind. No
        //    manufactured divergence: replaying c3 onto c1 conflicts the
        //    same way it did for A's own rebase in step 1 (the same trigger
        //    `aForeignRebaseAndAnUnrelatedFailingOperationAttachNothing`
        //    above uses), regardless of which commit HEAD is sitting on
        //    after the abort.
        let foreignStatus = try runForeignGit(["rebase", "--onto", c1, target], at: repo.url.path)
        #expect(foreignStatus != 0, "the foreign rebase must stop on a conflict")
        #expect(repo.isMidRebase, "the foreign rebase must be genuinely live")

        // 4. An unrelated switchyard operation fails while the foreign
        //    rebase is live. `sequencerWasLiveBefore` is true for this
        //    call, so it must never write into the foreign rebase's
        //    directory.
        #expect(throws: ProbeFailure.self) {
            _ = try JournalCheckpoint.around(operation: "unrelated", at: repo.url.path, git: git) { _ in
                throw ProbeFailure()
            }
        }
        let entriesAfterUnrelated = try JournalAnchor.list(in: context)
        #expect(entriesAfterUnrelated.count == 2,
                "the unrelated operation's own pre-operation checkpoint is still written")
        let unrelated = try #require(entriesAfterUnrelated.first { $0.id != entryA.id })

        #expect(try currentInFlightEntryID(in: context) == nil,
                "the foreign rebase's own directory must still hold no switchyard-entry-id file")

        // 5. The foreign rebase eventually concludes through switchyard (an
        //    own invocation, marker present) -- exactly the shape a real
        //    `post-rewrite` hook glue (#0217) would classify, called while
        //    the foreign rebase is still genuinely live. The fix under
        //    test: the foreign rebase's own directory, created fresh in
        //    step 3, never had a file written into it -- A's died with A's
        //    directory in step 2 -- so `attachRewrite` finds nothing to
        //    resolve, however the two rebases' tips happen to relate.
        let decision = PostRewrite.decide(
            sourceArgument: "rebase",
            environment: [GitProcess.markerVariable: "1"],
            readStandardInput: {
                Data("\(String(repeating: "a", count: 40)) \(String(repeating: "b", count: 40))\n".utf8)
            })
        #expect(decision.isOwnInvocation)
        let attached = try JournalCheckpoint.attachRewrite(decision, entryID: nil, in: context)
        #expect(attached == nil, "neither A nor the unrelated entry may receive the foreign rebase's mapping")

        let afterA = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: entryA.id, in: context))
        #expect(afterA.rewrite == nil, "entry A, aborted long ago, must never receive the foreign rebase's mapping")

        let afterUnrelated = try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: unrelated.id, in: context))
        #expect(afterUnrelated.rewrite == nil, "the unrelated entry must stay untouched too")

        #expect(try JournalObserved.list(in: context).isEmpty)
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
    /// incidental: `inFlightEntryID` requires `SequencerSnapshot.capture(in:)
    /// != nil` before trusting the file at all (guide §11 decision 24,
    /// #0273). Without a live rebase here, a mutant that reads the file
    /// anyway would find `inFlightEntryID` answering `nil` regardless -- for
    /// the wrong reason -- and this test would redden for the wrong cause.
    /// With a live rebase, the mutant's file read succeeds either way, so
    /// the guard is what this test is actually pinned to.
    @Test func aForeignDecisionWithALiveFilePresentAttachesNothing() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let liveEntry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: context)
        let rebaseMergePath = try makeLiveRebaseMerge(in: context)
        defer { try? FileManager.default.removeItem(atPath: rebaseMergePath) }

        let pendingPath = rebaseMergePath + "/" + RepositoryLayout.sequencerEntryIDFileName
        try liveEntry.id.string.write(toFile: pendingPath, atomically: true, encoding: .utf8)

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
    /// The file sits behind a genuinely live rebase for the same reason as
    /// the test above: under the *correct* precedence `attachRewrite`'s own
    /// ternary guards the read -- `entryID == nil` is false here, so
    /// `inFlightEntryID` is never called and the file is never opened. That
    /// is the ternary's own condition, not `??`'s autoclosure: `fromFile` is
    /// already a materialized value by the time `??` runs below it. So this
    /// fixture's liveness only matters for the mutant, which does open the
    /// file -- and must find a real, resolvable entry there, or the mutant
    /// would wrongly fall through to the environment id anyway and this test
    /// would stop catching the swap.
    @Test func precedenceLandsOnTheEnvironmentEntryNotTheFileEntryWhenBothNameLiveEntries() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let environmentEntry = try JournalCheckpoint.checkpoint(
            operation: "environment-entry", in: context)
        let fileEntry = try JournalCheckpoint.checkpoint(operation: "file-entry", in: context)
        #expect(environmentEntry.id != fileEntry.id, "the two entries must be genuinely different")

        let rebaseMergePath = try makeLiveRebaseMerge(in: context)
        defer { try? FileManager.default.removeItem(atPath: rebaseMergePath) }

        let pendingPath = rebaseMergePath + "/" + RepositoryLayout.sequencerEntryIDFileName
        try fileEntry.id.string.write(toFile: pendingPath, atomically: true, encoding: .utf8)

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

        #expect(FileManager.default.fileExists(atPath: pendingPath),
                "the other operation's in-flight file must not be cleared by this call")
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
    /// file -- `inFlightEntryID` requires a live resumable operation (guide
    /// §11 decision 24, #0273) -- without it, this test would stop
    /// exercising the removal at all and would pass for the wrong reason.
    @Test func aSuccessfulAttachThroughTheFileRemovesIt() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let liveEntry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: context)
        let rebaseMergePath = try makeLiveRebaseMerge(in: context)
        defer { try? FileManager.default.removeItem(atPath: rebaseMergePath) }

        let pendingPath = rebaseMergePath + "/" + RepositoryLayout.sequencerEntryIDFileName
        try liveEntry.id.string.write(toFile: pendingPath, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: pendingPath))

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

    // MARK: - #0286: a failed entry-id write must not replace the body's error

    /// `around`'s catch writes the in-flight entry id with `try?` — a failed
    /// write degrades to no-attach, the same safe degradation every other
    /// path in this mechanism takes, and the body's own error is rethrown
    /// intact. Before this issue the `try` was unguarded, so a permission
    /// failure on that write replaced whatever the body threw --
    /// `FixupError.blockedOnConflicts`, which tells the caller the rebase is
    /// resumable and how, discarded in favour of a file-system error the
    /// caller can do nothing with.
    ///
    /// Made to fail deterministically without touching production code: the
    /// body runs a real conflicting `--apply` rebase (mirroring
    /// `aConflictingApplyBackendRebaseWritesAndReadsTheEntryIDFromRebaseApply`
    /// above, which confirms `rebase-apply/` is genuinely live once this
    /// call throws), and once that call has failed -- so `rebase-apply/`
    /// already exists on disk -- strips the directory's write bit before
    /// rethrowing. `around`'s catch still finds the sequencer live (reading
    /// it needs no write permission) and still attempts the entry-id write,
    /// which now fails with a permission error instead of succeeding. The
    /// permissions are restored before the fixture is torn down.
    @Test func aFailedEntryIDWriteDoesNotReplaceTheBodysError() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }

        // c1, on main: f = "a"
        try "a\n".write(to: repo.url.appendingPathComponent("f"),
                        atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "c1"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        // A side branch off c1.
        try git.run(["checkout", "-qb", "side"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        // c2, back on main: f = "b" -- main moves past c1 on the same line.
        try git.run(["checkout", "-q", "main"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)
        try "b\n".write(to: repo.url.appendingPathComponent("f"),
                        atomically: true, encoding: .utf8)
        try git.run(["commit", "-qam", "c2"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        // c3, on side: f = "c" -- a conflicting edit to the same line.
        try git.run(["checkout", "-q", "side"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)
        try "c\n".write(to: repo.url.appendingPathComponent("f"),
                        atomically: true, encoding: .utf8)
        try git.run(["commit", "-qam", "c3"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        let context = try WorktreeContext.resolve(path: repo.url.path)
        let applyDir = try context.path(for: "rebase-apply")
        defer {
            // Restore the write bit so `repo.destroy()` can remove the tree.
            _ = try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: applyDir)
        }

        var caught: Error?
        do {
            _ = try JournalCheckpoint.around(
                operation: "apply-backend-write-failure", at: repo.url.path
            ) { scoped in
                do {
                    try scoped.run(["rebase", "--apply", "main"], workingDirectory: repo.url.path,
                                   extraEnvironment: hermetic)
                } catch {
                    // `--apply` has already replayed `c3` onto main's `c2`,
                    // conflicted, and left `rebase-apply/` on disk -- strip
                    // its write bit before rethrowing, so `around`'s catch
                    // can still find the sequencer live but cannot write
                    // into it.
                    #expect(FileManager.default.fileExists(atPath: applyDir))
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o500], ofItemAtPath: applyDir)
                    throw error
                }
            }
            Issue.record("expected around to rethrow the body's error")
        } catch {
            caught = error
        }

        let error = try #require(caught, "around must rethrow something")
        #expect(error is GitProcess.Failure,
                "the body's own error must survive a failed entry-id write, not a file-system error")
    }

    /// #0286 round 2: the same principle extends to the two throwing calls
    /// immediately above the write -- `SequencerSnapshot.capture` and
    /// `context.path`, both plumbing through `git`. Either failing would
    /// replace the body's error exactly as the write did, so both are now
    /// guarded (`try?`) in the `if let` chain that decides whether to write
    /// at all.
    ///
    /// Made to fail deterministically without touching production code, and
    /// without the `chmod` trick above: `context.path`'s only failure mode
    /// is `git rev-parse --git-path` itself failing, so this fixture routes
    /// `around` through a `git` shim that forwards every invocation to real
    /// `/usr/bin/git` -- including the real conflicting `--apply` rebase the
    /// body runs, and including `SequencerSnapshot.capture`'s own
    /// `--git-path` calls for `rebase-merge`/`rebase-apply`/`AUTO_MERGE` --
    /// except the one whose `--git-path` argument names
    /// `RepositoryLayout.sequencerEntryIDFileName`, which it fails outright.
    /// That is exactly, and only, the call `around`'s catch makes to resolve
    /// where the entry id would be written.
    @Test func aFailedGitPathResolutionDoesNotReplaceTheBodysError() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }

        // c1, on main: f = "a"
        try "a\n".write(to: repo.url.appendingPathComponent("f"),
                        atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "c1"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        // A side branch off c1.
        try git.run(["checkout", "-qb", "side"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        // c2, back on main: f = "b" -- main moves past c1 on the same line.
        try git.run(["checkout", "-q", "main"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)
        try "b\n".write(to: repo.url.appendingPathComponent("f"),
                        atomically: true, encoding: .utf8)
        try git.run(["commit", "-qam", "c2"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        // c3, on side: f = "c" -- a conflicting edit to the same line.
        try git.run(["checkout", "-q", "side"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)
        try "c\n".write(to: repo.url.appendingPathComponent("f"),
                        atomically: true, encoding: .utf8)
        try git.run(["commit", "-qam", "c3"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        // A shim that is real git for everything except the one `--git-path`
        // name this issue is about -- forwarding, not stubbing, so the
        // fixture's own conflicting rebase and `SequencerSnapshot.capture`'s
        // other lookups behave exactly as they do against real git.
        let shimDir = NSTemporaryDirectory() + "yard-shim-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: shimDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: shimDir) }
        let shimPath = shimDir + "/git-shim.sh"
        let script = """
        #!/bin/sh
        case "$*" in
          *--git-path*\(RepositoryLayout.sequencerEntryIDFileName)*) exit 1 ;;
          *) exec /usr/bin/git "$@" ;;
        esac
        """
        try script.write(toFile: shimPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shimPath)
        let flakyGit = GitProcess(executablePath: shimPath)

        var caught: Error?
        do {
            _ = try JournalCheckpoint.around(
                operation: "apply-backend-path-failure", at: repo.url.path, git: flakyGit
            ) { scoped in
                try scoped.run(["rebase", "--apply", "main"], workingDirectory: repo.url.path,
                               extraEnvironment: hermetic)
            }
            Issue.record("expected around to rethrow the body's error")
        } catch {
            caught = error
        }

        // Both the body's own conflict and the shim's induced failure throw
        // `GitProcess.Failure`, so the type alone cannot tell them apart --
        // `arguments` can: only the body's real `rebase --apply` command
        // names `"rebase"` as an element, and only the shim-failed
        // resolution names `"--git-path"`.
        let error = try #require(caught, "around must rethrow something")
        guard case let .exited(_, _, arguments) = try #require(error as? GitProcess.Failure) else {
            Issue.record("expected a GitProcess.Failure(.exited), got \(error)")
            return
        }
        #expect(arguments.contains("rebase"),
                "the body's own conflicting rebase must be what around rethrows")
        #expect(!arguments.contains("--git-path"),
                "the git-path resolution's own failure must not have replaced the body's error")

        // The shim's fail branch was genuinely exercised, not merely
        // present: the sequencer is still findable through real git (the
        // shim only fails the one name this issue is about), and no
        // entry-id file exists at the path `around` never resolved.
        let context = try WorktreeContext.resolve(path: repo.url.path)
        defer { _ = try? SequencerSnapshot.clear(in: context, git: git) }
        let sequencer = try #require(try SequencerSnapshot.capture(in: context, git: git))
        #expect(sequencer.layout == .rebaseApply)
        let entryIDPath = try context.path(
            for: sequencer.layout.rawValue + "/" + RepositoryLayout.sequencerEntryIDFileName,
            git: git)
        #expect(!FileManager.default.fileExists(atPath: entryIDPath),
                "no file can exist at a path around never successfully resolved")
    }

    /// #0292 (proposal 1 of #0160's eighth umbrella review): the same
    /// principle extends one call earlier -- the `try?
    /// SequencerSnapshot.capture` immediately above the `--git-path`
    /// resolution the previous test pins. Failing it must degrade the same
    /// way: `around`'s catch finds nothing to write into and rethrows the
    /// body's own error unchanged, not a `GitProcess.Failure` from the
    /// capture itself.
    ///
    /// Extends the shim above rather than inventing a third technique, but
    /// it cannot simply fail every `--git-path rebase-merge` call the way
    /// the previous test fails every `--git-path
    /// <sequencerEntryIDFileName>` call: `around` (`sequencerWasLiveBefore`)
    /// and `checkpoint` (inside `JournalLock.withLock`) each call
    /// `SequencerSnapshot.capture` with an unguarded `try` *before* `body`
    /// ever runs, so an unconditional failure would abort `around` before
    /// the body's real conflict ever happens, and this test would pin
    /// nothing. Instead the shim only starts failing `--git-path
    /// rebase-merge` once a marker file exists, and the marker is created by
    /// the body itself -- after its own real rebase has already conflicted
    /// and left `rebase-apply/` live on disk, immediately before
    /// rethrowing -- so the only `--git-path rebase-merge` query the shim
    /// ever fails is the one `around`'s catch makes afterward.
    @Test func aFailedSequencerCaptureDoesNotReplaceTheBodysError() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }

        // c1, on main: f = "a"
        try "a\n".write(to: repo.url.appendingPathComponent("f"),
                        atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "c1"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        // A side branch off c1.
        try git.run(["checkout", "-qb", "side"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        // c2, back on main: f = "b" -- main moves past c1 on the same line.
        try git.run(["checkout", "-q", "main"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)
        try "b\n".write(to: repo.url.appendingPathComponent("f"),
                        atomically: true, encoding: .utf8)
        try git.run(["commit", "-qam", "c2"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        // c3, on side: f = "c" -- a conflicting edit to the same line.
        try git.run(["checkout", "-q", "side"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)
        try "c\n".write(to: repo.url.appendingPathComponent("f"),
                        atomically: true, encoding: .utf8)
        try git.run(["commit", "-qam", "c3"], workingDirectory: repo.url.path,
                    extraEnvironment: hermetic)

        // A shim that is real git for everything except `--git-path
        // rebase-merge` once the marker file below exists.
        let shimDir = NSTemporaryDirectory() + "yard-shim-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: shimDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: shimDir) }
        let shimPath = shimDir + "/git-shim.sh"
        let markerPath = shimDir + "/fail-now"
        let script = """
        #!/bin/sh
        case "$*" in
          *--git-path*rebase-merge*) [ -f "\(markerPath)" ] && exit 1; exec /usr/bin/git "$@" ;;
          *) exec /usr/bin/git "$@" ;;
        esac
        """
        try script.write(toFile: shimPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shimPath)
        let flakyGit = GitProcess(executablePath: shimPath)

        var caught: Error?
        do {
            _ = try JournalCheckpoint.around(
                operation: "apply-backend-capture-failure", at: repo.url.path, git: flakyGit
            ) { scoped in
                do {
                    try scoped.run(["rebase", "--apply", "main"], workingDirectory: repo.url.path,
                                   extraEnvironment: hermetic)
                } catch {
                    // The conflict has already left `rebase-apply/` live --
                    // arm the shim now, so the only `--git-path rebase-merge`
                    // query it ever fails is the one `around`'s catch makes
                    // after this rethrow, not the two that already succeeded
                    // before the body ran (`sequencerWasLiveBefore` and
                    // `checkpoint`'s own capture).
                    try "1".write(toFile: markerPath, atomically: true, encoding: .utf8)
                    throw error
                }
            }
            Issue.record("expected around to rethrow the body's error")
        } catch {
            caught = error
        }

        // Both the body's own conflict and the shim's induced failure throw
        // `GitProcess.Failure`, so the type alone cannot tell them apart --
        // `arguments` can: only the body's real `rebase --apply` command
        // names `"rebase"` as an element, and only the shim-failed capture
        // names `"--git-path"`.
        let error = try #require(caught, "around must rethrow something")
        guard case let .exited(_, _, arguments) = try #require(error as? GitProcess.Failure) else {
            Issue.record("expected a GitProcess.Failure(.exited), got \(error)")
            return
        }
        #expect(arguments.contains("rebase"),
                "the body's own conflicting rebase must be what around rethrows")
        #expect(!arguments.contains("--git-path"),
                "the sequencer capture's own failure must not have replaced the body's error")

        // The shim's fail branch was genuinely exercised, not merely
        // present: once the marker is cleared, real git still finds
        // `rebase-apply/` live, and no entry-id file exists at the path
        // `around` never got far enough to resolve.
        try FileManager.default.removeItem(atPath: markerPath)
        let context = try WorktreeContext.resolve(path: repo.url.path)
        defer { _ = try? SequencerSnapshot.clear(in: context, git: git) }
        let sequencer = try #require(try SequencerSnapshot.capture(in: context, git: git))
        #expect(sequencer.layout == .rebaseApply)
        let entryIDPath = try context.path(
            for: sequencer.layout.rawValue + "/" + RepositoryLayout.sequencerEntryIDFileName,
            git: git)
        #expect(!FileManager.default.fileExists(atPath: entryIDPath),
                "no file can exist at a path around never successfully resolved")
    }
}
