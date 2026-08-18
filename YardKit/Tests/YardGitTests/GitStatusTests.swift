// GitStatusTests.swift — behavioural tests for the public `gitStatus` function.
//
// `WorktreeStatusTests.swift` exercises `WorktreeStatusParser` directly, feeding
// it hand-built porcelain bytes; it never calls `gitStatus` itself. That left
// `gitStatus(at:includeIgnored:git:)` (`WorktreeStatus.swift:424`) — its own
// argument construction and the `git status` invocation it wires up — with no
// test that could fail (#0245). This file closes that gap: it runs real git
// against real fixtures and asserts on the exact parsed result, the shape
// `ConflictsTests` already uses and the mutated review found missing here.

import Foundation
import Testing
@testable import YardGit

struct GitStatusTests {

    @Test("gitStatus(includeIgnored:) reveals a gitignored file only when true")
    func includeIgnoredRevealsGitignoredFile() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        try repo.writeUntracked([
            ".gitignore": "ignored.txt\n",
            "ignored.txt": "secret\n",
        ])

        // Without --ignored: only the (untracked) .gitignore itself is
        // reported. The gitignored file must be absent, not merely "some
        // entries exist" — that is the assertion the flag had no coverage for.
        let withoutIgnored = try gitStatus(at: repo.url.path, includeIgnored: false)
        #expect(withoutIgnored.entries.map(\.path) == [".gitignore"])

        // With --ignored: the gitignored file now appears, reported via the
        // porcelain "!" record.
        let withIgnored = try gitStatus(at: repo.url.path, includeIgnored: true)
        #expect(withIgnored.entries.map(\.path) == [".gitignore", "ignored.txt"])

