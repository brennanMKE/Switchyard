// RepositorySidebarView.swift
//
// #0081: the Sidebar pane's real content -- local branches, remote-tracking
// branches, tags, worktrees, and a stash count. Replaces the #0339
// placeholder in `ContentView.swift`.
//
// Re-scoped 2026-08-18 for the MVP (see issue 0081's "Re-scoped" section):
// selection does not switch tab context (no tabs yet, #0079), there is no
// live reload on external ref changes (#0217), and per-worktree ahead/behind
// and attached agent sessions are not shown.
//
// #0371: the ref sections collapse again -- the MVP dropped collapsing and
// used plain `Section`s throughout. Branches, Remotes and Tags collapse
// (Branches expanded, Remotes and Tags collapsed by default); Worktrees,
// Rerere and Stashes stay plain. #0398: the collapse control is a
// `DisclosureGroup` inside a plain `Section` -- `Section(_:isExpanded:)`
// draws no disclosure control on macOS 26.6.2 (#0386 measured), so the
// spike's failure branch shipped. Expansion state is per window and
// deliberately not persisted.
//
// #0372: local branch rows carry a trailing status -- the branch's
// ahead/behind and its merged state, as guide §11 decision 27 defines them
// (A3: against the upstream when set, else the default branch, the baseline
// named; M6: merged by ancestry, else upstream-gone, else content, with
// *unknown* for conflicts). The status read is one `for-each-ref` process
// run when the opened worktree path changes (`BranchStatus.read`, the
// decision's synchronous-load budget); the content pass is a background
// `.task` (`BranchStatus.contentPass`) that fills the merged answers after
// the rows appear -- content-dependent rows read *unknown* until it lands.
// #0378: a filter field at the top of the sidebar (`.searchable`, sidebar
// placement) narrows the three ref sections as the user types -- case- and
// diacritic-insensitive substring on the short ref name (`RefFilter`).
// While the query is significant the non-ref sections (HEAD, Worktrees,
// Rerere, Stashes) are hidden so the list shows only results, every ref
// section with matches renders expanded regardless of its stored state
// (via `.constant`, which never writes the binding), and an empty result
// set shows `ContentUnavailableView.search`. Clearing the field restores
// the stored expansion -- filtering never mutates it.

import SwiftUI
import YardGit

/// Branches, remotes, tags, worktrees, and a stash count for one repository.
///
/// A `List` whose three ref sections -- Branches, Remotes, Tags -- collapse
/// via a `DisclosureGroup` inside a plain `Section` (#0371 re-planned onto
/// this by #0398, after #0386 measured `Section(_:isExpanded:)` rendering no
/// disclosure control on macOS 26.6.2); every other section stays a plain
/// `Section`. `List` already gives scrolling and row selection for free.
/// Expansion state is per window and not persisted across launches,
/// deliberately (#0371).
public struct RepositorySidebarView: View {
    private let summary: RepositorySidebarSummary

    /// #0065: the selected recorded resolution's conflict id, routed to the
    /// Detail pane. `nil` when nothing is selected; the Detail pane's
    /// rerere branch observes it the way it observes the History pane's
    /// commit selection.
    @Binding private var selectedResolution: String?

    /// #0401: the full ref name of the sidebar row last clicked, owned by
    /// `ContentView`; the matching row draws selected.
    private let selectedRef: String?
    /// #0401: reports a click on a branch or remote row. The sidebar never
    /// writes the History selection itself.
    private let onSelectRef: ((RefSnapshot.Entry) -> Void)?
    /// #0496: the oid of the stash row last clicked, owned by
    /// `ContentView`; the matching row draws selected.
    private let selectedStash: String?
    /// #0496: reports a click on a stash row (guide §11 decision 36).
    private let onSelectStash: ((Stash.Item) -> Void)?
    /// #0496: a stash row's context menu: Apply and Pop run, Drop… asks
    /// first, which `ContentView` owns.
    private let onStashAction: ((StashAction) -> Void)?
    private let onDropStash: ((Stash.Item) -> Void)?
    /// #0496: disables the context menu's items while anything runs.
    private let isBusy: Bool
    /// #0510: what the ref rows' Switch, Check Out and Delete items need to
    /// decide availability (guide §11 decision 38). `nil` hides the items
    /// (previews, tests).
    private let refContext: RefActionContext?
    /// #0510: Switch and Check Out run at once; the deletions ask first,
    /// which `ContentView` owns.
    private let onRefAction: ((RefAction) -> Void)?
    private let onDeleteRef: ((RefDeleteConfirmation) -> Void)?
    /// #0532: a remote row's menu and the Remotes header's Add Remote…
    /// (guide §11 decision 41). `nil` hides the items (previews, tests).
    private let onRemoteCommand: ((RemoteMenuCommand) -> Void)?

