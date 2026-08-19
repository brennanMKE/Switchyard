// PaneLayout.swift
//
// Minimum pane widths for the three-pane Git View shell (#0080). Split-position
// persistence and pane collapse are explicitly out of scope here -- see
// #0080's "Re-scoped 2026-08-18" section: persistence moves to #0083, and a
// draggable divider that can reach zero is treated as MVP-sufficient collapse,
// so there is no fraction or collapsed-state model to carry. This file is
// geometry constants only (criterion 6: no engine logic, view layer only).
//
// `nonisolated`: like `RepositorySummary` in RepositoryLoader.swift, these are
// plain immutable values with no reason to inherit YardUI's
// `.defaultIsolation(MainActor.self)`. Marking the type lets callers off the
// main actor -- including this target's tests -- read it without an `await`.

import SwiftUI

/// Minimum widths for the three fixed panes in `ContentView`'s loaded state,
/// and the window minimum they together require. A caseless enum used purely
/// as a namespace -- there is nothing here to instantiate.
public nonisolated enum PaneLayout {
    /// Sidebar pane minimum width, in points.
    public static let sidebarMinWidth: CGFloat = 120

    /// History pane minimum width, in points.
    public static let historyMinWidth: CGFloat = 160

    /// Detail pane minimum width, in points.
    public static let detailMinWidth: CGFloat = 200

    /// The narrowest a window can be while giving every pane its minimum
    /// width. `ContentView`'s `minWidth` must be at least this -- it is
    /// exactly today's 480, chosen so the window did not need to grow.
    public static let windowMinWidth: CGFloat = sidebarMinWidth + historyMinWidth + detailMinWidth
}
