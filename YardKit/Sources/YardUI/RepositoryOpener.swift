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
        let outcome = store.open(path: path)
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

// MARK: - Entry point 4's model half: open into the frontmost window

extension RepositoryTabs {
    /// #0084's XPC entry point. Opens `path` through `open(path:)` -- the
    /// same focus-or-open rule as the other three entry points -- and, when
    /// that open created a NEW tab, attaches the tab to the user's active
    /// window. A focus outcome touches no window: the repository is already
    /// open, in whatever window holds it. A refusal opens nothing.
    ///
    /// "Frontmost" at the model level is the window showing the selected
    /// tab -- what the tab-bar binding commits into `WindowState.tabIDs` --
    /// falling back to the first window when nothing is selected. Which
    /// NSWindow that is, and bringing it forward, only the shell can see
    /// (`NSApp.windows` order); that half is app-target code, checked by
    /// #0054's manual script.
    @discardableResult
    public func openInFrontmostWindow(
        path: String,
        windowStore: WindowStore = .shared
    ) -> Outcome {
        let previousSelection = selectedTabID
        let outcome = open(path: path)
        if case .opened(let tab) = outcome {
            let frontmost = previousSelection.flatMap { selected in
                windowStore.windows.first { $0.tabIDs.contains(selected) }
            } ?? windowStore.windows[0]
            frontmost.tabIDs.append(tab.id)
        }
        return outcome
    }
}
