// JournalMenu.swift
//
// #0393: the Edit menu's Undo and Redo over the journal. The pure pieces —
// the operation-title map and the undoTarget/cursor derivation — live here
// so JournalMenuTests can reach them without scene machinery; the wiring
// (the focused target, `JournalCommands`) is the thin declaration surface,
// the same split CommitActionMenu.swift draws for the Commit menu.

import AppKit
import SwiftUI
import YardGit

/// The menu item titles, named after the operation that wrote the entry a
/// step would restore (#0393). Operation strings are display-only (#0034
/// decision 7); this map is exactly that decision's "this use".
public nonisolated enum JournalMenuTitles {
    /// The first six measured from each engine's `around` call, the rest
    /// named by M8 — the operation string each in-app action writes.
    private static let titles: [String: String] = [
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

    /// "Undo <title>" for a mapped operation, plain "Undo" for anything
    /// else — an unknown operation string, or an entry whose metadata did
    /// not decode.
    public static func undo(operation: String?) -> String {
        title("Undo", operation: operation)
    }

    /// "Redo <title>" for a mapped operation, plain "Redo" otherwise.
    public static func redo(operation: String?) -> String {
        title("Redo", operation: operation)
    }

    private static func title(_ verb: String, operation: String?) -> String {
        guard let operation, let name = titles[operation] else { return verb }
        return "\(verb) \(name)"
    }
}

/// The undoTarget/cursor derivation the titles read (#0393): undo restores
/// `state.undoTarget` — the pre-operation capture of the entry it names —
/// and redo replays forward onto `state.cursor`, read only when
/// `state.redoTarget` says a step exists.
public nonisolated enum JournalMenu {
    /// The operation of the entry `state.undoTarget` names, or nil when
    /// there is nothing to undo or the entry carries no metadata.
    public static func undoOperation(in listing: JournalList.Listing?) -> String? {
        guard let target = listing?.state.undoTarget else { return nil }
        return listing?.items.first { $0.entry.id == target }?.metadata?.operation
    }

    /// The operation of the entry `state.cursor` names, read only when
    /// `state.redoTarget` names a step — nil when there is nothing to redo
    /// or the cursor entry carries no metadata.
    public static func redoOperation(in listing: JournalList.Listing?) -> String? {
        guard listing?.state.redoTarget != nil, let cursor = listing?.state.cursor else {
            return nil
        }
        return listing?.items.first { $0.entry.id == cursor }?.metadata?.operation
    }
}

/// What the menu bar's Edit menu acts on: the focused window's journal
/// state — both titles, both enabled flags, and the traversal to run. The
/// same shape `CommitMenuTarget` gives the Commit menu.
public struct JournalMenuTarget {
    public enum Kind: Sendable { case undo, redo }

    public let undoTitle: String
    public let redoTitle: String
    public let undoEnabled: Bool
    public let redoEnabled: Bool
    public let perform: (Kind) -> Void

    public init(
        undoTitle: String, redoTitle: String,
        undoEnabled: Bool, redoEnabled: Bool,
        perform: @escaping (Kind) -> Void
    ) {
        self.undoTitle = undoTitle
        self.redoTitle = redoTitle
        self.undoEnabled = undoEnabled
        self.redoEnabled = redoEnabled
        self.perform = perform
    }
}

extension FocusedValues {
    @Entry public var journalMenuTarget: JournalMenuTarget? = nil
}

/// Edit ▸ Undo (⌘Z) and Redo (⇧⌘Z), replacing the `.undoRedo` group the
/// system Edit menu fills (#0393). When the key window's first responder is
/// an `NSText` view — #0359's message editor, #0375's split sheet — the
/// items forward `undo:` / `redo:` down the responder chain instead of
/// calling the journal, so text editing keeps its own undo stack, which
/// replacing the command group would otherwise take away.
public struct JournalCommands: Commands {
    @FocusedValue(\.journalMenuTarget) private var target

    public init() {}

    public var body: some Commands {
        // A text view owns ⌘Z while it is first responder, whatever the
        // journal's state — so the enabled check yields to it.
        let editingText = NSApp.keyWindow?.firstResponder is NSText
        CommandGroup(replacing: .undoRedo) {
            Button(target?.undoTitle ?? "Undo") {
                if NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) { return }
                target?.perform(.undo)
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!(target?.undoEnabled ?? false) && !editingText)

            Button(target?.redoTitle ?? "Redo") {
                if NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) { return }
                target?.perform(.redo)
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!(target?.redoEnabled ?? false) && !editingText)
        }
    }
}
