// RerereSurfaceTests.swift
//
// The app surface of #0065 round 2, tested through YardUI's public API —
// this target imports YardUI WITHOUT `@testable` (see
// `RepositorySidebarLoaderTests`' header for why). The engine calls the
// loaders wrap (`Rerere.status`, `Rerere.resolution(for:)`, `rerereForget`)
// are exercised through those public loaders and directly, against real
// fixture repositories and real git, using the conflict recipe and the
// measured byte shapes the #0065 round-1 and round-2 probes pinned.
//
// NOT covered here, deliberately: the click → pane rendering itself
// (SwiftUI, not assertable headless — the same line
// `RepositoryTabsTests` draws for the tab chrome). What IS asserted is
// everything the routing is built from: the loader payload the sidebar
// section renders, the id → entry seam the Detail pane resolves a
// selection through, the recorded-diff bytes the detail view shows, the
// forget gate and its engine call, and the public constructibility of the
// views the route joins.

import Foundation
import SwiftUI
import Testing
import YardGit
import YardUI

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

private let git = GitProcess()

/// Builds `base → (ours edit of f.txt) + (side edit of f.txt)` with rerere
/// enabled, merges, resolves `f.txt` to `a/R/c`, and commits — the recorded
/// resolution's fixture. The measured rr-cache bytes for it (round-2 probe):
/// preimage `a\n<<<<<<<\nB\n=======\nX\n>>>>>>>\nc\n`, postimage `a\nR\nc\n`.
private func recordedFixture() throws -> FixtureRepository {
    var repo = try FixtureRepository()
    try repo.build([
        .init("base", files: ["f.txt": "a\nb\nc\n"]),
        .init("side", parents: ["base"], files: ["f.txt": "a\nB\nc\n"]),
        .init("ours", parents: ["base"], files: ["f.txt": "a\nX\nc\n"]),
    ])
    try git.run(["config", "rerere.enabled", "true"], workingDirectory: repo.url.path)
    let side = try #require(repo.oids["side"])
    // The conflicting merge exits 1 by design; capture, never run.
    _ = try git.capture(
        ["merge", "--no-commit", side], workingDirectory: repo.url.path,
        extraEnvironment: hermetic)
    try "a\nR\nc\n".write(
        to: repo.url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    try git.run(["add", "f.txt"], workingDirectory: repo.url.path)
    try git.run(["commit", "-q", "-m", "resolved"], workingDirectory: repo.url.path)
    return repo
}

/// Resets the fixture back to the pre-merge commit and re-merges `side`,
/// re-raising the identical conflict — the merge machinery replays the
/// recorded resolution into the working file.
private func reraise(in repo: FixtureRepository) throws {
    try git.run(["reset", "-q", "--hard", "HEAD~1"], workingDirectory: repo.url.path)
    let side = try #require(repo.oids["side"])
    _ = try git.capture(
        ["merge", "--no-commit", side], workingDirectory: repo.url.path,
        extraEnvironment: hermetic)
}

// MARK: - The loader payload the sidebar section renders

@Test("loadRepositorySidebar carries the recorded rerere resolution and its id resolves the entry")
func loadRepositorySidebarCarriesRecordedResolution() async throws {
    let repo = try recordedFixture()
    defer { repo.destroy() }

    let sidebar = try await loadRepositorySidebar(at: repo.url.path)

    #expect(sidebar.rerere.enabled, "the fixture enabled rerere; the summary must report it")
    #expect(sidebar.rerere.entries.count == 1, "one recorded conflict, one entry; got \(sidebar.rerere.entries.count)")
    let entry = try #require(sidebar.rerere.entries.first, "the recorded resolution must be in the summary")
    #expect(entry.state == .recorded)
    #expect(entry.conflictID.count >= 40)
    #expect(entry.conflictID.allSatisfy { $0.isHexDigit })
    #expect(entry.paths.isEmpty, "the conflict has settled; no live path is attributed")
    // The selection seam: the Detail pane resolves a selected conflict id
    // against exactly this payload — the id the sidebar row carries must
    // find the entry again.
    let resolved = try #require(
        sidebar.rerere.entries.first(where: { $0.conflictID == entry.conflictID }),
        "the row's conflict id must resolve to its entry")
    #expect(resolved.conflictID == entry.conflictID)
    #expect(resolved.state == .recorded)
}

@Test("loadRepositorySidebar reports rerere disabled with no entries when nothing is recorded")
func loadRepositorySidebarReportsRerereDisabledShape() async throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["f.txt": "a\n"])])

    let sidebar = try await loadRepositorySidebar(at: repo.url.path)

    #expect(!sidebar.rerere.enabled, "rerere is git-disabled by default; the summary must say so")
    #expect(sidebar.rerere.entries.isEmpty)
}