    /// #0371: the ref sections' initial expansion state. Branches opens so
    /// the current branch is visible without a click; Remotes and Tags start
    /// collapsed -- Switchyard measures 309 local and 294 remote-tracking
    /// refs, so a fully open sidebar is effectively unreachable. Per window;
    /// deliberately not persisted across launches. `nonisolated` on purpose:
    /// inert constants, asserted by tests running off the main actor.
    public nonisolated static let branchesStartExpanded = true
    public nonisolated static let remotesStartExpanded = false
    public nonisolated static let tagsStartExpanded = false

    /// The three ref sections' live expansion state, seeded from the
    /// `*StartExpanded` constants above.
    @State private var branchesExpanded = RepositorySidebarView.branchesStartExpanded
    @State private var remotesExpanded = RepositorySidebarView.remotesStartExpanded
    @State private var tagsExpanded = RepositorySidebarView.tagsStartExpanded

    /// #0372: the per-branch ahead/behind + upstream state behind the local
    /// branch rows' trailing status -- the one-process `for-each-ref` read
    /// (`BranchStatus.read`, decision 27's sidebar-load budget). `nil` until
    /// it lands, and whenever the read fails: rows then carry no numbers.
    /// Reloaded whenever the opened worktree path changes.
    @State private var branchStatus: BranchStatus.Report?

    /// #0372: the background `merge-tree --write-tree` content pass's
    /// answers, keyed by full ref name (`BranchStatus.contentPass`). `nil`
    /// until the pass lands after the sidebar appears -- content-dependent
    /// merged answers read *unknown* until then, never blocking the rows.
    @State private var contentStates: [String: BranchStatus.MergedState]?
    /// #0571: the worktree `branchStatus` was read for. A refresh of the
    /// same worktree keeps the old numbers on screen until the new ones
    /// land; a different worktree clears them first.
    @State private var branchStatusPath: String?
    /// #0378: the filter field's text. Empty or all-whitespace means no
    /// filtering; anything else narrows the three ref sections. #0402: owned
    /// by ContentView so the History pane filters too.
    @Binding private var refFilter: String

    public init(
        summary: RepositorySidebarSummary,
        selectedResolution: Binding<String?>,
        refFilter: Binding<String> = .constant(""),
        selectedRef: String? = nil,
        onSelectRef: ((RefSnapshot.Entry) -> Void)? = nil,
        selectedStash: String? = nil,
        onSelectStash: ((Stash.Item) -> Void)? = nil,
        onStashAction: ((StashAction) -> Void)? = nil,
        onDropStash: ((Stash.Item) -> Void)? = nil,
        isBusy: Bool = false,
        refContext: RefActionContext? = nil,
        onRefAction: ((RefAction) -> Void)? = nil,
        onDeleteRef: ((RefDeleteConfirmation) -> Void)? = nil,
        onRemoteCommand: ((RemoteMenuCommand) -> Void)? = nil
    ) {
        self.summary = summary
        self._selectedResolution = selectedResolution
        self._refFilter = refFilter
        self.selectedRef = selectedRef
        self.onSelectRef = onSelectRef
        self.selectedStash = selectedStash
        self.onSelectStash = onSelectStash
        self.onStashAction = onStashAction
        self.onDropStash = onDropStash
        self.isBusy = isBusy
        self.refContext = refContext
        self.onRefAction = onRefAction
        self.onDeleteRef = onDeleteRef
        self.onRemoteCommand = onRemoteCommand
    }

    // `nonisolated`: inert String constants, read by the `nonisolated`
    // `sortedBranches` below -- under YardUI's default isolation an
    // unannotated static is MainActor-isolated, and a nonisolated reader of
    // a MainActor static traps at runtime (see RepositoryOpener.swift's
    // `nonisolated` statics for the same reasoning).
    private nonisolated static let headsPrefix = "refs/heads/"
    private nonisolated static let remotesPrefix = "refs/remotes/"
    private nonisolated static let tagsPrefix = "refs/tags/"

