// RefSnapshotSerializationTests.swift — the refs blob format (#0165)
//
// Deliberately NOT @testable: restore and rebuild read this format as public
// callers, so a member silently dropping to internal must fail here at
// compile time (the #0116 failure class).

import Foundation
import Testing
import YardGit

struct RefSnapshotSerializationTests {

    private let oidA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let oidB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    // MARK: - Golden bytes

    /// The format is wire contract for #0030's refs-only recovery, so the
    /// exact bytes are pinned, not just the round trip: a reordered field or
    /// a renamed keyword must fail here even if it round-trips.
    @Test func symbolicHeadSerializesToThePinnedBytes() throws {
        let snapshot = RefSnapshot(
            head: .symbolic(target: "refs/heads/main"),
            refs: [
                RefSnapshot.Entry(name: "refs/heads/main", oid: oidA),
                RefSnapshot.Entry(name: "refs/tags/v1", oid: oidB),
            ])
        let expected = """
        switchyard-refs 1
        head symbolic refs/heads/main
        \(oidA) refs/heads/main
        \(oidB) refs/tags/v1

        """
        #expect(snapshot.serialized() == Data(expected.utf8))
    }

    @Test func detachedHeadSerializesToThePinnedBytes() throws {
        let snapshot = RefSnapshot(head: .detached(oid: oidA), refs: [])
        #expect(snapshot.serialized()
            == Data("switchyard-refs 1\nhead detached \(oidA)\n".utf8))
    }

    // MARK: - Round trips

    @Test func symbolicSnapshotRoundTrips() throws {
        let snapshot = RefSnapshot(
            head: .symbolic(target: "refs/heads/feature/x"),
            refs: [
                RefSnapshot.Entry(name: "refs/heads/feature/x", oid: oidA),
                RefSnapshot.Entry(name: "refs/remotes/origin/main", oid: oidB),
            ])
        #expect(try RefSnapshot(serialized: snapshot.serialized()) == snapshot)
    }

    @Test func detachedEmptySnapshotRoundTrips() throws {
        let snapshot = RefSnapshot(head: .detached(oid: oidB), refs: [])
        #expect(try RefSnapshot(serialized: snapshot.serialized()) == snapshot)
    }

    /// A real capture round-trips, in both ref formats: what `for-each-ref`
    /// actually produces — annotated tags, multiple namespaces — survives the
    /// bytes unchanged.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func realCaptureRoundTrips(format: FixtureRepository.RefFormat) throws {
        let git = GitProcess()
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        try git.run(["tag", "-a", "-m", "annotated", "v1"],
                    workingDirectory: repo.url.path)
        try git.run(["update-ref", "refs/heads/side", try repo.revParse("HEAD")],
                    workingDirectory: repo.url.path)
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let captured = try RefSnapshot.capture(in: context)
        let reparsed = try RefSnapshot(serialized: captured.serialized())

        #expect(!captured.refs.isEmpty)
        #expect(reparsed == captured)
    }

    // MARK: - Rejection

    /// The error `init(serialized:)` throws for `data`, hoisted so tests can
    /// compare cases without nesting `#require` (which does not compile).
    private func parseError(
        of data: Data
    ) throws -> RefSnapshot.SerializationError {
        try #require(throws: RefSnapshot.SerializationError.self) {
            _ = try RefSnapshot(serialized: data)
        }
    }

    @Test func rejectsBytesThatAreNotUTF8() throws {
        #expect(try parseError(of: Data([0xFF, 0xFE, 0x0A])) == .notUTF8)
    }

    @Test func rejectsEmptyAndUnterminatedData() throws {
        #expect(try parseError(of: Data()) == .truncated)
        // A blob cut off mid-write has no final newline.
        let cut = Data("switchyard-refs 1\nhead detached \(oidA)".utf8)
        #expect(try parseError(of: cut) == .truncated)
    }

    @Test func rejectsAForeignOrFutureHeader() throws {
        let future = Data("switchyard-refs 2\nhead detached \(oidA)\n".utf8)
        #expect(try parseError(of: future) == .unsupportedHeader("switchyard-refs 2"))
        #expect(try parseError(of: Data("{}\n".utf8)) == .unsupportedHeader("{}"))
    }

    @Test func rejectsAMalformedHeadLine() throws {
        let bads = [
            "switchyard-refs 1\n",                          // no head line at all
            "switchyard-refs 1\nhead symbolic\n",           // no target
            "switchyard-refs 1\nhead attached \(oidA)\n",   // unknown keyword
            "switchyard-refs 1\n\(oidA) refs/heads/main\n", // ref line where head belongs
        ]
        for bad in bads {
            let error = try parseError(of: Data(bad.utf8))
            guard case .malformedHead = error else {
                Issue.record("expected .malformedHead for \(bad), got \(error)")
                continue
            }
        }
    }

    @Test func rejectsAMalformedRefLine() throws {
        let prefix = "switchyard-refs 1\nhead detached \(oidA)\n"
        let bads = ["\(oidB)\n", "\(oidB) refs/heads/x extra\n", "\n", " refs/heads/x\n"]
        for bad in bads {
            let error = try parseError(of: Data((prefix + bad).utf8))
            #expect(error == .malformedRef(String(bad.dropLast())), "input: \(bad)")
        }
    }
}
