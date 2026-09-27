// RepositoryWindowTabbing.swift
//
// #0417: repository tabs are native macOS window tabs. Each repository is
// its own window (#0416's one repository per window), and every repository
// window prefers to join the current window's tab group, so opening a
// second repository adds a tab instead of a window. AppKit supplies the rest
// for free: the tab bar, dragging a tab out ("Move Tab to New Window"),
// Window ▸ Merge All Windows, and Show/Hide Tab Bar.
//
// SwiftUI has no tabbing API, so the one AppKit setting is applied from a
// zero-size background view as soon as it joins its window -- before the
// window is first ordered on screen, which is when AppKit decides whether a
// new window joins a tab group.

import AppKit
import SwiftUI
import YardKit

/// The tabbing configuration every repository window gets.
public enum RepositoryWindowTabbing {
    /// Repository windows tab only with each other -- never with a Commit
    /// Changes window or Settings, which keep AppKit's defaults.
    public static let identifier = ServiceNames.bundleIdentifier + ".repository"

    /// Makes `window` a repository window that joins the current window's
    /// tab group when it is first shown, whatever the user's "Prefer tabs
    /// when opening documents" setting says.
    public static func configure(_ window: NSWindow) {
        window.tabbingIdentifier = identifier
        window.tabbingMode = .preferred
    }
}

/// A zero-size view that applies `RepositoryWindowTabbing.configure` to the
/// window it is placed in. `ContentView` puts it in its background.
struct RepositoryWindowTabbingAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> TabbingView {
        TabbingView()
    }

    func updateNSView(_ nsView: TabbingView, context: Context) {}

    final class TabbingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                RepositoryWindowTabbing.configure(window)
            }
        }
    }
}
