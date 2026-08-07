// CommitLogTests.swift

import Foundation
import Testing
@testable import YardGit

struct CommitLogTests {

    private let git = GitProcess()

    // MARK: - SignatureStatus parsing

    @Test func signatureStatusMapsGLowerToValid() {
        #expect(SignatureStatus("g") == .valid)
    }

    @Test func signatureStatusMapsGCapitalToInvalid() {
        #expect(SignatureStatus("G") == .invalid)
    }

    @Test func signatureStatusMapsOtherToNoSig() {
        #expect(SignatureStatus("x") == .noSig)
    }

    @Test func signatureStatusWithEmptyStringReturnsNoSig() {
        #expect(SignatureStatus("") == .noSig)
    }

    // MARK: - Trailer parsing

    @Test func trailerParsesAgentName() throws {
        let t = try #require(Trailer.parse("Agent-Name: tool v1.0"))
        #expect(t.key == "Agent-Name")
        #expect(t.value == "tool v1.0")
    }

    @Test func trailerParsesSignedOffBy() throws {
        let t = try #require(Trailer.parse("Signed-off-by: <alice@example.invalid>"))
        #expect(t.key == "Signed-off-by")
        #expect(t.value == "<alice@example.invalid>")
    }

    @Test func trailerParsesReviewedBy() throws {
        let t = try #require(Trailer.parse("Reviewed-by: Bob <bob@example.invalid>"))
        #expect(t.key == "Reviewed-by")
    }

    @Test func trailerRejectsCommentLine() throws {
        let t = Trailer.parse("# This is a comment")
        #expect(t == nil)
    }

    @Test func trailerRejectsIndentedBodyContinuation() throws {
        let t = Trailer.parse("\tcontinued body paragraph")
        #expect(t == nil)
    }

    // MARK: - CommitLogEntry helpers

    @Test func shortOidReturnsTwelveChars() {
        let long = String(repeating: "a", count: 40)
        #expect(CommitLogEntry.shortOid(long).count == 12)
    }

    @Test func shortOidReturnsUnknownForEmptyString() {
        #expect(CommitLogEntry.shortOid("") == "<unknown>")
    }

    @Test func hasProvenanceDetectsAgentName() {
        let trailers = [Trailer(key: "Agent-Name", value: "tool v1.0")]
        #expect(CommitLogEntry.hasAgentName(trailers: trailers))
    }

    @Test func hasProvenanceReturnsFalseForNoTrailer() {
        let trailers = [Trailer(key: "Other", value: "x")]
        #expect(!CommitLogEntry.hasAgentName(trailers: trailers))
    }

    @Test func shortOidPropertyReturnsTruncatedOid() {
        let long = String(repeating: "b", count: 40)
        let entry = CommitLogEntry(oid: long, parents: [], author: "Alice", refs: "", signatureStatus: .noSig, message: "hi", trailers: [])
        #expect(entry.shortOid.count == 12)
    }

    // MARK: - Subject from message

    @Test func subjectReturnsFirstLineOfMessage() {
        let long = String(repeating: "a", count: 40)
        let entry = CommitLogEntry(oid: long, parents: [], author: "Alice", refs: "", signatureStatus: .noSig, message: "First line\nsecond line", trailers: [])
        #expect(entry.subject == "First line")
    }

    @Test func subjectFallsBackToPlaceholderWhenMessageIsEmpty() {
        let entry = CommitLogEntry(oid: "abcdef123456", parents: [], author: "Alice", refs: "", signatureStatus: .noSig, message: "", trailers: [])
        #expect(entry.subject == "(commit abcdef123456)")
    }

    // MARK: - TrailerBlock parsing in commit body

    @Test func trailersParsingWithAgentName() {
        let body = """
            First commit.

            Agent-Name: CI v1.0
        """
        let trailers = CommitLog.parseTrailerBlock(from: body)
        #expect(trailers.count == 1)
        #expect(trailers[0].key == "Agent-Name")
    }

    @Test func trailersParsingNoTrailers() {
        let body = """
            Just a commit with no trailers.
        """
        let trailers = CommitLog.parseTrailerBlock(from: body)
        #expect(trailers.isEmpty)
    }

    @Test func trailersParsingMultipleTrailers() {
        let body = """
            Body text.

            Agent-Name: CI v1.0
            Signed-off-by: Alice <alice@example.invalid>
        """
        let trailers = CommitLog.parseTrailerBlock(from: body)
        #expect(trailers.count == 2)
    }

