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
}
