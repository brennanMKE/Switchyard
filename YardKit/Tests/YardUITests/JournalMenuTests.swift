// JournalMenuTests.swift — the Edit menu's Undo/Redo titles and their
// chain-state derivation (#0393). Pure values only: the title map and the
// undoTarget/cursor derivation are unit-tested here without scene
// machinery, the same level CommitActionMenuTests covers the Commit menu's
// states.

import Foundation
import Testing
import YardGit
import YardUI

@Suite("JournalMenuTitles")
struct JournalMenuTitlesTests {

    /// #0393's title map, exactly as the issue pins it: the first six
    /// measured from each engine's `around` call, the rest named by M8.
    @Test func everyMeasuredAndNamedOperationHasItsTitle() {
        let pairs: [String: String] = [
            "reword": "Edit Message",
            "drop": "Delete Commit",
            "reorder": "Move Commit",
            "fixup": "Fixup",
            "split": "Split",
            "absorb": "Absorb",
            "revert": "Revert",
            "cherry-pick": "Cherry-Pick",
            "merge": "Merge",
            "rebase-onto": "Rebase",
            "set-tip": "Set Branch Tip",
            "branch-create": "New Branch",
            "branch-rename": "Rename Branch",
            "branch-delete": "Delete Branch",
            "tag-create": "New Tag",
            "tag-delete": "Delete Tag",
        ]
        #expect(pairs.count == 16)
        for (operation, name) in pairs {
            #expect(JournalMenuTitles.undo(operation: operation) == "Undo \(name)")
            #expect(JournalMenuTitles.redo(operation: operation) == "Redo \(name)")
        }
    }

    /// Anything unmapped — no metadata, an unknown string, an empty one —
    /// falls back to the plain verb, never to a mangled title.
    @Test func unknownOrMissingOperationFallsBackToThePlainTitles() {
        #expect(JournalMenuTitles.undo(operation: nil) == "Undo")
        #expect(JournalMenuTitles.redo(operation: nil) == "Redo")
        #expect(JournalMenuTitles.undo(operation: "checkpoint") == "Undo")
        #expect(JournalMenuTitles.redo(operation: "checkpoint") == "Redo")
        #expect(JournalMenuTitles.undo(operation: "") == "Undo")
        #expect(JournalMenuTitles.redo(operation: "") == "Redo")
    }
}

@Suite("JournalMenu derivation")
struct JournalMenuDerivationTests {

    private let rewordID = JournalEntryID("01AAAAAAAAAAAAAAAAAAAAAAAA")!
    private let dropID = JournalEntryID("01BBBBBBBBBBBBBBBBBBBBBBBB")!
    private let traversalID = JournalEntryID("01CCCCCCCCCCCCCCCCCCCCCCCC")!

    private func item(_ id: JournalEntryID, operation: String?) -> JournalList.Item {
        JournalList.Item(
            entry: JournalAnchor.Entry(id: id, commit: String(repeating: "0", count: 40)),
            metadata: operation.map {
                JournalEntryMetadata(
                    id: id, operation: $0, timestamp: Date(timeIntervalSince1970: 0),
                    worktree: JournalEntryMetadata.Worktree(name: nil, path: "/repo"),
                    captured: JournalEntryMetadata.Captured(
                        refs: true, head: true, index: .tree,
                        worktree: .notCaptured, untracked: false))
            },
            defect: nil, position: .history)
    }

    private func listing(
        items: [JournalList.Item], cursor: JournalEntryID?,
        undoTarget: JournalEntryID?, redoTarget: JournalChain.RedoStep?
    ) -> JournalList.Listing {
        JournalList.Listing(
            items: items, foreignRefs: [],
            state: JournalChain.State(
                cursor: cursor, undoTarget: undoTarget,
                redoTarget: redoTarget, protectedIDs: []))
    }

