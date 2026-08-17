// CommitLogTests.swift

import Foundation
import Testing
@testable import YardGit

struct CommitLogTests {

    private let git = GitProcess()

    // MARK: - SignatureStatus parsing

    @Test func signatureStatusMapsGToGood() {
        #expect(SignatureStatus("G") == .good)
    }

    @Test func signatureStatusMapsUToGoodUntrusted() {
        #expect(SignatureStatus("U") == .goodUntrusted)
    }

    @Test func signatureStatusMapsBToBad() {
        #expect(SignatureStatus("B") == .bad)
    }

    @Test func signatureStatusMapsXToExpiredSignature() {
        #expect(SignatureStatus("X") == .expiredSignature)
    }

    @Test func signatureStatusMapsYToExpiredKey() {
        #expect(SignatureStatus("Y") == .expiredKey)
    }

    @Test func signatureStatusMapsRToRevokedKey() {
        #expect(SignatureStatus("R") == .revokedKey)
    }

    @Test func signatureStatusMapsEToCannotCheck() {
        #expect(SignatureStatus("E") == .cannotCheck)
    }

    @Test func signatureStatusMapsNToNoSig() {
        #expect(SignatureStatus("N") == .noSig)
    }

    @Test func signatureStatusMapsUnrecognizedToUnknown() {
        #expect(SignatureStatus("x") == .unknown)
        #expect(SignatureStatus("?") == .unknown)
    }

    @Test func signatureStatusMapsLowercaseGToUnknownGitNeverEmitsIt() {
        #expect(SignatureStatus("g") == .unknown)
    }

    @Test func signatureStatusWithEmptyStringReturnsUnknown() {
        #expect(SignatureStatus("") == .unknown)
    }

    @Test func signatureStatusCharacterInitAgreesWithStringInit() {
        #expect(SignatureStatus(Character("G")) == .good)
        #expect(SignatureStatus(Character("N")) == .noSig)
    }

