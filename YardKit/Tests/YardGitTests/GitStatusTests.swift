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
}
