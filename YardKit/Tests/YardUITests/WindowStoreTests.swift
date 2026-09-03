// WindowStoreTests.swift
//
// #0078's multi-window model, tested through YardUI's public API -- this
// target imports YardUI WITHOUT `@testable`, so everything asserted here is
// reachable at exactly the access level the app target sees.
//
// `WindowStore` and `WindowState` live on YardUI's default MainActor
// isolation (Package.swift), so the tests that exercise them are @MainActor:
// the isolation is part of the type's contract. `WindowID` is `nonisolated`,
// and its Codable test deliberately runs without @MainActor to prove the
// conformance is usable outside the main actor too.
//
// NOT covered here, and not fakeable with a store inspection: the issue's
// URL-open and XPC-activation criteria (a real `switchyard://` open and an
// XPC-triggered activation must open no new window). Those need a running
// app and belong to #0054's manual script.

import Foundation
import Testing
import YardUI

@MainActor
@Test("A fresh store seeds exactly one window and initialWindowID names that seeded window")
func storeSeedsExactlyOneWindowAndInitialWindowIDNamesIt() throws {
    let store = WindowStore()
    #expect(store.windows.count == 1)
    let seeded = try #require(store.windows.first)
    #expect(store.initialWindowID == seeded.id)
    // The phantom-window trap as an assertion: the id the scene's
    // defaultValue hands out must resolve to state the store already holds,
    // not a fresh id with no runtime behind it.
    let resolved = try #require(store.windowState(for: store.initialWindowID))
    #expect(resolved === seeded)
}

@MainActor
@Test("Adding a window yields an independent tab set")
func addedWindowHasIndependentTabSet() throws {
    let store = WindowStore()
    let first = try #require(store.windowState(for: store.initialWindowID))
    first.tabIDs.append(UUID())

    let second = store.addWindow()
    second.tabIDs.append(UUID())
    second.tabIDs.append(UUID())

    // Adding really added, with a fresh identity the store resolves.
    #expect(store.windows.count == 2)
    #expect(first.id != second.id)
    #expect(store.windowState(for: second.id) === second)
    // Mutating one window's tabs leaves the other's unchanged.
    #expect(first.tabIDs.count == 1)
    #expect(second.tabIDs.count == 2)
}

@MainActor
@Test("Removing a window leaves the others intact; removing the last window is a no-op")
func removalLeavesOthersIntactAndLastRemovalIsNoOp() throws {
    let store = WindowStore()
    let firstID = store.initialWindowID
    let second = store.addWindow()

    store.removeWindow(firstID)
    #expect(store.windows.count == 1)
    #expect(store.windowState(for: firstID) == nil)
    // initialWindowID still names a window the store holds -- the never-
    // phantom invariant survives removing the seeded window.
    #expect(store.initialWindowID == second.id)

    // Removing the last remaining window is the documented no-op: the list
    // must never empty, because defaultValue names an id the store holds.
    store.removeWindow(second.id)
    #expect(store.windows.count == 1)
    #expect(store.windowState(for: second.id) === second)
}

@Test("WindowID round-trips through Codable")
func windowIDRoundTripsThroughCodable() throws {
    let original = WindowID()
    let other = WindowID()
    #expect(original != other)

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WindowID.self, from: data)
    #expect(decoded == original)
    #expect(decoded != other)
}
