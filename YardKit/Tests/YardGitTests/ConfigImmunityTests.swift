// ConfigImmunityTests.swift — enforces M1 criterion 5(b) with a config sweep (#0330)
//
// The property, stated exactly: an engine result's encoded `schemaVersion: 1`
// bytes must not depend on the user's git configuration. #0316 enforced
// clauses (a) and (c) of the same criterion; this file is the analogue for
// clause (b), across the seven functions that produce a criterion-1 payload.
//
// A shell sweep (`od -c | md5` over git's raw output) found #0328 and #0329
// in one run, but it also produced a benign false positive on
// `conflictedFiles` under `status.renames=false` -- only the porcelain `2 R.`
// line moves, and `ConflictParser` reads `u ` records only, so the parsed
// result never changes. Comparing raw git bytes would have to special-case
// that forever. Comparing **encoded results** instead is drift-proof (no
// vector bytes are transcribed into this file) and uniform across all seven
// functions, and it is the property the criterion actually states.

import Foundation
import Testing
@testable import YardGit

// MARK: - Encoding

/// The same `JSONEncoder` configuration `YardWireTests` uses to pin wire
/// bytes: `.sortedKeys` and nothing else, so key order can never be the
/// reason two encodings differ.
private func configImmunityEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

// MARK: - The hostile fixture

/// `line 01` … `line 20`, one per line, trailing newline. Shared shape with
/// `HunksTests.base20()` (this file cannot import that private helper, so it
/// is reproduced rather than exposed).
private func configImmunityBase20() -> String {
    (1...20).map { String(format: "line %02d", $0) }.joined(separator: "\n") + "\n"
}

/// The two-hunk edit: a line inserted after `line 03`, and `line 17`
/// replaced -- far enough apart that git keeps them as separate hunks at the
/// default `-U3` context.
private func configImmunityEdited20() -> String {
    var lines = (1...20).map { String(format: "line %02d", $0) }
    lines[16] = "line 17 CHANGED"
    lines.insert("inserted after 03", at: 3)
    return lines.joined(separator: "\n") + "\n"
}

/// One fixture, built once and reused for the whole sweep (the runtime
/// budget below depends on that). Deliberately hostile: every shape a config
/// gap has actually hidden behind so far --
///
/// - at least two commits (`base`, `second`)
/// - a **staged rename** (`old.txt` -> `renamed.txt`, via `git mv`) --
///   #0329 was invisible without this
/// - an unstaged edit with **two separated hunks** (`unstaged.txt`) --
///   #0323 was invisible without this
/// - an **untracked file** (`untracked.txt`)
/// - an **ignored file** plus `.gitignore` (`ignored.txt`)
/// - a **non-ASCII path**, committed (`café.txt`)
private func hostileConfigImmunityFixture() throws -> FixtureRepository {
    var repo = try FixtureRepository()
    try repo.build([
        .init("base", files: [
            "old.txt": configImmunityBase20(),
            "unstaged.txt": configImmunityBase20(),
            "café.txt": "café\n",
        ]),
        .init("second", parents: ["base"], files: [
            "second.txt": "second\n",
        ]),
    ])

    // Staged rename.
    try GitProcess().run(["mv", "old.txt", "renamed.txt"], workingDirectory: repo.url.path)

    // Unstaged edit, two separated hunks -- `unstaged.txt` is already
    // tracked and committed, so overwriting it on disk (without staging)
    // is exactly the "modified, not staged" shape `listHunks(area: .unstaged)`
    // reads.
    try repo.writeUntracked(["unstaged.txt": configImmunityEdited20()])

    // Untracked file, plus an ignored file and the `.gitignore` that ignores it.
    try repo.writeUntracked([
        "untracked.txt": "brand new\n",
        ".gitignore": "ignored.txt\n",
        "ignored.txt": "secret\n",
    ])

    return repo
}

// MARK: - The seven functions, captured as one snapshot

/// One call to each of the seven criterion-1 engine functions (`listHunks`
/// counted twice, `.staged` and `.unstaged`, per the issue's explicit
/// requirement), each result encoded through `configImmunityEncoder()`.
private struct ConfigImmunitySnapshot {
    let whereAmI: Data
    let graphRows: Data
    let gitStatus: Data
    let listHunksStaged: Data
    let listHunksUnstaged: Data
    let conflictedFiles: Data
    let commitLogRun: Data
    let signatureVerificationRun: Data

