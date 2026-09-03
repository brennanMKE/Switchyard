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
//
// #0083: the whole layout -- windows, their ordered tabs, and the active tab
// -- persists to the state directory (`ServiceNames.stateDirectory()`, the
// one the CLI shares, guide §3) and restores from it on relaunch. Three
// pieces live here:
//
// - `WindowLayoutSnapshot`, the Codable wire shape (schema-versioned, like
//   `RecentOperations`' store file);
// - `CoalescingStateWriter`, the write throttle -- structural changes only
//   *mark* a write pending, and every flush writes **at most once** no
//   matter how many changes accumulated, so rapid tab switches can never
//   thrash the disk. The unit of throttling is the flush, not a timer, so
//   tests assert write COUNTS and never wall-clock time;
// - `WindowStore.save(to:tabs:)` / `WindowStore.restore(from:tabs:)`.
//
// Restore's contract is deliberately never-throw: a missing, corrupt,
// truncated, or foreign-schema file degrades to behaving exactly like a
// fresh launch (one seeded, empty window), never an error and never a crash
// loop. Restore replaces the window list with exactly the stored windows --
// the #0078 phantom-window trap is the *opposite* failure (a window the
// store does not hold), so restore may neither add windows beyond the
// stored count nor leave the seeded placeholder behind beside them.

import Foundation
import Observation
import YardKit

/// One window's state: its identity and the tabs open in it.
@Observable
public final class WindowState {
    /// The window's identity. Stable for the window's lifetime.
    public let id: WindowID

    /// Identities of the tabs open in this window. Empty for a new window;
    /// #0079 replaces this placeholder with the real tab model.
    public var tabIDs: [UUID] = [] {
        didSet {
            // #0083: any mutation of a window's tab list -- including the
            // direct array mutations the tab-bar bindings commit (#0080 /
            // #0084) -- is a structural change and marks a save pending.
            onStructureChange?()
        }
    }

    /// Fired whenever this window's structural state changes (#0083). The
    /// owning `WindowStore` points this at its `stateWriter`; tests can
    /// point it anywhere. The same seam shape as `RepositoryTab.onTeardown`.
    public var onStructureChange: (() -> Void)?

    public init(id: WindowID) {
        self.id = id
    }
}

/// The persisted shape of the app's windows and tabs (#0083).
///
/// A tab's stable identity across relaunches is its repository's
/// `WorktreeContext.commonDir` -- already canonical through `realpath(3)` by
/// the resolver -- not its runtime `UUID`, which is deliberately per-lifetime
/// (a stale window reference must not resurrect closed state). Display state
/// rides along: the selected worktree name and which tab was active.
///
/// `nonisolated`, like `WindowID`: inert value data whose Codable
/// conformance must be usable wherever the file is read.
nonisolated public struct WindowLayoutSnapshot: Codable, Equatable, Sendable {
    /// Bump on any wire change. A snapshot carrying any other version
    /// degrades restore to a fresh launch rather than mis-decoding.
    public static let schemaVersionCurrent = 1

    public var schemaVersion: Int
    public var windows: [Window]

    public struct Window: Codable, Equatable, Sendable {
        public var id: WindowID
        /// The window's tabs in tab-bar order.
        public var tabs: [Tab]

        public struct Tab: Codable, Equatable, Sendable {
            public var commonDir: String
            public var selectedWorktreeName: String?
            /// True for the one tab that was active when the layout was
            /// saved -- `RepositoryTabs.selectedTabID` is global, so across
            /// the whole snapshot at most one tab carries this.
            public var isActive: Bool

            public init(commonDir: String, selectedWorktreeName: String?, isActive: Bool) {
                self.commonDir = commonDir
                self.selectedWorktreeName = selectedWorktreeName
                self.isActive = isActive
            }
        }

        public init(id: WindowID, tabs: [Tab]) {
            self.id = id
            self.tabs = tabs
        }
    }

    public init(schemaVersion: Int = WindowLayoutSnapshot.schemaVersionCurrent, windows: [Window]) {
        self.schemaVersion = schemaVersion
        self.windows = windows
    }
}

/// The write throttle behind #0083's state persistence.
///
/// Every structural change calls `scheduleWrite()`, which only marks a write
/// pending -- it performs no I/O. `flushNow()` performs **at most one** write
/// and clears the pending mark, so N changes between flushes cost one write,
/// not N: that is the whole anti-thrash guarantee, and it is why the unit of
/// throttling is the flush rather than a timer. Flush points are the app's
/// commit decisions (terminate, scene background, last-window close -- the
/// launch wiring is #0125's); this type owns only the coalescing.
///
/// The write closure is injected, so a test counts writes through a spy
/// without touching any file.
@Observable
public final class CoalescingStateWriter {
    private let write: () -> Void
    private var isDirty = false

    /// True while at least one structural change has not been flushed yet.
    public var hasPendingWrite: Bool { isDirty }

    public init(write: @escaping () -> Void) {
        self.write = write
    }

    /// Records that a structural change happened. Coalescing: any number of
    /// calls before the next flush produce exactly one write.
    public func scheduleWrite() {
        isDirty = true
    }

