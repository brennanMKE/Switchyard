// RepositoryTabs.swift
//
// #0079: one tab per repository. A tab's identity is its `$GIT_COMMON_DIR` --
// `WorktreeContext.commonDir` -- not the path the user opened. That single
// choice settles every dedup case at once:
//
// - opening an already-open repository focuses its tab;
// - opening a linked worktree of an open repository focuses the parent
//   repository's tab and selects that worktree inside it, because a linked
//   worktree resolves to the SAME commonDir as its parent;
// - opening the same repository by a different spelling of its path --
//   symlink, trailing slash, `/tmp` vs `/private/tmp`, a subdirectory --
//   focuses the existing tab, because `WorktreeContext.resolve` canonicalizes
//   every path it reports through `realpath(3)`.
//
// The store does NOT canonicalize anything itself: the view layer calls no
// realpath. Canonicalization is a property of `WorktreeContext`, and the
// tests assert the property (commonDir is a realpath fixed point) rather
// than re-deriving it.
//
// Resolution is injected, not called directly, so pure-store behaviour is
// testable with no git subprocess; every identity case is tested through the
// default resolver against real repositories, because what is under test is
// what git says.
//
// Both types sit on YardUI's default MainActor isolation (Package.swift sets
// `.defaultIsolation(MainActor.self)`), like `WindowStore` (#0078).

import Foundation
import Observation
import YardGit

/// One open repository's tab.
///
/// `id` is the stable handle other layers hold: `WindowState.tabIDs: [UUID]`
/// (#0078) stores exactly such ids, and #0080/#0084 wire the two models
/// together through them. Identity between tabs is `context.commonDir` --
/// two tabs with the same commonDir are the same repository and must never
/// both exist (the store refuses to create the second).
@Observable
public final class RepositoryTab: Identifiable {
    /// Stable identity for this tab's lifetime. Not derived from the
    /// repository: closing and reopening the same repository yields a new
    /// id, so a stale window reference cannot resurrect closed state.
    public let id: UUID

    /// The resolved repository identity. `context.commonDir` is the tab's
    /// key; `context.worktreeName` names the linked worktree this tab was
    /// opened by, if any.
    public let context: WorktreeContext

    /// The path the tab was opened by, as the user spelled it. Kept for
    /// diagnostics only -- never used for identity.
    public let openPath: String

    /// The linked worktree the tab is showing, or nil for the main
    /// worktree. Reopening the repository by any path re-selects the
    /// worktree the opening path names.
    public var selectedWorktreeName: String?

    /// Fired exactly once, by `RepositoryTabs.close`, when this tab is
    /// closed. This is where per-tab engine resources are released. There
    /// are no file watchers yet (#0081's sidebar/graph work introduces
    /// them); when they exist they are torn down here, which is how "closing
    /// a tab releases its watchers" is guaranteed without the store knowing
    /// what a watcher is.
    public var onTeardown: (() -> Void)?

    public init(id: UUID = UUID(), context: WorktreeContext, openPath: String) {
        self.id = id
        self.context = context
        self.openPath = openPath
        // A tab opened by a linked-worktree path starts on that worktree;
        // nil for the main worktree, which is the "no selection" default.
        self.selectedWorktreeName = context.worktreeName
    }

    /// The name a tab chip renders: the working tree's folder name, or the
    /// repository directory's for a bare repository (no top level).
    public var displayName: String {
        let base = context.topLevel ?? context.commonDir
        return (base as NSString).lastPathComponent
    }
}

/// The observable owner of the app's open-repository tab list (#0079).
///
/// The list is ordered (tab bar order) and keyed by `commonDir`: `open`
/// never appends a second tab for a repository already present. Selection
/// follows focus -- opening a path selects the tab it resolved to, whether
/// that tab was just created or already existed.
@Observable
public final class RepositoryTabs {

    /// What `open(path:)` did.
    public enum Outcome {
        /// The repository was already open: its tab was focused (made the
        /// selected tab) and the worktree named by the opening path is now
        /// selected inside it. `selectedWorktreeName` is nil when the path
        /// resolved to the main worktree.
        case focusedExisting(tab: RepositoryTab, selectedWorktreeName: String?)
        /// A new tab was opened for a repository that was not open yet.
        case opened(tab: RepositoryTab)
        /// The path is not a git repository. `detail` carries the
        /// resolver's `notARepository` detail so the caller can report the
        /// refusal clearly. No tab is opened.
        case refused(path: String, detail: String)
    }

    /// Resolves a user-supplied path to its repository identity. Defaults
    /// to `WorktreeContext.resolve(path:)`; tests inject fakes for
    /// pure-store behaviour.
    public typealias Resolver = (String) throws -> WorktreeContext

