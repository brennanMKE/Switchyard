// JournalAnchorWireTests.swift — the anchor prefix IS the ServiceNames one (#0028).
//
// `ServiceNames.journalRefPrefix` (YardKit) names where every other part of
// the product — the CLI, the app, the hook layer — expects journal anchors
// to live. `JournalAnchor.refPrefix` (YardGit) is where the engine actually
// writes them, built from `RefSnapshot.switchyardNamespace` because the
// engine cannot import `YardKit` and the literal may exist only in
// `ServiceNames.swift`. #0027's wire test pins containment in the excluded
// namespace; this one pins the stronger fact — the two strings are equal —
// so neither side can drift without a red test here.

import Testing
import YardGit
import YardKit

@Suite("Journal anchor prefix")
struct JournalAnchorWireTests {

    @Test func anchorPrefixEqualsTheServiceNamesJournalRefPrefix() {
        #expect(JournalAnchor.refPrefix == ServiceNames.journalRefPrefix)
    }
}
