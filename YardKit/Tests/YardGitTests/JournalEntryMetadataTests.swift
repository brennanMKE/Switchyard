// JournalEntryMetadataTests.swift — the metadata.json wire shape (#0155)
//
// Deliberately NOT @testable: checkpoint, restore, rebuild and the listing
// all read this shape as public callers, so a member silently dropping to
// internal must fail here at compile time (the #0116 failure class).
//
// The golden-bytes tests exist because round trips are blind to symmetric
// bugs: parse(serialize(x)) == x passes when both directions are wrong the
// same way — SE-0295's synthesized {"tree":{}} round-trips perfectly and
// still breaks the wire. The literal bytes are pinned independently.

import Foundation
import Testing
import YardGit

struct JournalEntryMetadataTests {

    private let git = GitProcess()

    /// Fixture ids and entries, hoisted into a throwing init because `try`
    /// cannot sit inside an `#expect` comparison and nested `#require` does
    /// not compile (the JournalChainTests pattern).
    private struct Fixture {
        let idA, idB: JournalEntryID
        let oidA = String(repeating: "a", count: 40)
        let oidB = String(repeating: "b", count: 40)
        /// 2026-08-07T18:22:31Z exactly.
        let wholeSecond = Date(timeIntervalSince1970: 1_786_126_951)

