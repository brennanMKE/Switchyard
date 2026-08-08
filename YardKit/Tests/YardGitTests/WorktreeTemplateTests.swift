// WorktreeTemplateTests.swift — untracked-file setup for fresh worktrees (#0023)

import Foundation
import Testing
@testable import YardGit

// MARK: - Fixtures

/// The documented example: a copied secret, a symlinked cache, and a
/// post-create command.
private let exampleJSON = """
{
  "schemaVersion": 1,
  "entries": [
    { "action": "copy", "path": ".env" },
    { "action": "symlink", "path": "node_modules" },
    { "action": "run", "command": "echo ran > post-create.txt" }
  ]
}
"""

/// A repo whose main worktree carries the template file plus the untracked
/// state the entries reference, and one fresh linked worktree to apply into.
/// Returns (repo, destination worktree path).
private func templateFixture(
    _ format: FixtureRepository.RefFormat,
    json: String = exampleJSON
) throws -> (FixtureRepository, String) {
    var repo = try FixtureRepository(refFormat: format)
    try repo.build([.init("base")])
    try repo.writeUntracked([
        WorktreeTemplate.configPath: json,
        ".env": "SECRET=hunter2\n",
        "node_modules/dep/index.js": "// dep\n",
    ])
    let wt = try repo.addWorktree(named: "fresh", branch: "fresh")
    return (repo, FixtureRepository.realPath(wt.path))
}

// MARK: - Loading

@Test func loadReturnsNilWhenTheRepositoryHasNoTemplate() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let template = try WorktreeTemplate.load(fromWorktree: repo.url.path)
    #expect(template == nil)
}

@Test func loadParsesTheDocumentedExample() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base")])
    try repo.writeUntracked([WorktreeTemplate.configPath: exampleJSON])

    let template = try #require(try WorktreeTemplate.load(fromWorktree: repo.url.path))
    #expect(template.entries == [
        .init(action: .copy, path: ".env"),
        .init(action: .symlink, path: "node_modules"),
        .init(action: .run, command: "echo ran > post-create.txt"),
    ])
}

@Test func unsupportedSchemaVersionThrows() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base")])
    try repo.writeUntracked([WorktreeTemplate.configPath:
        #"{ "schemaVersion": 2, "entries": [] }"#])

    #expect(throws: WorktreeTemplate.Failure.unsupportedVersion(2)) {
        try WorktreeTemplate.load(fromWorktree: repo.url.path)
    }
}

@Test func entryMissingItsRequiredFieldThrows() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base")])
    try repo.writeUntracked([WorktreeTemplate.configPath:
        #"{ "schemaVersion": 1, "entries": [ { "action": "copy" } ] }"#])

    #expect(throws: WorktreeTemplate.Failure.invalidEntry(
        index: 0, reason: "copy requires a path")) {
        try WorktreeTemplate.load(fromWorktree: repo.url.path)
    }
}

@Test func malformedJSONThrowsUnreadable() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base")])
    try repo.writeUntracked([WorktreeTemplate.configPath: "not json"])

    #expect(throws: WorktreeTemplate.Failure.self) {
        try WorktreeTemplate.load(fromWorktree: repo.url.path)
    }
}

// MARK: - Applying