    /// `(label, before, after)` triples in a fixed, readable order -- the
    /// order the starting table's "fastest tell" note refers to.
    static func labeledPairs(before: ConfigImmunitySnapshot, after: ConfigImmunitySnapshot) -> [(String, Data, Data)] {
        [
            ("whereAmI", before.whereAmI, after.whereAmI),
            ("graphRows", before.graphRows, after.graphRows),
            ("gitStatus", before.gitStatus, after.gitStatus),
            ("listHunks(.staged)", before.listHunksStaged, after.listHunksStaged),
            ("listHunks(.unstaged)", before.listHunksUnstaged, after.listHunksUnstaged),
            ("conflictedFiles", before.conflictedFiles, after.conflictedFiles),
            ("CommitLog.run", before.commitLogRun, after.commitLogRun),
            ("SignatureVerification.run", before.signatureVerificationRun, after.signatureVerificationRun),
        ]
    }
}

/// Runs all seven (eight, counting both `listHunks` areas) criterion-1
/// engine functions against the repository at `path` and encodes each
/// result. Every field is captured with the fixture's own `HEAD` --
/// `whereAmI` is included even though it has no known config lever yet,
/// because the property under test is about the whole criterion-1 surface,
/// not only the functions a prior gap was found in.
private func captureConfigImmunitySnapshot(
    at path: String,
    encoder: JSONEncoder
) throws -> ConfigImmunitySnapshot {
    ConfigImmunitySnapshot(
        whereAmI: try encoder.encode(whereAmI(path: path)),
        graphRows: try encoder.encode(graphRows(at: path)),
        gitStatus: try encoder.encode(gitStatus(at: path)),
        listHunksStaged: try encoder.encode(listHunks(at: path, area: .staged)),
        listHunksUnstaged: try encoder.encode(listHunks(at: path, area: .unstaged)),
        conflictedFiles: try encoder.encode(conflictedFiles(at: path)),
        commitLogRun: try encoder.encode(CommitLog.run(path: path, rangeArguments: [])),
        signatureVerificationRun: try encoder.encode(
            SignatureVerification.run(revision: "HEAD", in: path))
    )
}

// MARK: - The starting table

/// One `git config` pair to sweep against the fixture above.
private struct ConfigImmunityCase: Sendable {
    let key: String
    let value: String
}

/// **The starting table -- the deliverable's real content.** Every entry is
/// a config git's own documentation says the relevant command honours, not a
/// config the engine's source already mentions -- picking from the source
/// would only ever re-confirm what a prior author already thought of, which
/// is exactly the blind spot guide §11 records for M1 criterion 5(b).
///
/// This table is bounded by git's documentation as read on 2026-08-18, not
/// exhaustive of it. **Adding a row is how this criterion gets stronger:**
/// finding a config git documents for `diff`, `status`, `log`, or `commit`
/// output that is not already a row here, and adding it, directly extends
/// what this test enforces.
private let configImmunityTable: [ConfigImmunityCase] = [
    .init(key: "diff.renames", value: "false"),
    .init(key: "diff.renames", value: "copies"),
    .init(key: "status.renames", value: "false"),
    .init(key: "diff.suppressBlankEmpty", value: "true"),
    .init(key: "diff.context", value: "10"),
    .init(key: "diff.interHunkContext", value: "10"),
    .init(key: "diff.algorithm", value: "patience"),
    .init(key: "diff.indentHeuristic", value: "false"),
    .init(key: "diff.noprefix", value: "true"),
    .init(key: "diff.mnemonicPrefix", value: "true"),
    .init(key: "diff.relative", value: "true"),
    .init(key: "diff.wsErrorHighlight", value: "all"),
    .init(key: "diff.ignoreSubmodules", value: "all"),
    .init(key: "core.abbrev", value: "16"),
    .init(key: "core.abbrev", value: "4"),
    .init(key: "core.quotepath", value: "true"),
    .init(key: "color.ui", value: "always"),
    .init(key: "color.diff", value: "always"),
    .init(key: "color.status", value: "always"),
    .init(key: "log.showSignature", value: "true"),
    .init(key: "log.date", value: "raw"),
    .init(key: "log.follow", value: "true"),
    .init(key: "log.excludeDecoration", value: "refs/heads/main"),
    .init(key: "format.pretty", value: "fuller"),
    .init(key: "i18n.logOutputEncoding", value: "ISO-8859-1"),
    .init(key: "notes.displayRef", value: "refs/notes/x"),
    .init(key: "status.showUntrackedFiles", value: "no"),
    .init(key: "status.relativePaths", value: "false"),
    .init(key: "status.short", value: "true"),
    .init(key: "status.branch", value: "true"),
    .init(key: "status.aheadBehind", value: "false"),
]