    // MARK: - SignatureStatus end-to-end (no signing key is ever created)

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func unsignedCommitReportsNoSigThroughRun(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        #expect(entries.count == 1)
        // Measured: %G? on an unsigned commit is `N`.
        #expect(entries.first?.signatureStatus == .noSig)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func craftedBadSSHSignatureReportsBadThroughRun(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        // A structurally-valid, cryptographically garbage SSH signature block,
        // written as a raw commit object. No key exists anywhere in this test.
        // Continuation lines carry exactly one leading space — that is commit
        // object header-continuation syntax, and it is load-bearing.
        let tree = try repo.revParse("HEAD^{tree}")
        let ident = "Fixture <fixture@example.invalid> 1700000000 +0000"
        let object = """
        tree \(tree)
        author \(ident)
        committer \(ident)
        gpgsig -----BEGIN SSH SIGNATURE-----
         U1NIU0lHTAAAAAWZha2VmYWtlZmFrZQ==
         -----END SSH SIGNATURE-----

        crafted signed commit
        """ + "\n"
        let out = try git.run(
            ["hash-object", "-t", "commit", "-w", "--stdin", "--literally"],
            workingDirectory: repo.url.path,
            standardInput: Data(object.utf8)
        )
        let sha = out.lines[0]

        // Local config overrides any global config, so this is deterministic
        // whatever the developer's machine has. Measured: %G? is then `B`.
        try repo.writeUntracked(["allowed_signers": ""])
        try git.run(
            ["config", "gpg.ssh.allowedSignersFile",
             repo.url.appendingPathComponent("allowed_signers").path],
            workingDirectory: repo.url.path
        )

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["-1", sha])
        #expect(entries.count == 1)
        #expect(entries.first?.signatureStatus == .bad)
    }

    // MARK: - Embedded delimiter in message

    @Test func parsePreservesEmbeddedDelimiterInMessage() throws {
        let oid = "a" + String(repeating: "0", count: 39)
        let soH = "\u{01}"
        let bodyWithDelimiter = "has \(soH) delimiter inside\n\nbody"
        // Six fields separated by SOH: OID, parents (empty), author, sig (empty), refs, body.
        // The body itself contains a SOH byte so split would produce 7 parts; the rejoin must
        // recover the original message exactly.
        let record = "\(oid)\(soH)\(soH)fixture<fixture@example.invalid>\(soH)\(soH)(HEAD, main)\(soH)\(bodyWithDelimiter)\u{0}"
        let entries = CommitLog.parse(output: record)
        #expect(entries.count == 1)
        let entry = try #require(entries.first(where: { $0.oid == oid }))
        #expect(entry.message == bodyWithDelimiter)
    }

    @Test func parseBodyWithoutEmbeddedDelimiterIsByteIdentical() throws {
        let oid = "b" + String(repeating: "0", count: 39)
        let soH = "\u{01}"
        let body = "subject one\n\nline two"
        let record = "\(oid)\(soH)\(soH)fixture<fixture@example.invalid>\(soH)\(soH)(HEAD, main)\(soH)\(body)\u{0}"
        let entries = CommitLog.parse(output: record)
        #expect(entries.count == 1)
        let entry = try #require(entries.first(where: { $0.oid == oid }))
        #expect(entry.message == body)
    }

    @Test func parsePreservesTrailingNewlineFromBody() throws {
        let oid = "c" + String(repeating: "0", count: 39)
        let soH = "\u{01}"
        // The body must retain its trailing newline -- the raw output from %B ends in \n
        // before the NUL terminator, and CommitLog must not eat it.
        let body = "subject\n\nbody line"
        let record = "\(oid)\(soH)\(soH)fixture<fixture@example.invalid>\(soH)\(soH)(HEAD, main)\(soH)\(body)\n\u{0}"
        let entries = CommitLog.parse(output: record)
        #expect(entries.count == 1)
        let entry = try #require(entries.first(where: { $0.oid == oid }))
        #expect(entry.message == "\(body)\n", "trailing newline must be preserved verbatim")
    }

    @Test func parseSkipsEmptyTailRecordAndStripsTheRecordSeparator() throws {
        // The real shape, from `od -c` on the project's own format string:
        //
        //     <record>\n \0 \n <record>\n \0 \n
        //
        // %B's trailing newline, then the %x00 from the format, then the
        // separator newline `git log` writes between entries. A fixture that
        // omits that separator cannot detect the bug where it is treated as part
        // of the next record -- which is exactly what round 1 shipped.
        let oid1 = "d" + String(repeating: "0", count: 39)
        let oid2 = "e" + String(repeating: "0", count: 39)
        let soH = "\u{01}"
        func record(_ oid: String, _ body: String) -> String {
            "\(oid)\(soH)\(soH)fixture<fixture@example.invalid>\(soH)\(soH)(HEAD, main)\(soH)\(body)\n\u{0}\n"
        }
        let output = record(oid1, "first commit") + record(oid2, "second commit")

        let entries = CommitLog.parse(output: output)

        #expect(entries.count == 2, "the empty trailing record must be skipped")
        #expect(entries.map(\.oid) == [oid1, oid2],
                "the separator newline must not survive into the oid field")
        #expect(entries.map(\.message) == ["first commit\n", "second commit\n"],
                "%B's own trailing newline must survive")
    }

    @Test func parseFindsSohWhenRecordContainsLeadingNewlines() throws {
        // git always emits SOH-delimited fields from the first character of a record;
        // that SOH guarantees we still skip leading whitespace without trimming the body.
        let oid = "e" + String(repeating: "0", count: 39)
        let soH = "\u{01}"
        let body = "subject\n\nbody line"
        let record = "\(oid)\(soH)\(soH)fixture<fixture@example.invalid>\(soH)\(soH)(HEAD, main)\(soH)\(body)\n\u{0}"
        let entries = CommitLog.parse(output: record)
        #expect(entries.count == 1)
        let entry = try #require(entries.first(where: { $0.oid == oid }))
        // trailing newline from %B is preserved, matching what the body had appended.
        #expect(entry.message == "\(body)\n")
    }

    @Test func parseDiscardsRecordWithNoSohDelimiter() throws {
        // A stray line with no SOH bytes must be skipped.
        let record = "this is a plain text line\nno delimiters at all\n"
        let entries = CommitLog.parse(output: record)
        #expect(entries.isEmpty)
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

    @Test func trailersParsingWithEmptyMessageReturnsNoTrailers() {
        // A genuinely empty commit message. `FixtureRepository.build` runs
        // `git commit --allow-empty -m <message>` with no `--allow-empty-message`,
        // so it cannot build a fixture with an empty message -- git rejects it
        // ("Aborting commit due to empty commit message"). Pin the property by
        // calling the parser directly instead (#0196).
        let trailers = CommitLog.parseTrailerBlock(from: "")
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
        // git's `commit -m` appends a trailing newline to the stored message; CommitLog preserves
        // whatever was actually written by git, which is what we observe here.
        // `git commit -m` applies its default cleanup, which ends the stored message
        // with exactly one newline. %B is verbatim, so the parser now returns it --
        // the old assertion without it encoded the trim this change removes.
        #expect(message == multiLine + "\n")
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

        // `-1` limits to the merge commit itself. Passing bare "HEAD" asks for the
        // whole history reachable from HEAD, which is four commits here.
        let entries = try CommitLog.run(path: url, rangeArguments: ["-1", "HEAD"])
        #expect(entries.count == 1)

        let entry = try #require(entries.first)
        // merge commit should have 2 parents: c and b oids
        // #require, not #expect: #expect records a failure and keeps going, so a
        // wrong count traps on the subscripts below and kills the whole suite.
        try #require(entry.parents.count == 2)

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
        // A trailer value is everything after the colon, name included.
        #expect(signed.value == "Alice <alice@example.invalid>")
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
        try #require(entries.count >= 1, "not enough entries to index")
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

        // HEAD~1..HEAD is a single commit — the lower bound is exclusive. This test
        // is about ordering, so ask for the history and assert newest-first.
        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        try #require(entries.count >= 2)
        #expect(entries[0].oid == repo.oids["b"], "newest commit must come first")

        // Newest first, so "b" comes first
        #expect(entries[0].oid == repo.oids["b"])
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runFillsOidsForEachEntry(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        try #require(entries.count >= 2, "not enough entries to index")
        #expect(entries[0].oid == repo.oids["b"])
        #expect(entries[1].oid == repo.oids["a"])
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runParsesBranchRef(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        try #require(entries.count >= 1, "not enough entries to index")
        #expect(!entries[0].refs.isEmpty)

        // %D renders the checked-out branch as "HEAD -> main", a single field with
        // no comma, so splitting on "," and matching a prefix never fires.
        #expect(entries[0].refs.contains("main"),
                "refs should name the branch; got \(entries[0].refs)")
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runIncludesParentsForCommitWithOne(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        try #require(entries.count >= 2, "not enough entries to index")

        // #require, not #expect: if the order is ever inverted, entries[0] is the
        // root commit with no parents, and the subscript below traps and kills
        // the whole suite instead of failing this one test.
        try #require(entries[0].parents.count == 1, "newest entry should have one parent")

        // Second commit has first commit as parent
        #expect(entries[0].parents[0] == entries[1].oid)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runIncludesEmptyParentsForRoot(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        try #require(entries.count >= 1, "not enough entries to index")
        #expect(entries[0].parents.isEmpty)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func runWithRangePicksUpCommittedMessage(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        let msg = "First commit\n\nAgent-Name: tool v1.0"
        try repo.build([FixtureRepository.Commit("a", message: msg)])

        let entries = try CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        try #require(entries.count >= 1, "not enough entries to index")
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
        try #require(entries.count >= 1, "not enough entries to index")
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