    /// The open tabs, in tab-bar order. Public so the tab bar view can bind
    /// reorder commits through `@Bindable` -- the same choice `WindowState`
    /// makes with `tabIDs` (#0078).
    public var tabs: [RepositoryTab] = []

    /// The selected tab's id, or nil when no tab is open (or nothing is
    /// selected). The tab bar's active-id binding.
    public var selectedTabID: UUID?

    private let resolve: Resolver

    /// - Parameter resolver: the identity resolver. Defaults to
    ///   `WorktreeContext.resolve(path:)`, which shells out to
    ///   `git rev-parse --git-common-dir` and canonicalizes through
    ///   `realpath(3)`.
    public init(resolver: @escaping Resolver = { try WorktreeContext.resolve(path: $0) }) {
        self.resolve = resolver
    }

    /// The open tab with id `id`, or nil.
    public func tab(for id: UUID) -> RepositoryTab? {
        tabs.first { $0.id == id }
    }

    /// Opens the repository at `path` -- or focuses the tab it is already
    /// open in, by commonDir identity. Refuses a path that is not a
    /// repository: the resolver's throw IS the gate, and no tab is created.
    ///
    /// Selecting follows the opening path: a linked-worktree path selects
    /// that worktree inside the (existing) tab; a main-worktree path
    /// re-selects the main worktree.
    @discardableResult
    public func open(path: String) -> Outcome {
        let context: WorktreeContext
        do {
            context = try resolve(path)
        } catch let error as WorktreeContext.Error {
            switch error {
            case let .notARepository(path: refusedPath, detail):
                return .refused(path: refusedPath, detail: detail)
            case .pathNotResolved:
                return .refused(path: path, detail: String(describing: error))
            }
        } catch {
            return .refused(path: path, detail: String(describing: error))
        }

        if let index = tabs.firstIndex(where: { $0.context.commonDir == context.commonDir }) {
            let tab = tabs[index]
            tab.selectedWorktreeName = context.worktreeName
            selectedTabID = tab.id
            return .focusedExisting(tab: tab, selectedWorktreeName: context.worktreeName)
        }

        let tab = RepositoryTab(context: context, openPath: path)
        tabs.append(tab)
        selectedTabID = tab.id
        return .opened(tab: tab)
    }

    /// Closes the tab with id `id` -- a no-op when no tab with that id is
    /// open. Fires the tab's `onTeardown` hook (the seam where per-tab
    /// engine resources and, once they exist, file watchers are released)
    /// and removes the tab from the list, leaving the other tabs' order
    /// intact.
    ///
    /// Closing the LAST tab is allowed: the list may empty. The never-empty
    /// guarantee is `WindowStore`'s (#0078) and lives at the window level --
    /// a window with no repository tabs is a valid state this store does
    /// not own. When the closed tab was the selected one, selection moves
    /// to the tab now at the closed tab's index (clamped to the last), or
    /// to nil when the list emptied.
    public func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        tab.onTeardown?()
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty
                ? nil
                : tabs[min(index, tabs.count - 1)].id
        }
    }
}

// MARK: - Tab bar chrome (#0079)

import SlidingTabs
import SwiftUI

/// The repository tab bar: `SlidingTabBar` over the store's tabs.
///
/// Chrome only -- every behaviour behind it is a property of
/// `RepositoryTabs`, testable with no view. The wiring is:
///
/// - **reorder** commits straight into the store: the bar's `items` binding
///   is `$store.tabs`, so a drop mutates the store's ordered list (and
///   SwiftUI's observation fires from the store, not from view-local state);
/// - **tap** selects through `$store.selectedTabID`;
/// - **"+"** invokes `onAdd`, which the app target supplies -- its closure
///   ends in `store.open(path:)` once a path picker exists (#0080/#0084
///   wire the panels). The store owns no picker: opening a repository needs
///   a path only the shell can choose.
/// - **close** on each chip calls `store.close(_:)`, firing that tab's
///   teardown hook before removal.
public struct RepositoryTabBar: View {
    private let store: RepositoryTabs
    private let onAdd: () -> Void

    public init(store: RepositoryTabs, onAdd: @escaping () -> Void) {
        self.store = store
        self.onAdd = onAdd
    }

    public var body: some View {
        @Bindable var store = store
        return SlidingTabBar(
            items: $store.tabs,
            activeID: $store.selectedTabID,
            onAdd: onAdd
        ) { tab, isActive in
            DefaultTabChip(
                title: tab.displayName,
                systemImage: tab.context.isLinkedWorktree
                    ? "arrow.triangle.branch"
                    : "folder.fill",
                isActive: isActive,
                onClose: { store.close(tab.id) }
            )
        }
    }
}