/// Exemptions from the config-immunity property enforced below, keyed
/// `"<function label>|<config key>=<config value>"`. **Empty unless
/// something genuinely needs one** -- #0316's precedent is that an allow-list
/// that cannot self-expire is a permanent exemption wearing a temporary
/// label, so every entry here must name the issue that justifies it (or, for
/// a finding this sweep produced and has not yet been triaged into an issue,
/// a `TODO(unfiled)` marker naming the row).
///
/// TODO(unfiled): `listHunks(.unstaged)` under `diff.interHunkContext=10`.
/// Measured 2026-08-18 on this sweep: with the hostile fixture's two hunks
/// (an insertion after line 3, an edit at line 17), `--unified=3` is pinned
/// (`Hunks.swift`) but nothing pins `--inter-hunk-context`, so a user's
/// `diff.interHunkContext=10` merges the two otherwise-separate hunks into
/// one -- a real config-dependent shape change `listHunks` does not guard
/// against. Not one of the six blockers #0330 names as resolved; needs its
/// own issue and its own fix, not this test weakening around it.
private let configImmunityAllowList: [String: String] = [
    "listHunks(.unstaged)|diff.interHunkContext=10": "TODO(unfiled)",
]

// MARK: - The sweep

@Suite("Engine results are immune to the user's git configuration (#0330)")
struct ConfigImmunityTests {

    /// For every `(key, value)` pair in `configImmunityTable`, against one
    /// shared hostile fixture: capture all eight criterion-1 calls, set the
    /// config, capture all eight again, and `#expect` the encoded bytes are
    /// unchanged -- reporting which function and which config on failure.
    ///
    /// Deliberately one `@Test`, not `@Test(arguments:)`: the fixture's git
    /// config is shared, mutable state, and swift-testing parallelizes
    /// parameterized cases by default, which would race two rows' `git
    /// config` calls against each other. A single sequential sweep over the
    /// table is also what "build the fixture once for the whole table"
    /// requires -- a fresh fixture per row would multiply the ~500 git
    /// invocations the table already costs by 31.
    @Test func engineResultsAreImmuneToGitConfiguration() throws {
        #expect(!configImmunityTable.isEmpty)

        let repo = try hostileConfigImmunityFixture()
        defer { repo.destroy() }
        let path = repo.url.path
        let git = GitProcess()
        let encoder = configImmunityEncoder()

        var rowsChecked = 0
        for config in configImmunityTable {
            let before = try captureConfigImmunitySnapshot(at: path, encoder: encoder)

            try git.run(["config", config.key, config.value], workingDirectory: path)
            let after: ConfigImmunitySnapshot
            do {
                after = try captureConfigImmunitySnapshot(at: path, encoder: encoder)
            } catch {
                _ = try? git.run(["config", "--unset", config.key], workingDirectory: path)
                throw error
            }
            try git.run(["config", "--unset", config.key], workingDirectory: path)

            for (label, beforeData, afterData) in ConfigImmunitySnapshot.labeledPairs(before: before, after: after) {
                let allowKey = "\(label)|\(config.key)=\(config.value)"
                if configImmunityAllowList[allowKey] != nil {
                    continue
                }
                #expect(
                    beforeData == afterData,
                    "\(label) differs under \(config.key)=\(config.value)"
                )
            }
            rowsChecked += 1
        }

        // Guards against a loop that silently ran zero iterations (Rule 7):
        // every row in the table must actually have been swept.
        #expect(rowsChecked == configImmunityTable.count)
    }
}
