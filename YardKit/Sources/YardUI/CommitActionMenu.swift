// CommitActionMenu.swift
//
// #0359: one menu body shared by the History list's context menu and the
// menu bar's Commit menu, so both show the same items, order, shortcuts and
// disabled states. The rules live in `CommitActions.swift`; this file only
// renders `CommitActionState`s and calls back with a `CommitAction`.
//
// `.help` on a disabled item shows its reason where macOS surfaces one;
// #0381's spike records whether a tooltip appears on a disabled menu item.
// The reason's primary guarantee is the unit test, not the hover.

import SwiftUI

public struct CommitActionMenuItems: View {
    private let states: [CommitActionState]
    private let branchName: String?
    private let perform: (CommitAction) -> Void

    public init(
        states: [CommitActionState], branchName: String? = nil,
        perform: @escaping (CommitAction) -> Void
    ) {
        self.states = states
        self.branchName = branchName
        self.perform = perform
    }

    public var body: some View {
        let byAction = Dictionary(uniqueKeysWithValues: states.map { ($0.action, $0) })
        ForEach(Array(CommitAction.menuGroups.enumerated()), id: \.offset) { groupIndex, group in
            if groupIndex > 0 { Divider() }
            ForEach(group, id: \.self) { action in
                let state = byAction[action]
                Button(action.title(branchName: branchName)) { perform(action) }
                    .keyboardShortcut(action.shortcut)
                    .disabled(state?.isEnabled != true)
                    .help(state?.disabledReason ?? "")
            }
        }
    }
}

/// What the menu bar's Commit menu acts on: the focused window's selected
/// commit. This is what makes the shortcuts real — a shortcut shown only in
/// a context menu is not guaranteed to fire while that menu is closed
/// (#0382's spike settles it).
public struct CommitMenuTarget {
    public let states: [CommitActionState]
    public let perform: (CommitAction) -> Void

    public init(states: [CommitActionState], perform: @escaping (CommitAction) -> Void) {
        self.states = states
        self.perform = perform
    }
}

extension FocusedValues {
    @Entry public var commitMenuTarget: CommitMenuTarget? = nil
}

public struct CommitCommands: Commands {
    @FocusedValue(\.commitMenuTarget) private var target

    public init() {}

    public var body: some Commands {
        CommandMenu("Commit") {
            CommitActionMenuItems(
                states: target?.states ?? CommitActionRules.allDisabled(reason: "Select a commit first"),
                perform: { target?.perform($0) })
        }
    }
}