        let ignoredEntry = try #require(withIgnored.entries.first(where: { $0.path == "ignored.txt" }))
        #expect(ignoredEntry.worktree == .ignored)
        #expect(ignoredEntry.staged == .unmodified)
    }

    @Test("gitStatus reports the exact path of an untracked file, newline included")
    func reportsExactPathWithNewline() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        // A path containing a literal newline round-trips only if the "-z"
        // NUL-terminated form is actually used; git's default LF-separated,
        // quoted-path output would mangle it into a C-quoted literal instead
        // of the real byte. `WorktreeListTests.newlineInPathRoundTrips` is the
        // precedent for this shape.
        let name = "has\nnewline.txt"
        try repo.writeUntracked([name: "content\n"])

        let status = try gitStatus(at: repo.url.path)

        // Exact path, not merely "some non-empty path" — the linear fixture's
        // tree is otherwise clean, so this is the only entry.
        #expect(status.entries.map(\.path) == [name])

        let entry = try #require(status.entries.first)
        #expect(entry.path == name)
        #expect(entry.worktree == .untracked)
        #expect(entry.staged == .unmodified)
    }

    @Test("gitStatus reports staged and unstaged states for tracked modifications")
    func reportsStagedAndUnstagedTrackedModifications() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let git = GitProcess()

        // Both files must be TRACKED before an edit reads as a modification --
        // an uncommitted new file is `?`, not `M`. Commit both first.
        try repo.writeUntracked([
            "staged.txt": "original staged\n",
            "unstaged.txt": "original unstaged\n",
        ])
        try git.run(["add", "staged.txt", "unstaged.txt"], workingDirectory: repo.url.path)
        try git.run(["commit", "-q", "-m", "track staged.txt and unstaged.txt"],
                    workingDirectory: repo.url.path)

        // staged.txt: modify AND stage the modification -- the `M.` case,
        // reported through `staged`.
        try "staged change\n".write(
            to: repo.url.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
        try git.run(["add", "staged.txt"], workingDirectory: repo.url.path)

        // unstaged.txt: modify WITHOUT staging -- the `.M` case, reported
        // through `worktree`.
        try "unstaged change\n".write(
            to: repo.url.appendingPathComponent("unstaged.txt"), atomically: true, encoding: .utf8)

        let status = try gitStatus(at: repo.url.path)

        // Exact entry set, not merely "some entries exist" -- the linear
        // fixture's tree is otherwise clean.
        #expect(Set(status.entries.map(\.path)) == ["staged.txt", "unstaged.txt"])

        let staged = try #require(status.entries.first(where: { $0.path == "staged.txt" }))
        #expect(staged.staged == .modified, "a staged modification must report staged as modified")
        #expect(staged.worktree == .unmodified, "a staged-only modification leaves the worktree side clean")

        let unstaged = try #require(status.entries.first(where: { $0.path == "unstaged.txt" }))
        #expect(unstaged.staged == .unmodified, "an unstaged modification must not report staged as modified")
        #expect(unstaged.worktree == .modified, "an unstaged modification must report worktree as modified")
    }

    @Test("gitStatus reports the original path of a staged rename")
    func reportsOriginalPathOfStagedRename() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let git = GitProcess()

        try repo.writeUntracked(["original.txt": "content\n"])
        try git.run(["add", "original.txt"], workingDirectory: repo.url.path)
        try git.run(["commit", "-q", "-m", "track original.txt"], workingDirectory: repo.url.path)

        // `git mv` renames on disk and stages the rename in one step -- git
        // detects it as a `2 R.` record with no explicit `-M` needed, since
        // the content is unchanged (measured: `status.renames` defaults on).
        try git.run(["mv", "original.txt", "renamed.txt"], workingDirectory: repo.url.path)

        let status = try gitStatus(at: repo.url.path)

        #expect(status.entries.map(\.path) == ["renamed.txt"])

        let renamed = try #require(status.entries.first)
        #expect(renamed.originalPath == "original.txt")
        #expect(renamed.originalPathBytes == Array("original.txt".utf8))
        #expect(renamed.staged == .modified, "a rename is reported on the staged side")
        #expect(renamed.worktree == .unmodified)
    }

    @Test("gitStatus does not throw on a repository configured for copy detection")
    func doesNotThrowOnCopyDetectionRepository() throws {
        // #0310: `status.renames=copies` makes real git emit a `2 C.` record
        // -- distinct from `EnumVocabularyCoverageTests`' alphabet table
        // (#0316), which feeds `WorktreeStatusParser` a hand-built, synthetic
        // `C.` record and so proves only that the character-to-state mapping
        // is right, never that real git's on-disk `C` record actually
        // decodes through `gitStatus`'s full pipeline (real `git status`
        // invocation, real `-z` framing) without throwing.
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let git = GitProcess()

        // Copy detection is off by default; git only looks for copies when
        // asked. Scoped to this repository -- FixtureRepository never
        // touches global config.
        try git.run(["config", "status.renames", "copies"], workingDirectory: repo.url.path)

        try repo.writeUntracked(["original.txt": "aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc\n"])
        try git.run(["add", "original.txt"], workingDirectory: repo.url.path)
        try git.run(["commit", "-q", "-m", "track original.txt"], workingDirectory: repo.url.path)

        // A copy git reports as a plain add unless its source is ALSO
        // modified -- measured 2026-08-18, git 2.50.1. Copy first, then
        // modify the source, then stage both.
        try FileManager.default.copyItem(
            at: repo.url.appendingPathComponent("original.txt"),
            to: repo.url.appendingPathComponent("copied.txt"))
        try "extra line to modify the source\n".append(
            to: repo.url.appendingPathComponent("original.txt"))
        try git.run(["add", "original.txt", "copied.txt"], workingDirectory: repo.url.path)

        // Verify git actually emitted a `C` record before trusting anything
        // downstream -- a copy git reports as `A` pins nothing.
        let porcelain = try git.run(["status", "--porcelain=v2"], workingDirectory: repo.url.path)
        #expect(
            porcelain.text.contains("C. N..."),
            "fixture did not provoke a copy record: \(porcelain.text)")

        // The behaviour under test: `gitStatus` must return the entry, not throw.
        let status = try gitStatus(at: repo.url.path)

        #expect(Set(status.entries.map(\.path)) == ["original.txt", "copied.txt"])

        let copy = try #require(status.entries.first(where: { $0.path == "copied.txt" }))
        #expect(copy.originalPath == "original.txt")
        #expect(copy.originalPathBytes == Array("original.txt".utf8))
        #expect(copy.staged == .modified, "a copy is reported on the staged side")
        #expect(copy.worktree == .unmodified)

        let source = try #require(status.entries.first(where: { $0.path == "original.txt" }))
        #expect(source.staged == .modified, "the copy's modified source is reported separately")
    }
}

private extension String {
    /// Appends to an existing file's contents. `String.write(to:atomically:encoding:)`
    /// always overwrites, so the fixture's "modify the source too" step needs this instead.
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(utf8))
    }
}
