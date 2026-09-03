// WindowState.swift
//
// #0078: the multi-window model. `WindowStore` is the observable owner of the
// app's window list; `WindowState` is one window's share of it. All of the
// behaviour lives here so `swift test` can reach it -- the app's
// `SwitchyardApp.swift` stays scene declarations only.
//
// Both types sit on YardUI's default MainActor isolation (Package.swift sets
// `.defaultIsolation(MainActor.self)`), because every mutation happens from
// SwiftUI or app-delegate code on the main actor. Only `WindowID` is
// `nonisolated`, because it is inert value data (see WindowID.swift).
//
// The tab list is a placeholder: #0079 owns the real tab model. What this
// round guarantees is the per-window *independence* the multi-window model
// needs -- each window owns its own array on its own instance, so mutating
// one window's tabs can never touch another's.

import Foundation
import Observation

/// One window's state: its identity and the tabs open in it.
@Observable
public final class WindowState {
    /// The window's identity. Stable for the window's lifetime.
    public let id: WindowID

    /// Identities of the tabs open in this window. Empty for a new window;
    /// #0079 replaces this placeholder with the real tab model.
    public var tabIDs: [UUID] = []

    public init(id: WindowID) {
        self.id = id
    }
}

/// The observable owner of the app's window list.
///
/// Seeds exactly one window at initialisation and keeps the list **never
/// empty**: the app's `WindowGroup(for:).defaultValue` hands SwiftUI
/// `initialWindowID`, so the first content window must always find its state
/// here. A default value naming an id the store does not hold is the
/// phantom-window trap (#0078) -- CLI/XPC-delivered work lands in an
/// invisible window while the visible one shows nothing. Consequently
/// `removeWindow` is a no-op when it would remove the last remaining window,
/// and `initialWindowID` always names the first window still in the list
/// (after the seeded window is closed it names the next one) -- never an id
/// absent from the store.
@Observable
public final class WindowStore {
    /// The store the app's scene declarations reach (`defaultValue`,
    /// Cmd-N's `openWindow(value:)` path). The initialiser is public so
    /// tests that import YardUI without `@testable` can construct isolated
    /// stores; the running app uses `shared`.
    public static let shared = WindowStore()

    /// Windows in creation order. Index 0 always exists -- see the type's
    /// discussion -- and is the window `initialWindowID` names.
    public private(set) var windows: [WindowState]

    public init() {
        windows = [WindowState(id: WindowID())]
    }

    /// The id the app's `WindowGroup(for:).defaultValue` returns. Always an
    /// id `windowState(for:)` can resolve -- that is the property the
    /// phantom-window trap is about, and the reason this returns the first
    /// window still in the list rather than a captured id that could
    /// outlive its state.
    public var initialWindowID: WindowID {
        windows[0].id // safe: the list is never empty
    }

    /// The state for `id`, or `nil` when no window with that id is open.
    public func windowState(for id: WindowID) -> WindowState? {
        windows.first { $0.id == id }
    }

    /// Opens a new window with its own independent tab set and returns its
    /// state. This is the model behind Cmd-N / `openWindow(value:)`.
    @discardableResult
    public func addWindow() -> WindowState {
        let added = WindowState(id: WindowID())
        windows.append(added)
        return added
    }

    /// Closes the window with id `id`. A no-op when it would remove the
    /// last remaining window (see the type's discussion) or when no window
    /// with that id is open.
    public func removeWindow(_ id: WindowID) {
        guard windows.count > 1 else { return }
        windows.removeAll { $0.id == id }
    }
}