    /// #0571: what the branch status is re-read for — the worktree, and
    /// every ref, since a commit, push, fetch or undo moves one.
    private struct BranchStatusKey: Equatable {
        let path: String?
        let refs: RefSnapshot
    }

    /// `HEAD`'s current branch name, from `RefSnapshot.head`. `nil` on a
    /// detached `HEAD` -- `isDetached` below covers that case explicitly
    /// rather than this falling through to "no branch marked".
    private var currentBranchName: String? {
        guard case let .symbolic(target) = summary.refs.head,
              target.hasPrefix(Self.headsPrefix) else { return nil }
        return String(target.dropFirst(Self.headsPrefix.count))
    }

    private var isDetached: Bool {
        if case .detached = summary.refs.head { return true }
        return false
    }

    private var branches: [RefSnapshot.Entry] {
        // #0378: sort first (#0371), then filter -- the current branch stays
        // first among the matches.
        Self.filtered(
            Self.sortedBranches(
                summary.refs.refs.filter { $0.name.hasPrefix(Self.headsPrefix) },
                currentBranchName: currentBranchName
            ),
            prefix: Self.headsPrefix,
            query: refFilter
        )
    }

    /// #0371: branch order -- the current branch first, the rest by full ref
    /// name. `currentBranchName` is the short name from `RefSnapshot.head`;
    /// `nil` (a detached `HEAD`) or a name with no matching ref yields a
    /// plain name sort. The tuple comparison ranks the current branch's
    /// `(0, name)` ahead of every other branch's `(1, name)`.
    /// `nonisolated` on purpose: a pure function on inert value data, so
    /// tests and callers off the main actor can use it without an isolation
    /// trap (same reasoning as `RepositoryOpener`'s statics).
    public nonisolated static func sortedBranches(
        _ entries: [RefSnapshot.Entry], currentBranchName: String?
    ) -> [RefSnapshot.Entry] {
        let currentRef = currentBranchName.map { headsPrefix + $0 }
        return entries.sorted {
            ($0.name == currentRef ? 0 : 1, $0.name) < ($1.name == currentRef ? 0 : 1, $1.name)
        }
    }

    /// #0371: every ref row's help text is the entry's full ref name, so a
    /// row the sidebar truncates can be read in full on hover. The label
    /// shows the short name; the help shows `entry.name`. `nonisolated` on
    /// purpose, like `sortedBranches` above.
    public nonisolated static func helpText(for entry: RefSnapshot.Entry) -> String {
        entry.name
    }

    /// #0433: a local branch row's help text -- the full ref name
    /// (`helpText`), then the full status text on a second line when there
    /// is one. The row gives its width to the name and truncates the status,
    /// so hover is where the whole status, baseline included, stays
    /// readable. `nonisolated` on purpose, like `helpText` above.
    public nonisolated static func branchHelpText(
        for entry: RefSnapshot.Entry, status: String?
    ) -> String {
        guard let status else { return helpText(for: entry) }
        return helpText(for: entry) + "\n" + status
    }