    /// The issue's proving scenario: undo restores the reword's
    /// pre-operation capture and the cursor then stands on it, so the Undo
    /// title names "Edit Message" before the step and the Redo title does
    /// after it — each from the entry its state field names.
    @Test func titlesNameTheRewordBeforeAndAfterTheTraversal() {
        let reword = item(rewordID, operation: "reword")
        let before = listing(
            items: [reword], cursor: nil, undoTarget: rewordID, redoTarget: nil)
        #expect(JournalMenu.undoOperation(in: before) == "reword")
        #expect(JournalMenuTitles.undo(operation: JournalMenu.undoOperation(in: before))
                == "Undo Edit Message")
        #expect(JournalMenuTitles.redo(operation: JournalMenu.redoOperation(in: before))
                == "Redo")

        let after = listing(
            items: [reword], cursor: rewordID, undoTarget: nil,
            redoTarget: .present(capturedBy: traversalID))
        #expect(JournalMenu.undoOperation(in: after) == nil)
        #expect(JournalMenuTitles.undo(operation: JournalMenu.undoOperation(in: after))
                == "Undo")
        #expect(JournalMenu.redoOperation(in: after) == "reword")
        #expect(JournalMenuTitles.redo(operation: JournalMenu.redoOperation(in: after))
                == "Redo Edit Message")
    }

    /// Each title reads the entry its own state field names, not just the
    /// first item: undoTarget names the reword, the cursor stands on the
    /// drop, and `.entry(_)` names the redo's restore target.
    @Test func undoAndRedoReadTheirOwnNamedEntriesAmongSeveral() {
        let listing = self.listing(
            items: [item(rewordID, operation: "reword"), item(dropID, operation: "drop")],
            cursor: dropID, undoTarget: rewordID, redoTarget: .entry(dropID))
        #expect(JournalMenu.undoOperation(in: listing) == "reword")
        #expect(JournalMenu.redoOperation(in: listing) == "drop")
        #expect(JournalMenuTitles.undo(operation: JournalMenu.undoOperation(in: listing))
                == "Undo Edit Message")
        #expect(JournalMenuTitles.redo(operation: JournalMenu.redoOperation(in: listing))
                == "Redo Delete Commit")
    }

    /// A redo step with the cursor at present — the post-undo shape's undo
    /// half, or a truncated tail — names no operation: the cursor entry the
    /// title would read does not exist.
    @Test func redoWithNoCursorEntryReadsNil() {
        let reword = item(rewordID, operation: "reword")
        let listing = self.listing(
            items: [reword], cursor: nil, undoTarget: rewordID,
            redoTarget: .entry(rewordID))
        #expect(JournalMenu.undoOperation(in: listing) == "reword")
        #expect(JournalMenu.redoOperation(in: listing) == nil)
        #expect(JournalMenuTitles.redo(operation: JournalMenu.redoOperation(in: listing))
                == "Redo")
    }

    /// An empty journal — never checkpointed — names nothing for either
    /// title, which is what leaves both items plain and disabled.
    @Test func emptyJournalNamesNothing() {
        let listing = self.listing(items: [], cursor: nil, undoTarget: nil, redoTarget: nil)
        #expect(JournalMenu.undoOperation(in: listing) == nil)
        #expect(JournalMenu.redoOperation(in: listing) == nil)
        #expect(JournalMenuTitles.undo(operation: JournalMenu.undoOperation(in: listing))
                == "Undo")
        #expect(JournalMenuTitles.redo(operation: JournalMenu.redoOperation(in: listing))
                == "Redo")
    }

    /// A target whose entry's metadata did not decode still disables
    /// correctly, but its title falls back to the plain verb.
    @Test func targetWithNoMetadataFallsBackToThePlainTitle() {
        let listing = self.listing(
            items: [item(dropID, operation: nil)], cursor: nil,
            undoTarget: dropID, redoTarget: nil)
        #expect(JournalMenu.undoOperation(in: listing) == nil)
        #expect(JournalMenuTitles.undo(operation: JournalMenu.undoOperation(in: listing))
                == "Undo")
    }

    /// A nil listing — no repository open, or the load failed — names
    /// nothing for either title.
    @Test func nilListingNamesNothing() {
        #expect(JournalMenu.undoOperation(in: nil) == nil)
        #expect(JournalMenu.redoOperation(in: nil) == nil)
    }

    /// "checkpoint" is a real journal operation — every snapshot writes
    /// one — but maps to no title: the plain word wins, not an omission.
    @Test func unknownOperationStillNamesItsEntry() {
        let listing = self.listing(
            items: [item(dropID, operation: "checkpoint")], cursor: nil,
            undoTarget: dropID, redoTarget: nil)
        #expect(JournalMenu.undoOperation(in: listing) == "checkpoint")
        #expect(JournalMenuTitles.undo(operation: JournalMenu.undoOperation(in: listing))
                == "Undo")
    }
}
