// CommitIDPasteboardTests.swift — #0377's copy-to-pasteboard rule
//
// This target imports YardUI WITHOUT `@testable`, so the asserted surface is
// exactly what the app target sees. The general pasteboard IS the user's
// clipboard, so every test saves its contents first and restores them last;
// the suite is `.serialized` so two tests cannot interleave save and restore.

import AppKit
import Testing
import YardUI

@MainActor
@Suite(.serialized)
struct CommitIDPasteboardTests {
    /// A full 40-hex oid, as #0377's interaction requires — not a short id.
    private static let oid = "0123456789abcdef0123456789abcdef01234567"

    private func savePasteboard() -> [(NSPasteboard.PasteboardType, Data)] {
        let pasteboard = NSPasteboard.general
        return (pasteboard.types ?? []).compactMap { type in
            pasteboard.data(forType: type).map { (type, $0) }
        }
    }

    private func restorePasteboard(_ saved: [(NSPasteboard.PasteboardType, Data)]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        for (type, data) in saved.reversed() {
            pasteboard.setData(data, forType: type)
        }
    }

    @Test func copyPutsTheFullOidOnTheGeneralPasteboardAsString() {
        let saved = savePasteboard()
        defer { restorePasteboard(saved) }

        CommitIDPasteboard.copy(Self.oid)

        #expect(NSPasteboard.general.string(forType: .string) == Self.oid)
    }

    @Test func copyReplacesWhateverThePasteboardHeldBefore() {
        let saved = savePasteboard()
        defer { restorePasteboard(saved) }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("stale contents", forType: .string)
        #expect(NSPasteboard.general.string(forType: .string) == "stale contents")

        CommitIDPasteboard.copy(Self.oid)

        #expect(NSPasteboard.general.string(forType: .string) == Self.oid)
    }

    @Test func copyDeclaresTheStringType() {
        let saved = savePasteboard()
        defer { restorePasteboard(saved) }

        CommitIDPasteboard.copy(Self.oid)

        #expect((NSPasteboard.general.types ?? []).contains(.string))
    }
}
