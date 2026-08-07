// CommitLogTests.swift

import Foundation
import Testing
@testable import YardGit

struct CommitLogTests {

    private let git = GitProcess()

    // MARK: - SignatureStatus parsing

    @Test func signatureStatusMapsGToValid() {
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

    @Test func trailerParsesAgentName() {
        let t = Trailer.parse("Agent-Name: tool v1.0") ?? nil
        #expect(t != nil)
        #expect((t?.key == "Agent-Name") ?? false)
        #expect((t?.value == "tool v1.0") ?? false)
    }

    @Test func trailerParsesSignedOffBy() {
        let t = Trailer.parse("Signed-off-by: <alice@example.invalid>") ?? nil
        #expect(t != nil)
        #expect((t?.key == "Signed-off-by") ?? false)
    }




    @Test func trailerRejectsCommentLine() throws {
        let t = Trailer.parse("# This is a comment")
        #expect(t == nil)
    }

    @Test func trailerRejectsIndentedBodyContinuation() throws {
        let t = Trailer.parse("\tcontinued body paragraph")
        #expect(t == nil)
    }

    @Test func trailerRejectsLongKey() throws {
        let t1 = Trailer.parse("A: Val")
        #expect(t1 != nil)

        let t2 = Trailer.parse("ABCDE: Val") // too long
        #expect(t2 == nil)
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
        let entry = CommitLogEntry(oid: long, parents: [], refs: "", signatureStatus: .noSig, trailers: [])
        #expect(entry.shortOid.count == 12)
    }

    // MARK: - TrailerBlock parsing in commit body

    @Test func trailersParsingWithSubjectHeader() {
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

    // MARK: - CommitLog.run — end-to-end

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runReturnsOneEntryForSingleCommit(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let entries = try CommitLog.run(repo: repo.url.path, rangeArguments: ["HEAD"])
        #expect(entries.count == 1)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runReturnsEntriesInReverseCommitOrder(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])

        // Use HEAD~1..HEAD to get last 2 commits (if any)
        let entries = try CommitLog.run(repo: repo.url.path, rangeArguments: ["HEAD~1..HEAD"])
        #expect(entries.count == 2)

        // Newest first, so "b" comes first
        #expect(entries[0].oid == repo.oids["b"])
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runFillsOidsForEachEntry(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])

        let entries = try CommitLog.run(repo: repo.url.path, rangeArguments: ["HEAD"])
        #expect(entries[0].oid == repo.oids["b"])
        #expect(entries[1].oid == repo.oids["a"])
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runParsesBranchRef(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])

        let entries = try CommitLog.run(repo: repo.url.path, rangeArguments: ["HEAD"])
        #expect(!entries[0].refs.isEmpty)

        let name = entries[0].refs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(name.contains(where: { $0.hasPrefix("main") || $0 == "HEAD" }))
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runIncludesParentsForCommitWithOne(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])

        let entries = try CommitLog.run(repo: repo.url.path, rangeArguments: ["HEAD"])
        #expect(entries[0].parents.count == 1)

        // Second commit has first commit as parent
        #expect(entries[0].parents[0] == entries[1].oid)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runIncludesEmptyParentsForRoot(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let entries = try CommitLog.run(repo: repo.url.path, rangeArguments: ["HEAD"])
        #expect(entries[0].parents.isEmpty)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runWithRangePicksUpCommittedMessage(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        let msg = "First commit\n\nAgent-Name: tool v1.0"
        try repo.build([FixtureRepository.Commit("a", message: msg)])

        let entries = try CommitLog.run(repo: repo.url.path, rangeArguments: ["HEAD"])
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
        let all = try CommitLog.run(repo: repo.url.path, rangeArguments: ["HEAD"])
        #expect(all.count == 3)

        // With agentOnly, only the second commit
        let filtered = try CommitLog.run(repo: repo.url.path, rangeArguments: ["HEAD"],
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

        let entries = try CommitLog.run(repo: repo.url.path, rangeArguments: ["HEAD"])
        #expect(!entries[0].refs.isEmpty)

        // When asking for refs explicitly we should see the main branch
        let decorated = try CommitLog.run(repo: repo.url.path, rangeArguments: ["HEAD"])
        #expect(decorated[0].refs.contains("main") || decorated[0].refs.contains("HEAD"))
    }

    // MARK: - Subject fallback to short OID

    @Test func subjectWithEmptyTrailersReturnsPlaceholder() {
        let entry = CommitLogEntry(oid: "abcdef123456", parents: [], refs: "", signatureStatus: .noSig, trailers: [])
        #expect(entry.subject.hasPrefix("(commit abcdef"))
    }

    @Test func subjectReturnsAgentNameValue() {
        let entry = CommitLogEntry(oid: "abcdef123456", parents: [], refs: "",
                                   signatureStatus: .noSig, trailers: [Trailer(key: "Agent-Name", value: "tool v1.0")])
        #expect(entry.subject == "tool v1.0")
    }

    // MARK: - hasProvenance shortcut

    @Test func hasProvenanceReturnsFalseWhenEmptyTrailers() {
        let entry = CommitLogEntry(oid: "a", parents: [], refs: "", signatureStatus: .noSig, trailers: [])
        #expect(!entry.hasProvenance)
    }

    @Test func hasProvenanceReturnsTrueWhenAgentNamePresent() {
        let entry = CommitLogEntry(oid: "a", parents: [], refs: "", signatureStatus: .noSig,
                                   trailers: [Trailer(key: "Agent-Name", value: "tool")])
        #expect(entry.hasProvenance)
    }

}

// MARK: - Internal parse testing for coverage

extension CommitLog {
    struct InternalTests {

        

        @Test func parseEmptyOutputReturnsNoEntries() {
            let out = CommitLog.parse(output: "")
            #expect(out.isEmpty)
        }




    }
}