    /// Performs the write if one is pending, and clears the pending mark.
    /// Returns whether a write happened, so a caller (or a test spy) can
    /// count flushes that did work without inspecting the file.
    @discardableResult
    public func flushNow() -> Bool {
        guard isDirty else { return false }
        isDirty = false
        write()
        return true
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

    /// #0083: the coalescing writer structural changes mark pending writes
    /// through, or nil when the store is used without persistence wiring.
    /// The app target attaches the production writer to `shared`; tests
    /// attach a spy to count writes.
    public var stateWriter: CoalescingStateWriter?

    public init() {
        // Two-step on purpose: `makeWindow` reads `self` (its hook reads
        // `stateWriter` at fire time), so `windows` must be initialized
        // before the seed window is built through it.
        windows = []
        windows = [makeWindow(id: WindowID())]
    }

    /// The state-directory file name for the persisted layout (#0083),
    /// beside `repositories.json` and `recent-operations.json`.
    public static let stateFileName = "window-state.json"

    /// Where the persisted layout lives in the state directory the CLI
    /// shares (`ServiceNames.stateDirectory()`, guide §3). Deliberately a
    /// property the app target passes **explicitly** into `save`/`restore`:
    /// nothing here defaults a call into the real state directory, so a
    /// test cannot touch it by omission (the `RecentOperations` rule).
    public static var stateFileURL: URL {
        ServiceNames.stateDirectory()
            .appendingPathComponent(Self.stateFileName, isDirectory: false)
    }

    /// Builds a window whose tab-list mutations mark a save pending on this
    /// store's `stateWriter` (#0083). The single factory for every window
    /// this store ever holds -- the seeded window, windows from
    /// `addWindow`, and windows rebuilt by `restore` -- so no mutation
    /// route can bypass the hook. Reads `stateWriter` at fire time, so a
    /// writer attached after windows exist is still honored.
    private func makeWindow(id: WindowID) -> WindowState {
        let state = WindowState(id: id)
        state.onStructureChange = { [weak self] in self?.stateWriter?.scheduleWrite() }
        return state
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
        let added = makeWindow(id: WindowID())
        windows.append(added)
        stateWriter?.scheduleWrite()
        return added
    }

    /// Closes the window with id `id`. A no-op when it would remove the
    /// last remaining window (see the type's discussion) or when no window
    /// with that id is open.
    public func removeWindow(_ id: WindowID) {
        guard windows.count > 1 else { return }
        windows.removeAll { $0.id == id }
        stateWriter?.scheduleWrite()
    }

    // MARK: - Persistence (#0083)

    /// Writes the whole layout -- windows in order, each window's tabs in
    /// tab-bar order (keyed by `commonDir`, with the selected worktree and
    /// the active flag), and every window's identity -- to `fileURL` as
    /// JSON. `tabs` supplies the open-tab data the window model's bare
    /// `tabIDs` point at.
    ///
    /// A `tabIDs` entry that resolves to no open tab (a stale id) is
    /// dropped from the snapshot rather than stored as a dangling
    /// reference. The write is atomic (temp-file-then-rename) and the
    /// directory is created owner-only (0700), matching `RecentOperations`.
    ///
    /// Deliberately NOT called on a timer: callers drive writes through a
    /// `CoalescingStateWriter`, so N changes between flushes cost one write.
    public func save(to fileURL: URL, tabs: RepositoryTabs) throws {
        let snapshot = WindowLayoutSnapshot(
            windows: windows.map { window in
                WindowLayoutSnapshot.Window(
                    id: window.id,
                    tabs: window.tabIDs.compactMap { tabs.tab(for: $0) }.map { tab in
                        WindowLayoutSnapshot.Window.Tab(
                            commonDir: tab.context.commonDir,
                            selectedWorktreeName: tab.selectedWorktreeName,
                            isActive: tabs.selectedTabID == tab.id
                        )
                    }
                )
            }
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Restores the layout persisted at `fileURL` into this store and
    /// `tabs`. Windows come back **exactly** as stored -- the stored count,
    /// the stored ids, the stored tab order -- replacing the seeded
    /// single-window launch state. Restore never adds a window beyond the
    /// stored count (the #0078 phantom-window trap) and never resolves a
    /// repository: tabs are inserted by `RepositoryTabs.restoreTab`, keyed
    /// by the stored `commonDir` alone.
    ///
    /// **Never throws.** A missing, unreadable, corrupt, truncated, or
    /// foreign-schema file leaves this store and `tabs` exactly as they
    /// were -- the fresh-launch invariant (one seeded, empty window), never
    /// a crash loop. The same is true of a snapshot that decodes but holds
    /// no windows: the never-empty invariant wins.
    ///
    /// The active tab comes back through `tabs.selectedTabID` (global, as
    /// the model owns it): the one stored tab carrying `isActive` anywhere
    /// in the file. Multiple `isActive` flags -- only possible in a
    /// hand-written file, since `save` emits at most one -- take the first.
    public func restore(from fileURL: URL, tabs: RepositoryTabs) {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? Self.decoder.decode(WindowLayoutSnapshot.self, from: data),
              snapshot.schemaVersion == WindowLayoutSnapshot.schemaVersionCurrent
        else { return }

        let restored = snapshot.windows.map { stored in
            let state = makeWindow(id: stored.id)
            state.tabIDs = stored.tabs.map { storedTab in
                tabs.restoreTab(
                    commonDir: storedTab.commonDir,
                    selectedWorktreeName: storedTab.selectedWorktreeName
                ).id
            }
            return state
        }
        guard !restored.isEmpty else { return }
        windows = restored

        for (window, stored) in zip(restored, snapshot.windows) {
            guard let index = stored.tabs.firstIndex(where: { $0.isActive }),
                  index < window.tabIDs.count
            else { continue }
            tabs.selectedTabID = window.tabIDs[index]
            break
        }
    }

    /// Sorted and pretty so the file diffs cleanly and tests are
    /// deterministic -- the same choice `RecentOperations` makes.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
