// WindowID.swift
//
// #0078: the identity of one app window. `WindowGroup(for:)` requires the
// value to be `Hashable`, `Codable`, and `Sendable` -- SwiftUI persists and
// restores windows by decoding these values, and compares them to decide
// whether a scene request names an existing window.
//
// Deliberately `nonisolated`: this is inert value data, not UI state. Under
// YardUI's `.defaultIsolation(MainActor.self)` a type declared here would
// otherwise be MainActor-isolated, which would isolate the synthesized
// Codable witnesses and make the conformance unusable outside the main
// actor. `WindowStore` and `WindowState` -- the types that actually own UI
// state -- stay on the target's default MainActor isolation (see
// WindowState.swift).
//
// The no-argument initialiser is what the app's Cmd-N / `openWindow(value:)`
// path uses. Every call must produce a distinct id, which the tests assert.

import Foundation

nonisolated public struct WindowID: Hashable, Codable, Sendable {
    /// The unique identifier. Two `WindowID()`s are never equal.
    public let uuid: UUID

    public init() {
        uuid = UUID()
    }

    /// Rebuilds a specific id -- e.g. one decoded from persisted scene state.
    public init(uuid: UUID) {
        self.uuid = uuid
    }
}