    /// #0372: a local branch row's trailing status -- the A3 ahead/behind
    /// with the baseline named, then the M6 merged state, joined with a
    /// middle dot -- or `nil` when the status read has not landed, has no
    /// row for this ref, or has nothing to say. Merged answers the composite
    /// can reach without the content pass (ancestry, upstream-gone) show as
    /// soon as the read lands; content-dependent branches read *unknown*
    /// until the background pass fills `content`.
    ///
    /// #0422: when the default branch does not resolve (no `origin/HEAD`
    /// and no local `main` -- `row.defaultAhead` is `nil`), no merged answer
    /// short of upstream-gone is reachable at all, so *unknown* is not
    /// pending, it is permanent -- and it was every row's only text. The
    /// word is dropped in that case; a row with neither numbers nor a
    /// merged answer shows nothing. `nonisolated` on purpose, like
    /// `helpText` above: pure text over inert value data, so tests and
    /// callers off the main actor can use it.
    public nonisolated static func branchStatusText(
        for entry: RefSnapshot.Entry,
        report: BranchStatus.Report?,
        content: [String: BranchStatus.MergedState]?
    ) -> String? {
        guard let report, let row = report.row(forBranchNamed: entry.name) else { return nil }
        var parts: [String] = []
        if let aheadBehind = aheadBehindText(for: row) { parts.append(aheadBehind) }
        let merged = BranchStatus.mergedState(for: row, content: content ?? [:])
        if merged != .unknown || row.defaultAhead != nil {
            parts.append(mergedText(merged))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// #0372: the A3 numbers with the baseline named -- decision 27 requires
    /// the row to say which branch the numbers are against, because ahead of
    /// the upstream returns to 0 on push while ahead of the default never
    /// returns to 0 after a squash landing. `nil` when the row has no
    /// resolvable numbers (no upstream set and no measurable default branch).
    public nonisolated static func aheadBehindText(for row: BranchStatus.Row) -> String? {
        guard let ahead = row.ahead, let behind = row.behind else { return nil }
        let baseline = row.baseline.displayName
        let counts: String
        switch (ahead, behind) {
        case (0, 0):
            counts = "in sync"
        case (0, let b):
            counts = "↓\(b)"
        case (let a, 0):
            counts = "↑\(a)"
        case (let a, let b):
            counts = "↑\(a)↓\(b)"
        }
        return "\(counts) vs \(baseline)"
    }

    /// #0372: the M6 merged-state word. `unknown` is honest, not a failure:
    /// a conflict answer and an unlanded content pass are both shown as
    /// unknown rather than guessed at (decision 27).
    public nonisolated static func mergedText(_ state: BranchStatus.MergedState) -> String {
        switch state {
        case .merged:
            return "merged"
        case .notMerged:
            return "not merged"
        case .unknown:
            return "unknown"
        }
    }

    /// #0378: the entries whose *short* name -- the ref name minus `prefix`
    /// -- survives the filter (`RefFilter.matches`). An empty or all-whitespace
    /// query returns every entry unchanged, so the unfiltered layout is a
    /// fixed point. Callers pre-filter by prefix, as the accessors below do.
    /// `nonisolated` on purpose, like `sortedBranches` above.
    public nonisolated static func filtered(
        _ entries: [RefSnapshot.Entry], prefix: String, query: String
    ) -> [RefSnapshot.Entry] {
        entries.filter { RefFilter.matches(String($0.name.dropFirst(prefix.count)), query: query) }
    }

    private var remotes: [RefSnapshot.Entry] {
        Self.filtered(
            summary.refs.refs
                .filter { $0.name.hasPrefix(Self.remotesPrefix) }
                .sorted { $0.name < $1.name },
            prefix: Self.remotesPrefix,
            query: refFilter
        )
    }

    /// #0532: one run of the Remotes section — a configured remote's row
    /// followed by its remote-tracking branches, or (`remote == nil`) the
    /// remote-tracking branches no configured remote owns, which list as
    /// before (guide §11 decision 41).
    public nonisolated struct RemoteGroup: Equatable, Identifiable, Sendable {
        public let remote: RemoteConfig.Remote?
        public let branches: [RefSnapshot.Entry]
        public var id: String { remote.map { "remote:" + $0.name } ?? "unowned" }
    }

    /// #0532: the Remotes section's groups. `branches` are the section's
    /// remote-tracking refs, already narrowed by the filter; a remote's row
    /// shows while nothing is filtered, when its name matches the filter,
    /// or when any of its branches do. A remote's branches are the refs
    /// under `refs/remotes/<name>/` (add and rename refuse nested names, so
    /// no two remotes share one).
    public nonisolated static func remoteGroups(
        remotes: [RemoteConfig.Remote], branches: [RefSnapshot.Entry], query: String
    ) -> [RemoteGroup] {
        let filtering = !query.trimmingCharacters(in: .whitespaces).isEmpty
        var owned = Set<String>()
        var groups: [RemoteGroup] = []
        for remote in remotes.sorted(by: { $0.name < $1.name }) {
            let prefix = remotesPrefix + remote.name + "/"
            let mine = branches.filter { $0.name.hasPrefix(prefix) }
            owned.formUnion(mine.map(\.name))
            if !filtering || !mine.isEmpty || RefFilter.matches(remote.name, query: query) {
                groups.append(RemoteGroup(remote: remote, branches: mine))
            }
        }
        let unowned = branches.filter { !owned.contains($0.name) }
        if !unowned.isEmpty { groups.append(RemoteGroup(remote: nil, branches: unowned)) }
        return groups
    }

    private var remoteGroups: [RemoteGroup] {
        Self.remoteGroups(remotes: summary.remotes, branches: remotes, query: refFilter)
    }

    private var tags: [RefSnapshot.Entry] {
        Self.filtered(
            summary.refs.refs
                .filter { $0.name.hasPrefix(Self.tagsPrefix) }
                .sorted { $0.name < $1.name },
            prefix: Self.tagsPrefix,
            query: refFilter
        )
    }

    /// #0378: true while the filter query is significant -- non-empty after
    /// trimming, the same rule `RefFilter.matches` applies.
    private var isFiltering: Bool {
        !refFilter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The rerere resolutions the Detail pane can show and forget: the
    /// entries with a recorded postimage, in `Rerere.status`'s id order.
    /// Merely-known entries (a live conflict git is tracking, preimage
    /// only) are not recorded resolutions and stay out of the section —
    /// the conflicts surface owns live-conflict reporting (#0065 round 1).
    private var recordedResolutions: [Rerere.Entry] {
        summary.rerere.entries.filter { $0.state == .recorded }
    }

    public var body: some View {
        List {
            // #0378: while filtering only the three ref sections show, so
            // the detached-HEAD banner hides with the other non-ref
            // sections and comes back when the field clears.
            if !isFiltering && isDetached {
                Section("HEAD") {
                    Label("Detached HEAD", systemImage: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                }
            }
            if !branches.isEmpty {
                // #0398: `Section(_:isExpanded:)` draws no disclosure control
                // on macOS 26.6.2 (#0386 measured), so the collapse moves to
                // a `DisclosureGroup` inside a plain `Section` -- same
                // binding, including #0378's force-expand while filtering
                // (`.constant` never writes it, so clearing the field
                // restores the user's stored layout).
                Section {
                    DisclosureGroup(
                        isExpanded: isFiltering ? .constant(true) : $branchesExpanded
                    ) {
                        ForEach(branches, id: \.name) { entry in
                            selectable(entry, branchRow(entry), onDoubleClick: { switchTo(entry) })
                                .contextMenu { branchMenu(entry) }
                        }
                    } label: {
                        Text("Branches")
                    }
                }
            }
            // #0532: shown while unfiltered even with no remotes, so Add
            // Remote… is always reachable (guide §11 decision 41).
            if !remoteGroups.isEmpty || !isFiltering {
                Section {
                    DisclosureGroup(
                        isExpanded: isFiltering ? .constant(true) : $remotesExpanded
                    ) {
                        ForEach(remoteGroups) { group in
                            if let remote = group.remote {
                                remoteConfigRow(remote)
                                    .contextMenu { remoteConfigMenu(remote) }
                            }
                            ForEach(group.branches, id: \.name) { entry in
                                selectable(entry, refRow(entry, prefix: Self.remotesPrefix, systemImage: "network"))
                                    .contextMenu { remoteMenu(entry) }
                            }
                        }
                        if remoteGroups.isEmpty {
                            Text("No remotes")
                                .foregroundStyle(.secondary)
                                .contextMenu { addRemoteItem }
                        }
                    } label: {
                        Text("Remotes")
                            .contextMenu { addRemoteItem }
                    }
                }
            }
            if !tags.isEmpty {
                Section {
                    DisclosureGroup(
                        isExpanded: isFiltering ? .constant(true) : $tagsExpanded
                    ) {
                        ForEach(tags, id: \.name) { entry in
                            refRow(entry, prefix: Self.tagsPrefix, systemImage: "tag")
                                .contextMenu { tagMenu(entry) }
                        }
                    } label: {
                        Text("Tags")
                    }
                }
            }
            if isFiltering {
                // #0378: every ref section came back empty -- no matches.
                if branches.isEmpty && remoteGroups.isEmpty && tags.isEmpty {
                    ContentUnavailableView.search(text: refFilter)
                }
            } else {
                if !summary.worktrees.isEmpty {
                    Section("Worktrees") {
                        ForEach(Array(summary.worktrees.enumerated()), id: \.offset) { _, entry in
                            worktreeRow(entry)
                        }
                    }
                }
                if !recordedResolutions.isEmpty {
                    Section("Rerere") {
                        ForEach(recordedResolutions, id: \.conflictID) { entry in
                            rerereRow(entry)
                        }
                    }
                }
                // #0496: every stash, `stash@{0}` first (guide §11
                // decision 36).
                Section("Stashes") {
                    if summary.stashes.isEmpty {
                        Text("No stashes")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(summary.stashes) { item in
                        stashRow(item)
                    }
                }
            }
        }
        .searchable(text: $refFilter, placement: .sidebar, prompt: "Filter")
        .listStyle(.sidebar)
        .task(id: BranchStatusKey(path: summary.currentWorktreePath, refs: summary.refs)) {
            // #0372: the synchronous-load read is one `for-each-ref` process
            // (decision 27's budget); the content pass is the background
            // fill that lands after the rows appear. #0571: re-read whenever
            // a ref moves, not only when the worktree changes; a repository
            // switch must not show the previous repository's numbers for a
            // moment, so only a new path clears them first.
            guard let path = summary.currentWorktreePath else { return }
            if branchStatusPath != path {
                branchStatus = nil
                contentStates = nil
                branchStatusPath = path
            }
            guard let report = try? await BranchStatus.read(at: path) else { return }
            branchStatus = report
            contentStates = try? await BranchStatus.contentPass(for: report, at: path)
        }
    }

    /// #0401: makes a branch or remote row clickable. A tap gesture rather
    /// than a `Button` keeps the row's `Label` text a plain static text,
    /// which the VM UI tests find the row by (`sidebarRow(named:)`).
    ///
    /// #0510: a double click runs `onDoubleClick` — Switch, on a local
    /// branch row. The double-click gesture is attached first so SwiftUI
    /// tries it before the single tap.
    private func selectable<Content: View>(
        _ entry: RefSnapshot.Entry, _ content: Content, onDoubleClick: (() -> Void)? = nil
    ) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onDoubleClick?() }
            .onTapGesture { onSelectRef?(entry) }
            .listRowBackground(
                selectedRef == entry.name
                    ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25))
                    : nil)
    }

    /// A branch row: the branch glyph (a filled checkmark for the current
    /// branch), the short name, and -- #0372 -- the trailing status text
    /// (`branchStatusText`): ahead/behind with the baseline named, then the
    /// merged state.
    ///
    /// #0433: the name wins the row's width. It carries a higher layout
    /// priority than the status, so the status truncates first and the name
    /// only when the name alone is wider than the row. The help text is the
    /// full ref name plus the full status (`branchHelpText`), so a status the
    /// row truncates -- including decision 27's baseline name -- is still
    /// readable on hover.
    private func branchRow(_ entry: RefSnapshot.Entry) -> some View {
        let name = String(entry.name.dropFirst(Self.headsPrefix.count))
        let isCurrent = !isDetached && name == currentBranchName
        let status = Self.branchStatusText(
            for: entry, report: branchStatus, content: contentStates)
        return HStack(spacing: 8) {
            Label(name, systemImage: isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .fontWeight(isCurrent ? .semibold : .regular)
                .lineLimit(1)
                .layoutPriority(1)
            if let status {
                Spacer(minLength: 8)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(Self.branchHelpText(for: entry, status: status))
    }

    // MARK: - #0510: Switch, Check Out and Delete (guide §11 decision 38)

    private func shortName(_ entry: RefSnapshot.Entry, _ prefix: String) -> String {
        String(entry.name.dropFirst(prefix.count))
    }

    /// Double-click on a local branch: Switch, when the rules allow it.
    private func switchTo(_ entry: RefSnapshot.Entry) {
        let name = shortName(entry, Self.headsPrefix)
        guard let refContext, RefActionRules.switchReason(branch: name, refContext) == nil else { return }
        onRefAction?(.switchBranch(name: name))
    }

    /// A local branch row's menu: Switch, then Delete Branch…. A disabled
    /// item carries its reason as help text.
    @ViewBuilder
    private func branchMenu(_ entry: RefSnapshot.Entry) -> some View {
        if let refContext {
            let name = shortName(entry, Self.headsPrefix)
            let switchReason = RefActionRules.switchReason(branch: name, refContext)
            Button("Switch to “\(name)”") { onRefAction?(.switchBranch(name: name)) }
                .disabled(switchReason != nil)
                .help(switchReason ?? "")
            Divider()
            let deleteReason = RefActionRules.deleteBranchReason(branch: name, refContext)
            Button("Delete Branch…") { onDeleteRef?(.branch(name)) }
                .disabled(deleteReason != nil)
                .help(deleteReason ?? "")
        }
    }

    /// A remote branch row's menu: Check Out as Local Branch.
    @ViewBuilder
    private func remoteMenu(_ entry: RefSnapshot.Entry) -> some View {
        if let refContext {
            let name = shortName(entry, Self.remotesPrefix)
            let reason = RefActionRules.trackReason(remoteBranch: name, refContext)
            Button("Check Out as Local Branch") { onRefAction?(.trackRemote(remoteBranch: name)) }
                .disabled(reason != nil)
                .help(reason ?? "")
        }
    }

    /// #0532: a configured remote's row: its name, and its fetch URL under
    /// it; the help text lists the fetch and push URLs.
    private func remoteConfigRow(_ remote: RemoteConfig.Remote) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(remote.name, systemImage: "server.rack")
                .fontWeight(.medium)
            Text(remote.fetchURL ?? "No URL")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 22)
        }
        .help(Self.remoteHelpText(remote))
    }

    /// #0532: a remote row's help text: where it fetches from and pushes to.
    public nonisolated static func remoteHelpText(_ remote: RemoteConfig.Remote) -> String {
        let fetch = "Fetch: " + (remote.fetchURL ?? "no URL")
        guard remote.pushDiffers else { return fetch }
        let push = remote.pushURLs.isEmpty ? ["no URL"] : remote.pushURLs
        return fetch + "\n" + push.map { "Push: " + $0 }.joined(separator: "\n")
    }

    /// #0532: a configured remote's menu (guide §11 decision 41). Every
    /// item disables while another operation runs.
    @ViewBuilder
    private func remoteConfigMenu(_ remote: RemoteConfig.Remote) -> some View {
        if let onRemoteCommand {
            let busy = isBusy ? "Another operation is still running" : ""
            Group {
                Button("Fetch “\(remote.name)”") { onRemoteCommand(.run(.fetch(remote: remote.name))) }
                Button("Prune “\(remote.name)”") { onRemoteCommand(.run(.prune(remote: remote.name))) }
                Divider()
                Button("Edit URL…") {
                    onRemoteCommand(.editURL(
                        remote: remote.name, pushURLs: remote.pushDiffers ? remote.pushURLs : []))
                }
                Button("Rename Remote…") { onRemoteCommand(.rename(remote: remote.name)) }
                Button("Remove Remote…") { onRemoteCommand(.remove(remote: remote.name)) }
                Divider()
                Button("Add Remote…") { onRemoteCommand(.add) }
            }
            .disabled(isBusy)
            .help(busy)
        }
    }

    /// #0532: Add Remote…, on the Remotes header and the "No remotes" row.
    @ViewBuilder
    private var addRemoteItem: some View {
        if let onRemoteCommand {
            Button("Add Remote…") { onRemoteCommand(.add) }
                .disabled(isBusy)
        }
    }

    /// A tag row's menu: Delete Tag….
    @ViewBuilder
    private func tagMenu(_ entry: RefSnapshot.Entry) -> some View {
        if let refContext {
            let reason = RefActionRules.deleteTagReason(refContext)
            Button("Delete Tag…") { onDeleteRef?(.tag(shortName(entry, Self.tagsPrefix))) }
                .disabled(reason != nil)
                .help(reason ?? "")
        }
    }

    /// A remote or tag row: the ref name minus its prefix as the label, the
    /// full ref name as help text (#0371).
    private func refRow(_ entry: RefSnapshot.Entry, prefix: String, systemImage: String) -> some View {
        Label(String(entry.name.dropFirst(prefix.count)), systemImage: systemImage)
            .help(Self.helpText(for: entry))
    }

    /// A worktree row. The current worktree -- the one `ContentView` opened
    /// -- is marked by comparing `entry.path` against
    /// `summary.currentWorktreePath`, both canonicalized by git itself
    /// (`RepositoryLoader.swift`'s `loadRepositorySidebar` doc comment).
    /// `isMainWorktree` marks the *main* worktree, which is the wrong
    /// question here: opening a linked worktree's folder must mark that
    /// worktree, not always the main one.
    private func worktreeRow(_ entry: WorktreeEntry) -> some View {
        let isCurrent = entry.path != nil && entry.path == summary.currentWorktreePath
        let displayName = entry.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "(bare)"
        return VStack(alignment: .leading, spacing: 2) {
            Label(displayName, systemImage: isCurrent ? "checkmark.circle.fill" : "folder")
                .fontWeight(isCurrent ? .semibold : .regular)
            if let branch = entry.branch {
                Text(branch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if entry.detached {
                Text("detached")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// #0496: a stash row -- its message without git's `On <branch>: `
    /// prefix, and `stash@{n}` with its date beneath, the worktree row's
    /// two-line shape. A tap selects it, the way a branch row selects (a
    /// tap gesture, so the label stays the static text the VM tests find);
    /// the context menu offers Apply, Pop and Drop….
    private func stashRow(_ item: Stash.Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(StashRowText.label(for: item), systemImage: "tray.full")
                .lineLimit(1)
            Text(StashRowText.caption(for: item))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(item.message)
        .contentShape(Rectangle())
        .onTapGesture { onSelectStash?(item) }
        .listRowBackground(
            selectedStash == item.oid
                ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25))
                : nil)
        .contextMenu {
            Button("Apply") { onStashAction?(.apply(oid: item.oid, restoreIndex: false)) }
                .disabled(isBusy)
            Button("Pop") { onStashAction?(.pop(oid: item.oid, restoreIndex: false)) }
                .disabled(isBusy)
            Divider()
            Button("Drop…") { onDropStash?(item) }
                .disabled(isBusy)
        }
    }

    /// A recorded rerere resolution row (#0065): the attributed path when
    /// one is live, else "Recorded resolution", with the short conflict id
    /// beneath — the worktree row's two-line shape. Tapping routes the
    /// conflict id to `selectedResolution` through a plain
    /// `.buttonStyle(.plain)` button (the review sheet's comment-remove
    /// affordance) rather than a `List(selection:)` binding: the sidebar's
    /// other sections are plain rows, and a list-wide selection binding
    /// would make every `ForEach` row selectable. The selected row marks
    /// itself semibold — the same marking `branchRow` uses for the current
    /// branch.
    private func rerereRow(_ entry: Rerere.Entry) -> some View {
        let isSelected = selectedResolution == entry.conflictID
        let displayName = entry.paths.isEmpty
            ? "Recorded resolution"
            : entry.paths.joined(separator: ", ")
        return Button {
            selectedResolution = entry.conflictID
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label(displayName, systemImage: "arrow.triangle.merge")
                    .fontWeight(isSelected ? .semibold : .regular)
                Text(String(entry.conflictID.prefix(12)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    @Previewable @State var selectedResolution: String?
    RepositorySidebarView(
        summary: RepositorySidebarSummary(
            refs: RefSnapshot(
                head: .symbolic(target: "refs/heads/main"),
                refs: [
                    RefSnapshot.Entry(name: "refs/heads/main", oid: "a1b2c3d"),
                    RefSnapshot.Entry(name: "refs/heads/feature", oid: "b2c3d4e"),
                    RefSnapshot.Entry(name: "refs/remotes/origin/main", oid: "a1b2c3d"),
                    RefSnapshot.Entry(name: "refs/tags/v1.0", oid: "c3d4e5f"),
                ]
            ),
            worktrees: [
                WorktreeEntry(path: "/tmp/repo", head: "a1b2c3d", branch: "main", isMainWorktree: true),
                WorktreeEntry(path: "/tmp/repo-wt", head: "b2c3d4e", branch: "feature"),
            ],
            currentWorktreePath: "/tmp/repo",
            rerere: Rerere.Status(
                enabled: true,
                entries: [
                    Rerere.Entry(
                        conflictID: "650b3bb115602e8f349398d8d6c560baaef932e3",
                        state: .recorded,
                        paths: ["f.txt"],
                        replayedPaths: [])
                ]
            ),
            stashes: [
                Stash.Item(
                    index: 0, oid: "d4e5f6a", baseOID: "a1b2c3d", includesUntracked: true,
                    date: 1_700_000_000, message: "On main: half done")
            ]
        ),
        selectedResolution: $selectedResolution
    )
}
