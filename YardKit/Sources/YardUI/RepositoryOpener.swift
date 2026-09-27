// RepositoryOpener.swift
//
// #0084: the shared funnel for every "open a repository" entry point --
// File ▸ Open and the recent menu, drag-and-drop onto window or Dock, the
// `switchyard://` URL scheme, and XPC. The focus-or-open rule itself is
// `RepositoryTabs.open(path:)` (#0079); nothing here resolves paths or
// decides identity, it only carries each entry point's argument shape into
// that one call and reports a refusal as a human-readable message.
//
// Four entry points is how "opening a repository twice gives two tabs"
// ships, so every caller in the app target goes through this file and
// nowhere else -- the app target stays declaration-thin (guide §11
// decision 10), and the grep proof in #0084's report checks that.
//
// Sits on YardUI's default MainActor isolation (Package.swift), like
// `RepositoryTabs` and `WindowStore`.

import AppKit
import YardKit

/// The shell-side funnel into `RepositoryTabs.open(path:)`.
@MainActor
public enum RepositoryOpener {

    // MARK: - The funnel

    /// Opens `path` through `store.open(path:)` -- the focus-or-open rule
    /// -- and presents a refusal as an alert, so every user-initiated
    /// entry point reports the same clear message. Returns the outcome
    /// either way.
    @discardableResult
    public static func open(
        path: String,
        store: RepositoryTabs = .shared
    ) -> RepositoryTabs.Outcome {
        // #0416: through the window placement, so the repository is SHOWN --
        // `store.open(path:)` alone only records a tab no window reads.
        let outcome = store.openInWindow(path: path)
        if let message = refusalMessage(for: outcome) {
            presentRefusal(message)
        }
        return outcome
    }

    // MARK: - Entry point 1: File ▸ Open…

    /// Runs a directory open panel and routes the chosen folder through
    /// `open(path:store:)`. Returns `nil` when the user cancelled.
    @discardableResult
    public static func chooseAndOpen(store: RepositoryTabs = .shared) -> RepositoryTabs.Outcome? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return open(path: url.path, store: store)
    }

    // MARK: - Entry point 2: drag and drop (window and Dock alike)

    /// Opens the first file URL a drop delivered, whatever surface it
    /// dropped on. Returns the outcome, or `nil` when the drop carried no
    /// file URL.
    @discardableResult
    public static func openDropped(
        urls: [URL],
        store: RepositoryTabs = .shared
    ) -> RepositoryTabs.Outcome? {
        guard let url = urls.first(where: { $0.isFileURL }) else { return nil }
        return open(path: url.path, store: store)
    }

    // MARK: - Entry points 2 + 3: OS-delivered opens

    /// Handles everything `application(_:open:)` delivers: file URLs
    /// (document and Dock-icon drops) and `switchyard://` URLs, each
    /// through `open(path:store:)`. A URL that names no repository path is
    /// ignored -- there is no path to report a refusal about.
    public static func openDelivered(urls: [URL], store: RepositoryTabs = .shared) {
        for url in urls {
            if let path = deliveredPath(from: url) {
                open(path: path, store: store)
            }
        }
    }

    /// The filesystem path a delivered URL names: itself for a file URL,
    /// the `path` query item of a `switchyard://` URL, otherwise nil.
    nonisolated public static func deliveredPath(from url: URL) -> String? {
        if url.isFileURL {
            return url.path
        }
        return repositoryPath(from: url)
    }

    /// The repository path a `switchyard://` URL names: the `path` query
    /// item, percent-decoded -- e.g.
    /// `switchyard://open?path=%2FUsers%2Fme%2FMy%20Repo`. `nil` for a
    /// foreign scheme or a URL that names no path.
    nonisolated public static func repositoryPath(from url: URL) -> String? {
        guard url.scheme?.lowercased() == ServiceNames.urlScheme.lowercased() else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        guard let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty
        else { return nil }
        return path
    }

    // MARK: - Refusal reporting

    /// The human-readable message an entry point reports for `outcome`, or
    /// nil when the outcome needs no report: focus and open succeed
    /// silently, and only a refusal carries a message. Every entry point
    /// shows the same text for the same refusal, whatever route delivered
    /// the path -- this function is the single formatter.
    nonisolated public static func refusalMessage(
        for outcome: RepositoryTabs.Outcome
    ) -> String? {
        guard case .refused(let path, let detail) = outcome else { return nil }
        return "\(path) is not a Git repository.\n\n\(detail)"
    }

    /// Presents a refusal as a modal alert. Only the user-initiated entry
    /// points reach this; the XPC entry point logs the same message instead,
    /// because a CLI-triggered open must never block the app on a modal the
    /// user did not ask for.
    private static func presentRefusal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't open repository"
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - #0416: one repository per window

/// Brings a window on screen by its `WindowID`. `show` is installed by
/// `ContentView` when it appears -- `{ openWindow(value: $0) }` plus app
/// activation -- because only a view can read SwiftUI's `openWindow`
/// action, while the entry points that open repositories (the app
/// delegate's `application(_:open:)`, XPC, the menu) are not views. Nil
/// until the first window appears and in every test, so presenting is then
/// a no-op: at launch the repository was placed in the window that is about
/// to appear anyway (`WindowStore.place(_:)` picks the initial window).
@MainActor
public final class WindowPresenter {
    public static let shared = WindowPresenter()

    /// Shows the window for an id -- opens it, or focuses it when a window
    /// for that id is already on screen (`openWindow(value:)` semantics).
    public var show: ((WindowID) -> Void)?

    public init() {}

    public func present(_ id: WindowID) {
        show?(id)
    }
}

extension WindowStore {
    /// The window whose model holds `tabID`, or nil.
    public func window(showing tabID: UUID) -> WindowState? {
        windows.first { $0.tabIDs.contains(tabID) }
    }

    /// #0416: the window `tab` is shown in -- one repository per window.
    ///
    /// 1. A window already holding the tab: that window (focus, never a
    ///    duplicate).
    /// 2. Otherwise the current window -- `activeWindowID`, or the first
    ///    window before any window has been active -- when it holds no
    ///    repository: the tab goes into it.
    /// 3. Otherwise a new window holding just this tab.
    @discardableResult
    public func place(_ tab: RepositoryTab) -> WindowState {
        if let existing = window(showing: tab.id) {
            return existing
        }
        let current = activeWindowID.flatMap { windowState(for: $0) } ?? windows[0]
        if current.tabIDs.isEmpty {
            current.tabIDs = [tab.id]
            return current
        }
        let added = addWindow()
        added.tabIDs = [tab.id]
        return added
    }
}

extension RepositoryTabs {
    /// #0416: every entry point's open. Resolves `path` through
    /// `open(path:)` -- the focus-or-open rule by `$GIT_COMMON_DIR` -- then
    /// places the tab in a window (`WindowStore.place(_:)`) and presents
    /// that window. A refusal places and presents nothing.
    @discardableResult
    public func openInWindow(
        path: String,
        windowStore: WindowStore = .shared,
        presenter: WindowPresenter = .shared
    ) -> Outcome {
        let outcome = open(path: path)
        switch outcome {
        case .opened(let tab), .focusedExisting(let tab, _):
            presenter.present(windowStore.place(tab).id)
        case .refused:
            break
        }
        return outcome
    }
}