@Test(arguments: FixtureRepository.RefFormat.supported())
func copyEntryCopiesTheUntrackedFile(format: FixtureRepository.RefFormat) throws {
    let (repo, wt) = try templateFixture(format)
    defer { repo.destroy() }
    let template = try #require(try WorktreeTemplate.load(fromWorktree: repo.url.path))

    let reports = template.apply(from: repo.url.path, to: wt)
    #expect(reports.count == 3)
    #expect(reports.allSatisfy { $0.succeeded })

    // The copy is a real file with the same bytes, not a link.
    let copied = wt + "/.env"
    let attributes = try FileManager.default.attributesOfItem(atPath: copied)
    #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    let copiedContent = try String(contentsOfFile: copied, encoding: .utf8)
    #expect(copiedContent == "SECRET=hunter2\n")
    // Editing the copy must not touch the source — per-worktree state.
    try "SECRET=changed\n".write(toFile: copied, atomically: true, encoding: .utf8)
    let original = try String(
        contentsOfFile: repo.url.appendingPathComponent(".env").path, encoding: .utf8)
    #expect(original == "SECRET=hunter2\n")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func symlinkEntryLinksToTheSourceWorktree(format: FixtureRepository.RefFormat) throws {
    let (repo, wt) = try templateFixture(format)
    defer { repo.destroy() }
    let template = try #require(try WorktreeTemplate.load(fromWorktree: repo.url.path))
    _ = template.apply(from: repo.url.path, to: wt)

    let link = wt + "/node_modules"
    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: link)
    #expect(dest == repo.url.appendingPathComponent("node_modules").path)
    // The shared cache is reachable through the link.
    let through = try String(
        contentsOfFile: link + "/dep/index.js", encoding: .utf8)
    #expect(through == "// dep\n")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func runEntryExecutesInTheDestinationWorktree(format: FixtureRepository.RefFormat) throws {
    let (repo, wt) = try templateFixture(format)
    defer { repo.destroy() }
    let template = try #require(try WorktreeTemplate.load(fromWorktree: repo.url.path))
    _ = template.apply(from: repo.url.path, to: wt)

    // `echo ran > post-create.txt` ran with the NEW worktree as cwd: the file
    // is in the destination and not in the source.
    let marker = try String(contentsOfFile: wt + "/post-create.txt", encoding: .utf8)
    #expect(marker == "ran\n")
    #expect(!FileManager.default.fileExists(
        atPath: repo.url.appendingPathComponent("post-create.txt").path))
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func missingSourceIsAWarningAndLaterEntriesStillRun(format: FixtureRepository.RefFormat) throws {
    let (repo, wt) = try templateFixture(format, json: """
    {
      "schemaVersion": 1,
      "entries": [
        { "action": "copy", "path": "does-not-exist.cfg" },
        { "action": "copy", "path": ".env" }
      ]
    }
    """)
    defer { repo.destroy() }
    let template = try #require(try WorktreeTemplate.load(fromWorktree: repo.url.path))

    let reports = template.apply(from: repo.url.path, to: wt)
    #expect(reports.count == 2)
    #expect(reports[0].outcome == .missingSource("does-not-exist.cfg"))
    // The entry after the warning was still applied.
    #expect(reports[1].outcome == .applied)
    #expect(FileManager.default.fileExists(atPath: wt + "/.env"))
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func failedCommandIsReportedNotThrownAndDoesNotStopTheRest(
    format: FixtureRepository.RefFormat) throws {
    let (repo, wt) = try templateFixture(format, json: """
    {
      "schemaVersion": 1,
      "entries": [
        { "action": "run", "command": "echo oops >&2; exit 3" },
        { "action": "run", "command": "echo second > second.txt" }
      ]
    }
    """)
    defer { repo.destroy() }
    let template = try #require(try WorktreeTemplate.load(fromWorktree: repo.url.path))

    let reports = template.apply(from: repo.url.path, to: wt)
    #expect(reports.count == 2)
    guard case let .commandFailed(exitCode, stderr) = reports[0].outcome else {
        Issue.record("expected commandFailed, got \(reports[0].outcome)")
        return
    }
    #expect(exitCode == 3)
    #expect(stderr.contains("oops"))
    #expect(reports[1].outcome == .applied)
    #expect(FileManager.default.fileExists(atPath: wt + "/second.txt"))
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func existingDestinationIsLeftUntouched(format: FixtureRepository.RefFormat) throws {
    let (repo, wt) = try templateFixture(format)
    defer { repo.destroy() }
    // The destination already has its own .env.
    try "SECRET=mine\n".write(toFile: wt + "/.env", atomically: true, encoding: .utf8)
    let template = try #require(try WorktreeTemplate.load(fromWorktree: repo.url.path))

    let reports = template.apply(from: repo.url.path, to: wt)
    #expect(reports[0].outcome == .destinationExists(".env"))
    let kept = try String(contentsOfFile: wt + "/.env", encoding: .utf8)
    #expect(kept == "SECRET=mine\n")
}

@Test func reportsNeverCarryFileContents() throws {
    // Secrets are copied by the template; their bytes must never appear in
    // what the engine reports (or logs — the engine does not log at all).
    // The Report type carries an Entry (action, path, command) and an
    // Outcome (paths, exit code, stderr of the caller's own command) — this
    // test pins the copy path's outcome to the content-free cases.
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base")])
    try repo.writeUntracked([
        WorktreeTemplate.configPath: exampleJSON,
        ".env": "SECRET=hunter2\n",
        "node_modules/dep/index.js": "// dep\n",
    ])
    let wt = try repo.addWorktree(named: "quiet", branch: "quiet")
    let template = try #require(try WorktreeTemplate.load(fromWorktree: repo.url.path))

    let reports = template.apply(
        from: repo.url.path, to: FixtureRepository.realPath(wt.path))
    for report in reports {
        #expect(!String(describing: report).contains("hunter2"))
    }
}