    // MARK: - CommitLog.run — end-to-end with multi-line, merge, non-ASCII, trailers

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func multiLineMessagePreservesNewlines(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        let multiLine = "First paragraph\n\nSecond paragraph\n\nThird line"
        try repo.build([FixtureRepository.Commit("a", message: multiLine)])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        #expect(entries.count == 1)

        let message = try #require(entries.first?.message)
        #expect(message == multiLine)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func messageWithBlankLinePreservesBlank(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        let msg = "Heading\n\nBody paragraph."
        try repo.build([FixtureRepository.Commit("a", message: msg)])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        let message = try #require(entries.first?.message)
        // Two newlines in between — blank line is preserved verbatim.
        #expect(message.contains("\n\n"))
        #expect(message.hasPrefix("Heading\n"))
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func mergeCommitHasTwoParentsDirect(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        let url = repo.url.path

        // Initial commit on main: A
        try repo.build([FixtureRepository.Commit("a", message: "initial")])

        // Switch to feature branch and make commit B
        _ = try? git.run(["-C", url, "checkout", "-b", "feature"], workingDirectory: "/")
        _ = try repo.build([FixtureRepository.Commit("b", message: "feature work")])

        // Switch back to main and make commit C (so we have A -> B on feature, A -> C on main)
        _ = try? git.run(["-C", url, "checkout", "main"], workingDirectory: "/")
        _ = try repo.build([FixtureRepository.Commit("c", message: "main work")])

        // Merge feature into main (now HEAD has two parents: C and B)
        _ = try? git.run(["-C", url, "merge", "feature", "--no-edit"], workingDirectory: "/")

        let entries = try CommitLog.run(path: url, rangeArguments: ["HEAD"])
        #expect(entries.count == 1)

        let entry = try #require(entries.first)
        // merge commit should have 2 parents: c and b oids
        #expect(entry.parents.count == 2)

        // Both parents should be among the oids we know
        #expect([entry.parents[0], entry.parents[1]].contains(repo.oids["c"]))
        #expect([entry.parents[0], entry.parents[1]].contains(repo.oids["b"]))
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func trailersAgentNameAndSignedOffByParse(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        let msg = "Work done\n\nAgent-Name: my-agent v2.0\nSigned-off-by: Alice <alice@example.invalid>"
        try repo.build([FixtureRepository.Commit("a", message: msg)])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        let trailers = try #require(entries.first?.trailers)

        // Both should be present.
        let keys = Set(trailers.map(\.key))
        #expect(keys.contains("Agent-Name"))
        #expect(keys.contains("Signed-off-by"))

        let agent = try #require(trailers.first(where: { $0.key == "Agent-Name" }))
        #expect(agent.value == "my-agent v2.0")

        let signed = try #require(trailers.first(where: { $0.key == "Signed-off-by" }))
        #expect(signed.value == "<alice@example.invalid>")
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func fourCommitsReturnsFourEntries(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        let msgs = ["first", "second\n\nAgent-Name: x", "third commit", "fourth"]
        try repo.build([
            FixtureRepository.Commit("a", message: msgs[0]),
            FixtureRepository.Commit("b", message: msgs[1]),
            FixtureRepository.Commit("c", message: msgs[2]),
            FixtureRepository.Commit("d", message: msgs[3])
        ])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        #expect(entries.count == 4)

        // Newest first, so d is first.
        #expect(entries[0].oid == repo.oids["d"])
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runReturnsOneEntryForSingleCommit(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        #expect(entries.count == 1)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runReturnsEntriesInReverseCommitOrder(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD~1..HEAD"])
        #expect(entries.count == 2)

        // Newest first, so "b" comes first
        #expect(entries[0].oid == repo.oids["b"])
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runFillsOidsForEachEntry(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        #expect(entries[0].oid == repo.oids["b"])
        #expect(entries[1].oid == repo.oids["a"])
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runParsesBranchRef(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        #expect(!entries[0].refs.isEmpty)

        let name = entries[0].refs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(name.contains(where: { $0.hasPrefix("main") || $0 == "HEAD" }))
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runIncludesParentsForCommitWithOne(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        #expect(entries[0].parents.count == 1)

        // Second commit has first commit as parent
        #expect(entries[0].parents[0] == entries[1].oid)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runIncludesEmptyParentsForRoot(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        #expect(entries[0].parents.isEmpty)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runWithRangePicksUpCommittedMessage(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        let msg = "First commit\n\nAgent-Name: tool v1.0"
        try repo.build([FixtureRepository.Commit("a", message: msg)])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        #expect(entries[0].trailers.count == 1)
        #expect(entries[0].trailers.first?.key == "Agent-Name")
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runAgentOnlyReturnsFilteredEntries(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        let messages = [
            "First commit",             // no Agent-Name
            "Second\n\nAgent-Name: tool v1.0",   // has Agent-Name
            "Third commit"              // no Agent-Name
        ]
        try repo.build([
            FixtureRepository.Commit("a", message: messages[0]),
            FixtureRepository.Commit("b", message: messages[1]),
            FixtureRepository.Commit("c", message: messages[2])
        ])

        // Without filter, we get all 3
        let all = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        #expect(all.count == 3)

        // With agentOnly, only the second commit
        let filtered = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"],
                                          options: .agentOnly)
        #expect(filtered.count == 1)

        let expected = repo.oids["b"]
        #expect(filtered.first?.oid == expected)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runIncludesRefsWhenRequested(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        #expect(!entries[0].refs.isEmpty)

        let decorated = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        #expect(decorated[0].refs.contains("main") || decorated[0].refs.contains("HEAD"))
    }

    // MARK: - hasProvenance shortcut

    @Test func hasProvenanceReturnsFalseWhenEmptyTrailers() {
        let entry = CommitLogEntry(oid: "a", parents: [], author: "", refs: "", signatureStatus: .noSig, message: "x", trailers: [])
        #expect(!entry.hasProvenance)
    }

    @Test func hasProvenanceReturnsTrueWhenAgentNamePresent() {
        let entry = CommitLogEntry(oid: "a", parents: [], author: "", refs: "",
                                   signatureStatus: .noSig, message: "x", trailers: [Trailer(key: "Agent-Name", value: "tool")])
        #expect(entry.hasProvenance)
    }

}