// MARK: - The recorded diff the Detail pane shows

@Test("loadRerereResolution returns the measured preimage and postimage bytes and the git-shaped diff")
func loadRerereResolutionReturnsMeasuredBytesAndDiffShape() async throws {
    let repo = try recordedFixture()
    defer { repo.destroy() }

    let status = try Rerere.status(at: repo.url.path, git: git, extraEnvironment: hermetic)
    let entry = try #require(status.entries.first)
    let resolution = try await loadRerereResolution(
        at: repo.url.path, conflictID: entry.conflictID)

    // Byte-for-byte against the round-2 probe (xxd of rr-cache/<id>/…):
    // the preimage is the conflict with markers, rerere-normalized (no
    // branch labels); the postimage is the resolution as written.
    #expect(String(decoding: resolution.preimage, as: UTF8.self)
        == "a\n<<<<<<<\nB\n=======\nX\n>>>>>>>\nc\n")
    #expect(String(decoding: resolution.postimage, as: UTF8.self) == "a\nR\nc\n")
    #expect(resolution.path == nil, "the conflict has settled; no path can be attributed")
    #expect(resolution.diff.count == 1, "one text file, one diff; got \(resolution.diff.count)")

    // The diff shape, pinned exactly: one hunk spanning both sides whole,
    // git's `@@ -1,7 +1,3 @@` header, and the marker-prefixed body.
    let file = try #require(resolution.diff.first)
    #expect(file.path == "rr-cache (path not attributed)")
    #expect(!file.isBinary)
    let hunk = try #require(file.hunks.first)
    #expect(hunk.header == "@@ -1,7 +1,3 @@")
    #expect(hunk.body == [
        " a",
        "-<<<<<<<",
        "-B",
        "-=======",
        "-X",
        "->>>>>>>",
        "+R",
        " c",
    ])
}

@Test("loadRerereResolution refuses an id that names no recorded resolution")
func loadRerereResolutionRefusesUnrecordedID() async throws {
    let repo = try recordedFixture()
    defer { repo.destroy() }

    // A well-formed id that names no rr-cache directory…
    let unknown = String(repeating: "0", count: 40)
    await #expect {
        _ = try await loadRerereResolution(at: repo.url.path, conflictID: unknown)
    } throws: { error in
        if case RerereError.noRecordedResolution = error { return true }
        return false
    }
    // …and a string that cannot be a conflict id at all (and must never
    // become a path component).
    await #expect {
        _ = try await loadRerereResolution(at: repo.url.path, conflictID: "../escape")
    } throws: { error in
        if case RerereError.noRecordedResolution = error { return true }
        return false
    }}

@Test("loadRerereResolution refuses a conflict whose resolution was forgotten")
func loadRerereResolutionRefusesMerelyKnownConflict() async throws {
    let repo = try recordedFixture()
    defer { repo.destroy() }
    try reraise(in: repo)
    let before = try Rerere.status(at: repo.url.path, git: git, extraEnvironment: hermetic)
    let recorded = try #require(before.entries.first { $0.state == .recorded })
    _ = try rerereForget(
        at: repo.url.path, recorded.paths, git: git, extraEnvironment: hermetic)

    let after = try Rerere.status(at: repo.url.path, git: git, extraEnvironment: hermetic)
    let known = try #require(after.entries.first { $0.conflictID == recorded.conflictID })
    #expect(known.state == .known, "the forget left the preimage but no resolution")
    await #expect {
        _ = try await loadRerereResolution(at: repo.url.path, conflictID: known.conflictID)
    } throws: { error in
        if case RerereError.noRecordedResolution = error { return true }
        return false
    }
}

// MARK: - The forget call and its observable state

@Test("rerereForget removes the recorded resolution and the status shows it merely known")
func rerereForgetRemovesRecordedResolution() async throws {
    let repo = try recordedFixture()
    defer { repo.destroy() }
    try reraise(in: repo)
    let before = try Rerere.status(at: repo.url.path, git: git, extraEnvironment: hermetic)
    let recorded = try #require(before.entries.first { $0.state == .recorded })
    #expect(recorded.paths == ["f.txt"], "the replayed conflict attributes its path; got \(recorded.paths)")

    let outcome = try await forgetRerereResolution(at: repo.url.path, recorded.paths)

    #expect(outcome.forgot == ["f.txt"], "git's own report of the removal; got \(outcome.forgot)")
    #expect(outcome.updatedPreimage == ["f.txt"],
            "the measured run also rewrites the preimage; got \(outcome.updatedPreimage)")
    let after = try Rerere.status(at: repo.url.path, git: git, extraEnvironment: hermetic)
    let known = try #require(
        after.entries.first { $0.conflictID == recorded.conflictID },
        "the forgotten entry keeps its rr-cache directory (preimage remains)")
    #expect(known.state == .known, "the recorded resolution is gone; only the preimage remains")
    #expect(known.paths == ["f.txt"], "forget wrote MERGE_RR, so the path is attributed again")
    #expect(known.replayedPaths.isEmpty)
}

