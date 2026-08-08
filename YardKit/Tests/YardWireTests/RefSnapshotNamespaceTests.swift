// RefSnapshotNamespaceTests.swift — the journal anchor prefix lives inside the
// namespace snapshots exclude (#0027).
//
// The two constants live on opposite sides of a boundary neither target may
// import across: `ServiceNames.journalRefPrefix` (YardKit) is where anchor
// refs are written, and `RefSnapshot.switchyardNamespace` (YardGit) is what
// capture skips and restore refuses to delete. If the anchor prefix ever
// left the excluded namespace, a snapshot would capture journal anchors and
// a restore would delete the anchor keeping itself reachable. This is the one
// test target that sees both sides, so the relationship is pinned here.

import Testing
import YardGit
import YardKit

@Suite("Journal ref namespace")
struct RefSnapshotNamespaceTests {

    @Test func journalAnchorPrefixIsInsideTheSnapshotExcludedNamespace() {
        #expect(ServiceNames.journalRefPrefix.hasPrefix(RefSnapshot.switchyardNamespace))
        #expect(RefSnapshot.switchyardNamespace.hasPrefix("refs/"))
        #expect(RefSnapshot.switchyardNamespace.hasSuffix("/"))
    }
}
