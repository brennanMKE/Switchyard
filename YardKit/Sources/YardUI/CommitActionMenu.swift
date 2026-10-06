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
        let shared = CommitActionMenuReasons.shared(states)
        if let shared {
            Text(shared)
            Divider()
        }
        ForEach(Array(CommitAction.menuGroups.enumerated()), id: \.offset) { groupIndex, group in
            if groupIndex > 0 { Divider() }
            ForEach(group, id: \.self) { action in
                let state = byAction[action]
                Button {
                    perform(action)
                } label: {
                    Text(action.title(branchName: branchName))
                    if let subtitle = CommitActionMenuReasons.subtitle(for: state, shared: shared) {
                        Text(subtitle)
                    }
                }
                .keyboardShortcut(action.shortcut)
                .disabled(state?.isEnabled != true)
                .help(state?.disabledReason ?? "")
                .accessibilityValue(state?.disabledReason ?? "")
            }
        }
    }
}

/// #0604: where a disabled item's reason is shown. macOS shows no tooltip
/// unless the pointer rests on the item, so the reason is drawn as the
/// item's subtitle — except when every item is disabled for one reason
/// (no commit selected, an operation running), which is shown once at the
/// top instead of sixteen times.
public nonisolated enum CommitActionMenuReasons {
    /// The reason every item shares, or `nil` when any item is enabled or
    /// two items are disabled for different reasons.
    public static func shared(_ states: [CommitActionState]) -> String? {
        guard let first = states.first?.disabledReason else { return nil }
        return states.allSatisfy { $0.disabledReason == first } ? first : nil
    }

    /// The subtitle under one item: its own reason, unless `shared` already
    /// says it.
    public static func subtitle(for state: CommitActionState?, shared: String?) -> String? {
        guard shared == nil else { return nil }
        return state?.disabledReason
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