        init() throws {
            idA = try #require(JournalEntryID("01K1H8QZZZW7CBVX5TRJJEDDVM"),
                               "fixture id must be a valid ULID")
            idB = try #require(JournalEntryID("01K1H8R100W7CBVX5TRJJEDDVM"),
                               "fixture id must be a valid ULID")
        }

        /// A fully populated normal entry — every optional present.
        var full: JournalEntryMetadata {
            JournalEntryMetadata(
                id: idB, operation: "fixup", command: "switchyard fixup HEAD~2",
                label: "before rebasing onto main",
                timestamp: wholeSecond,
                worktree: .init(name: "agent-a", path: "/Users/b/src/proj-agent-a"),
                captured: .init(refs: true, head: true, index: .tree,
                                worktree: .stash, untracked: true),
                guardRefs: ["HEAD": oidA, "refs/heads/main": oidB],
                agent: .init(name: "claude-code", session: "01J8W"))
        }

        /// The refs-only checkpoint #0167 writes until #0171 (#0034 decision 3),
        /// from the main worktree: no command, label, agent, or traversal.
        var minimal: JournalEntryMetadata {
            JournalEntryMetadata(
                id: idB, operation: "checkpoint", timestamp: wholeSecond,
                worktree: .init(name: nil, path: "/Users/b/src/proj"),
                captured: .refsOnly)
        }

        /// A traversal entry whose redo returned the cursor to a normal entry.
        var redo: JournalEntryMetadata {
            JournalEntryMetadata(
                id: idB, operation: "redo", timestamp: wholeSecond,
                worktree: .init(name: nil, path: "/Users/b/src/proj"),
                captured: .refsOnly,
                traversal: .init(restored: idA, resultingPosition: idA))
        }
    }

    // MARK: - Golden bytes

    @Test func aFullyPopulatedEntrySerializesToThePinnedBytes() throws {
        let f = try Fixture()
        let expected = #"{"agent":{"name":"claude-code","session":"01J8W"},"captured":{"head":true,"index":"tree","refs":true,"untracked":true,"worktree":"stash"},"command":"switchyard fixup HEAD~2","guard":{"HEAD":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","refs/heads/main":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"id":"01K1H8R100W7CBVX5TRJJEDDVM","label":"before rebasing onto main","operation":"fixup","schemaVersion":1,"timestamp":"2026-08-07T18:22:31Z","worktree":{"name":"agent-a","path":"/Users/b/src/proj-agent-a"}}"#
        #expect(try f.full.serialized() == Data(expected.utf8))
    }

    /// Absent optionals are absent keys — not null — and not-captured
    /// pieces are the JSON boolean `false`, never the SE-0295 object form.
    @Test func aRefsOnlyEntrySerializesToThePinnedBytes() throws {
        let f = try Fixture()
        let expected = #"{"captured":{"head":true,"index":false,"refs":true,"untracked":false,"worktree":false},"guard":{},"id":"01K1H8R100W7CBVX5TRJJEDDVM","operation":"checkpoint","schemaVersion":1,"timestamp":"2026-08-07T18:22:31Z","worktree":{"path":"/Users/b/src/proj"}}"#
        #expect(try f.minimal.serialized() == Data(expected.utf8))
    }

    /// `resultingPosition` present when the cursor landed on an entry, and
    /// absent — not null — when a traversal returned it to present.
    @Test func traversalEntriesSerializeToThePinnedBytes() throws {
        let f = try Fixture()
        let redoExpected = #"{"captured":{"head":true,"index":false,"refs":true,"untracked":false,"worktree":false},"guard":{},"id":"01K1H8R100W7CBVX5TRJJEDDVM","operation":"redo","schemaVersion":1,"timestamp":"2026-08-07T18:22:31Z","traversal":{"restored":"01K1H8QZZZW7CBVX5TRJJEDDVM","resultingPosition":"01K1H8QZZZW7CBVX5TRJJEDDVM"},"worktree":{"path":"/Users/b/src/proj"}}"#
        #expect(try f.redo.serialized() == Data(redoExpected.utf8))

        let toPresent = JournalEntryMetadata(
            id: f.idB, operation: "switchyard undo", timestamp: f.wholeSecond,
            worktree: .init(name: nil, path: "/Users/b/src/proj"),
            captured: .refsOnly,
            traversal: .init(restored: f.idA, resultingPosition: nil))
        let undoExpected = #"{"captured":{"head":true,"index":false,"refs":true,"untracked":false,"worktree":false},"guard":{},"id":"01K1H8R100W7CBVX5TRJJEDDVM","operation":"switchyard undo","schemaVersion":1,"timestamp":"2026-08-07T18:22:31Z","traversal":{"restored":"01K1H8QZZZW7CBVX5TRJJEDDVM"},"worktree":{"path":"/Users/b/src/proj"}}"#
        #expect(try toPresent.serialized() == Data(undoExpected.utf8))
    }

    // MARK: - Round trips and determinism

    @Test func entriesRoundTripAndSerializeDeterministically() throws {
        let f = try Fixture()
        for entry in [f.full, f.minimal, f.redo] {
            #expect(try JournalEntryMetadata(serialized: entry.serialized()) == entry)
            #expect(try entry.serialized() == entry.serialized())
        }
    }

    /// Sub-second capture moments floor to the whole second at construction
    /// (the ISO 8601 wire form cannot carry them), so equality survives the
    /// round trip for every input, not only whole-second ones.
    @Test func timestampsFloorToWholeSecondsAtInit() throws {
        let f = try Fixture()
        let subSecond = JournalEntryMetadata(
            id: f.idB, operation: "checkpoint",
            timestamp: Date(timeIntervalSince1970: 1_786_126_951.75),
            worktree: .init(name: nil, path: "/p"), captured: .refsOnly)
        #expect(subSecond.timestamp == f.wholeSecond)
        #expect(try JournalEntryMetadata(serialized: subSecond.serialized()) == subSecond)
    }

    // MARK: - The chain bridge: kind is the traversal field, not the string

    /// The claim this type exists to hold (#0034 decision 7): an entry is a
    /// traversal entry exactly when `traversal` is present. `operation` is
    /// free text — an operation literally named "undo" with no traversal is
    /// a normal entry, and a traversal entry keeps its record whatever its
    /// operation is called. `JournalChain` agrees because `chainNode` hands
    /// it the field itself.
    @Test func entryKindIsDecidedByTraversalPresenceNotTheOperationString() throws {
        // Free text says "undo"; no traversal field. A normal entry:
        // the chain offers it as the undo target, exactly like a checkpoint.
        let f = try Fixture()
        let misleadinglyNamed = JournalEntryMetadata(
            id: f.idB, operation: "undo", timestamp: f.wholeSecond,
            worktree: .init(name: nil, path: "/p"), captured: .refsOnly)
        #expect(misleadinglyNamed.chainNode.traversal == nil)
        let asNormal = try JournalChain.state(of: [misleadinglyNamed.chainNode])
        #expect(asNormal.cursor == nil)
        #expect(asNormal.undoTarget == f.idB)

        // Free text does not mention undo or redo; the traversal field is
        // present. A traversal entry: the chain replays the cursor from it.
        let freeText = JournalEntryMetadata(
            id: f.idB, operation: "step back to yesterday", timestamp: f.wholeSecond,
            worktree: .init(name: nil, path: "/p"), captured: .refsOnly,
            traversal: .init(restored: f.idA, resultingPosition: f.idA))
        let normalBelow = JournalChain.Node(id: f.idA)
        let asTraversal = try JournalChain.state(
            of: [normalBelow, freeText.chainNode])
        #expect(asTraversal.cursor == f.idA)
        #expect(asTraversal.redoTarget == .present(capturedBy: f.idB))
    }

    // MARK: - Rejection

    /// The error `init(serialized:)` throws for `data`, hoisted so tests
    /// can compare cases without nesting `#require`.
    private func decodeError(
        of data: Data
    ) throws -> JournalEntryMetadata.SerializationError {
        try #require(throws: JournalEntryMetadata.SerializationError.self) {
            _ = try JournalEntryMetadata(serialized: data)
        }
    }

    private func isUndecodable(
        _ error: JournalEntryMetadata.SerializationError
    ) -> Bool {
        if case .undecodable = error { return true }
        return false
    }

    @Test func rejectsBytesThatAreNotThisSchema() throws {
        #expect(try isUndecodable(decodeError(of: Data("not json".utf8))))
        #expect(try isUndecodable(decodeError(of: Data("{}".utf8))))
        // Valid JSON with the version but missing everything else.
        #expect(try isUndecodable(decodeError(of: Data(#"{"schemaVersion":1}"#.utf8))))
    }

    @Test func rejectsAnUnsupportedSchemaVersion() throws {
        let f = try Fixture()
        let bytes = try #require(
            String(data: f.minimal.serialized(), encoding: .utf8))
            .replacingOccurrences(
                of: #""schemaVersion":1"#, with: #""schemaVersion":2"#)
        #expect(try decodeError(of: Data(bytes.utf8)) == .unsupportedSchemaVersion(2))
    }

    /// Field-level validation: a malformed id and the wire values the
    /// capture enums do not define all fail typed, never default.
    @Test func rejectsInvalidIdsAndUnknownCaptureValues() throws {
        let f = try Fixture()
        let good = try #require(String(data: f.minimal.serialized(), encoding: .utf8))
        let bads = [
            (#""id":"01K1H8R100W7CBVX5TRJJEDDVM""#, #""id":"not-an-id""#),
            (#""index":false"#, #""index":true"#),
            (#""index":false"#, #""index":"blob""#),
            (#""worktree":false"#, #""worktree":true"#),
            (#""worktree":false"#, #""worktree":"tarball""#),
        ]
        for (from, to) in bads {
            let mangled = good.replacingOccurrences(of: from, with: to)
            #expect(mangled != good, "substitution failed: \(to)")
            #expect(try isUndecodable(decodeError(of: Data(mangled.utf8))), "input: \(to)")
        }
    }

    // MARK: - Through a real anchored commit

    /// The #0030 recovery path end to end: serialized metadata rides an
    /// anchored snapshot commit, comes back verbatim through both readers,
    /// and decodes to the original — while a foreign blob in a second
    /// anchor is recovered verbatim by rebuild (whose contract stops at
    /// bytes) and fails HERE, typed, at decode time.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func metadataRoundTripsThroughARealAnchoredCommit(
        format: FixtureRepository.RefFormat
    ) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let f = try Fixture()
        let entry = f.minimal
        try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: entry.serialized()),
            id: entry.id, in: context)
        let garbage = Data("not this schema".utf8)
        try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: garbage), id: f.idA, in: context)

        // The direct read decodes to the original.
        let bytes = try JournalAnchor.metadata(for: entry.id, in: context)
        #expect(try JournalEntryMetadata(serialized: bytes) == entry)

        // Rebuild recovers BOTH entries verbatim and reports no defect —
        // undecodable metadata is not a rebuild defect (#0030's contract).
        let rebuilt = try JournalRebuild.rebuild(in: context)
        #expect(rebuilt.defects.isEmpty)
        #expect(rebuilt.entries.map(\.id) == [f.idA, entry.id])
        let recovered = try #require(
            rebuilt.entries.first { $0.id == entry.id }?.metadataJSON)
        #expect(try JournalEntryMetadata(serialized: recovered) == entry)

        // Decoding the foreign blob is this layer's typed error.
        let foreign = try #require(
            rebuilt.entries.first { $0.id == f.idA }?.metadataJSON)
        #expect(foreign == garbage)
        #expect(try isUndecodable(decodeError(of: foreign)))
    }
}