@Test("rerereForget refuses a path with nothing recorded and leaves the record intact")
func rerereForgetRefusesPathWithNothingRecorded() async throws {
    let repo = try recordedFixture()
    defer { repo.destroy() }

    // The measured silent no-op shape: git exits 0 and changes nothing for
    // a path that names no resolution. The engine must refuse it instead.
    #expect {
        _ = try rerereForget(
            at: repo.url.path, ["no-such.txt"], git: git, extraEnvironment: hermetic)
    } throws: { error in
        if case RerereForgetError.nothingRecorded = error { return true }
        return false
    }
    let after = try Rerere.status(at: repo.url.path, git: git, extraEnvironment: hermetic)
    #expect(after.entries.contains { $0.state == .recorded },
            "the refusal must not have disturbed the recorded resolution")
}

@Test("rerereForget refuses an empty path list")
func rerereForgetRefusesEmptyPathList() async throws {
    let repo = try recordedFixture()
    defer { repo.destroy() }

    #expect {
        _ = try rerereForget(at: repo.url.path, [], git: git, extraEnvironment: hermetic)
    } throws: { error in
        if case RerereForgetError.emptyPaths = error { return true }
        return false
    }
    let after = try Rerere.status(at: repo.url.path, git: git, extraEnvironment: hermetic)
    #expect(after.entries.contains { $0.state == .recorded })
}

// MARK: - The forget gate and the public surface the route is built from

@MainActor
@Test("a resolution with a live path can be forgotten; a settled one cannot")
func forgetGateFollowsAttributedPaths() {
    let attributed = Rerere.Entry(
        conflictID: String(repeating: "a", count: 40), state: .recorded,
        paths: ["f.txt"], replayedPaths: [])
    let settled = Rerere.Entry(
        conflictID: String(repeating: "b", count: 40), state: .recorded,
        paths: [], replayedPaths: [])

    // Both views construct here, so the gate is read at exactly the access
    // level the app target sees.
    let withPath = RerereDetailView(
        repositoryPath: "/tmp/repo", entry: attributed, resolution: nil, resolutionError: nil)
    #expect(withPath.canForgetResolution,
            "git forget is path-keyed; an attributed path makes the arm offerable")
    let withoutPath = RerereDetailView(
        repositoryPath: "/tmp/repo", entry: settled, resolution: nil, resolutionError: nil)
    #expect(!withoutPath.canForgetResolution,
            "no measured git surface forgets by conflict id; the arm must not offer")
}

@MainActor
@Test("the sidebar and detail views are constructible with the rerere surface at a caller's access level")
func rerereViewsArePubliclyConstructible() throws {
    // Both fail to COMPILE if the boundary breaks: the sidebar's selection
    // binding and the detail's entry/resolution inputs are the public
    // contract the app target wires ContentView through.
    let summary = RepositorySidebarSummary(
        refs: RefSnapshot(head: .symbolic(target: "refs/heads/main"), refs: []),
        worktrees: [],
        currentWorktreePath: "/tmp/repo",
        rerere: Rerere.Status(
            enabled: true,
            entries: [
                Rerere.Entry(
                    conflictID: String(repeating: "a", count: 40), state: .recorded,
                    paths: ["f.txt"], replayedPaths: [])
            ]))
    var selected: String?
    let sidebar = RepositorySidebarView(
        summary: summary, stashCount: 0,
        selectedResolution: Binding(get: { selected }, set: { selected = $0 }))
    _ = sidebar

    let entry = try #require(summary.rerere.entries.first)
    let detail = RerereDetailView(
        repositoryPath: "/tmp/repo", entry: entry, resolution: nil, resolutionError: nil)
    _ = detail

    // Falsifiable assertions, so this is not merely a compile contract.
    #expect(String(describing: RepositorySidebarView.self) == "RepositorySidebarView")
    #expect(String(describing: RerereDetailView.self) == "RerereDetailView")
    #expect(detail.canForgetResolution, "the constructed entry carries a path, so the gate opens")
}
