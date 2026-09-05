// ResolvePaneTests.swift — the resolve pane's model layer (#0057 round 2)
//
// This target imports YardUI WITHOUT `@testable`, so everything asserted
// here is reachable at exactly the access level the app target sees. The
// pane is a pure function of `ResolvePaneModel`, so every state is asserted
// through the model — no test renders anything, touches AppKit, or reaches
// the XPC layer: the store below is the real `PendingResolveStore`, wired to
// `ResolveCenter` exactly as the app target wires it.
//
// No test reads a clock (Rule 7c): registration and outcome waits are
// bounded polls with a ceiling that returns the moment the state arrives.

import Foundation
import Testing
import YardKit
import YardUI

@MainActor
@Suite("ResolvePane")
struct ResolvePaneTests {

    private struct WaitTimeout: Error {}

    // MARK: - Fixtures

    /// A record of the apply seam's calls — the engine apply's stand-in.
    private final class ApplyLog: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [PathResolution] = []
        private var armed = false

        /// The next call refuses, like the engine does on a stale index;
        /// every call after that succeeds (the human's retry).
        func armFailure() { lock.withLock { armed = true } }
        func record(_ resolution: PathResolution) throws {
            try lock.withLock {
                log.append(resolution)
                if armed {
                    armed = false
                    throw ResolvePaneApplyError.applyUnwired
                }
            }
        }
        var entries: [PathResolution] { lock.withLock { log } }
        var count: Int { lock.withLock { log.count } }
    }

    /// The awaiting CLI's stand-in: collects the store's typed outcome.
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ResolveOutcome?
        func set(_ outcome: ResolveOutcome) { lock.withLock { stored = outcome } }
        var outcome: ResolveOutcome? { lock.withLock { stored } }
    }

    private func pending(
        commonDir: String = "/repos/a/.git",
        timeoutSeconds: Int = 3600
    ) -> PendingResolveStore.Pending {
        PendingResolveStore.Pending(
            id: UUID(),
            request: ResolveRequest(
                commonDir: commonDir,
                pathspec: nil,
                timeoutSeconds: timeoutSeconds))
    }

    private func detail(
        path: String,
        kind: ConflictKind,
        base: String? = nil,
        ours: String? = nil,
        theirs: String? = nil,
        working: String? = nil
    ) -> ResolveCardData {
        ResolveCardData(
            path: path,
            kind: kind,
            baseText: kind == .bothAdded ? nil : "base line",
            oursText: "ours line",
            theirsText: kind == .deletedByUs ? nil : "theirs line",
            workingText: kind == .bothModified ? "<<< marker\nours line\n===\ntheirs line\n>>> marker" : nil)
    }

    private func card(_ pane: ResolvePaneModel, path: String) throws -> ResolveCardModel {
        try #require(pane.cards.first(where: { $0.data.path == path }))
    }

    /// Bounded wait for a centre state, running ON the main actor so the
    /// fetch closure may read @MainActor state. Throws when the state never
    /// arrives, rather than hanging.
    private func waitUntil(
        timeout: Duration = .seconds(300),
        _ fetch: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if fetch() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitTimeout()
    }

    // MARK: - The design table's per-kind cards

    @Test func contentCardOffersOursTheirsAndEditMerged() throws {
        let pane = ResolvePaneModel(pending: pending())
        pane.attachDetails(
            originPath: "/repos/a",
            details: [ResolveCardData(
                path: "Sources/A.swift",
                kind: .bothModified,
                baseText: "base",
                oursText: "ours",
                theirsText: "theirs",
                workingText: "<<< marker\nours line\ntheirs line")])
        let card = try #require(pane.cards.first)
        #expect(card.choices == [.useOurs, .useTheirs, .editedContent])
        #expect(card.selectedChoice == .useOurs, "the first choice is precomposed")
        #expect(card.editorText == "<<< marker\nours line\ntheirs line", "the seed is the working file's text")

        let resolution = try #require(card.resolution())
        #expect(resolution.path == "Sources/A.swift")
        #expect(resolution.kind == .bothModified)
        #expect(resolution.choice == .useOurs)
        #expect(resolution.editedContent == nil, "a side choice carries no edited content")
        #expect(resolution.note == nil, "an empty note is absent, not empty")
    }

    @Test func addAddCardSeedsItsEditorWithOurs() throws {
        let pane = ResolvePaneModel(pending: pending())
        pane.attachDetails(
            originPath: "/repos/a",
            details: [ResolveCardData(
                path: "New.swift",
                kind: .bothAdded,
                baseText: nil,
                oursText: "ours new file",
                theirsText: "theirs new file",
                workingText: nil)])
        let card = try card(pane, path: "New.swift")
        #expect(card.choices == [.useOurs, .useTheirs, .editedContent])
        #expect(card.editorText == "ours new file", "add/add seeds with ours' content")

        card.selectedChoice = .editedContent
        let resolution = try #require(card.resolution())
        #expect(resolution.choice == .editedContent)
        #expect(resolution.editedContent == "ours new file", "what the human saves is what stages")
    }

    @Test func deleteModifyCardOffersDeletionModificationAndEdit() throws {
        let pane = ResolvePaneModel(pending: pending())
        pane.attachDetails(
            originPath: "/repos/a",
            details: [ResolveCardData(
                path: "Gone.swift",
                kind: .deletedByUs,
                baseText: "base",
                oursText: nil,
                theirsText: "theirs modification",
                workingText: "theirs modification")])
        let card = try card(pane, path: "Gone.swift")
        #expect(card.choices == [.keepDeletion, .keepModification, .editedContent])
        #expect(card.selectedChoice == .keepDeletion)
        #expect(card.editorText == "theirs modification", "the seed is the surviving side")

        card.selectedChoice = .keepModification
        let resolution = try #require(card.resolution())
        #expect(resolution.kind == .deletedByUs)
        #expect(resolution.choice == .keepModification)
        #expect(resolution.editedContent == nil)

        card.selectedChoice = .editedContent
        #expect(card.resolution()?.editedContent == "theirs modification")
    }

    @Test func renameCardOffersOnlyTheSideItsRecordCarries() throws {
        // AU is ours' new path — it carries ours' stage only, so "Take
        // theirs'" would be a choice the engine must refuse. Round 1's
        // finding: a rename group is per-record cards.
        let ours = ResolvePaneModel(pending: pending())
        ours.attachDetails(
            originPath: "/repos/a",
            details: [ResolveCardData(path: "Renamed.swift", kind: .addedByUs, oursText: "ours")])
        let oursCard = try card(ours, path: "Renamed.swift")
        #expect(oursCard.choices == [.renameTakeOurs])
        #expect(oursCard.resolution()?.choice == .renameTakeOurs)
        #expect(oursCard.resolution()?.kind == .addedByUs)

        let theirs = ResolvePaneModel(pending: pending())
        theirs.attachDetails(
            originPath: "/repos/a",
            details: [ResolveCardData(path: "Moved.swift", kind: .addedByThem, theirsText: "theirs")])
        let theirsCard = try card(theirs, path: "Moved.swift")
        #expect(theirsCard.choices == [.renameTakeTheirs])
        #expect(theirsCard.resolution()?.choice == .renameTakeTheirs)
    }

    @Test func bothDeletedKindIsReadOnlyWithAnExplanation() throws {
        let pane = ResolvePaneModel(pending: pending())
        pane.attachDetails(
            originPath: "/repos/a",
            details: [ResolveCardData(path: "Old.swift", kind: .bothDeleted)])
        let card = try card(pane, path: "Old.swift")
        guard case .readOnly(let explanation) = card.kind else {
            Issue.record("a both-deleted record must present read-only")
            return
        }
        #expect(!explanation.isEmpty)
        #expect(card.choices.isEmpty, "a kind the engine cannot resolve gets no fake choice")
        #expect(card.resolution() == nil)
        #expect(!pane.stage(card), "staging a read-only card refuses")
    }

    @Test func theComposedNoteRidesOnTheResolution() throws {
        let pane = ResolvePaneModel(pending: pending())
        pane.attachDetails(
            originPath: "/repos/a",
            details: [ResolveCardData(path: "A.swift", kind: .bothModified, oursText: "o", theirsText: "t")])
        let card = try card(pane, path: "A.swift")
        card.note = "keep ours; theirs was generated"
        let resolution = try #require(card.resolution())
        #expect(resolution.note == "keep ours; theirs was generated")
    }

    // MARK: - The pane's actions through the real store

    @Test func composedResolutionsReachTheStoreResolveAPI() async throws {
        let store = PendingResolveStore()
        let center = ResolveCenter(store: store)
        let box = OutcomeBox()
        let request = ResolveRequest(
            commonDir: "/repos/b/.git", pathspec: nil, timeoutSeconds: 3600)

        // The serving body's order: details delivered BEFORE registration —
        // the centre stashes them, and the pane consumes the stash at
        // creation.
        center.attachDetails(
            commonDir: request.commonDir,
            originPath: "/repos/a",
            details: [
                ResolveCardData(path: "A.swift", kind: .bothModified, oursText: "o", theirsText: "t"),
                ResolveCardData(path: "B.swift", kind: .bothAdded, oursText: "o", theirsText: "t"),
            ],
            errorMessage: nil)

        let waiter = Task { box.set(await store.awaitDecision(for: request)) }
        try await waitUntil { center.panes.count == 1 }
        let pane = try #require(center.panes.first)
        #expect(pane.cards.count == 2, "the stash was consumed at registration")

        try card(pane, path: "A.swift").selectedChoice = .useTheirs
        try card(pane, path: "B.swift").selectedChoice = .editedContent
        try card(pane, path: "B.swift").editorText = "merged text"

        #expect(pane.submit(), "the pending was there to receive the reply")
        let outcome = try #require(await waitOrTimeout(box))
        #expect(outcome == .decided(.resolutions([
            PathResolution(path: "A.swift", kind: .bothModified, choice: .useTheirs),
            PathResolution(path: "B.swift", kind: .bothAdded, choice: .editedContent, editedContent: "merged text"),
        ])))
        try await waitUntil { center.panes.isEmpty }
        #expect(!pane.submit(), "a decided pane composes no second reply")
        _ = waiter
    }

    @Test func stagingOneCardLeavesTheOthersPending() async throws {
        let store = PendingResolveStore()
        let center = ResolveCenter(store: store)
        let log = ApplyLog()
        center.applyResolution = { _, resolution in try log.record(resolution) }

        let request = ResolveRequest(
            commonDir: "/repos/partial/.git", pathspec: nil, timeoutSeconds: 3600)
        let waiter = Task { _ = await store.awaitDecision(for: request) }
        try await waitUntil { center.panes.count == 1 }
        let pane = try #require(center.panes.first)
        pane.attachDetails(
            originPath: "/repos/partial",
            details: [
                ResolveCardData(path: "A.swift", kind: .bothModified, oursText: "o", theirsText: "t"),
                ResolveCardData(path: "B.swift", kind: .bothAdded, oursText: "o", theirsText: "t"),
            ],
            errorMessage: nil)

        #expect(pane.stage(try card(pane, path: "A.swift")))
        #expect(log.count == 1, "exactly one card's apply ran")
        #expect(log.entries.first?.choice == .useOurs)
        #expect(log.entries.first?.path == "A.swift")
        #expect(try card(pane, path: "A.swift").staged)
        #expect(!(try card(pane, path: "B.swift")).staged, "the other card is still open")
        #expect(store.pendingResolves.count == 1, "staging does not end the request")

        // An already-staged card must not re-apply — the path is no longer
        // conflicted, and the engine would refuse it.
        #expect(pane.stage(try card(pane, path: "A.swift")))
        #expect(log.count == 1)
        _ = waiter
    }

    @Test func aFailedStageNeverResolvesThePending() async throws {
        let store = PendingResolveStore()
        let center = ResolveCenter(store: store)
        let log = ApplyLog()
        log.armFailure()
        center.applyResolution = { _, resolution in
            try log.record(resolution)
        }

        let request = ResolveRequest(
            commonDir: "/repos/fail/.git", pathspec: nil, timeoutSeconds: 3600)
        let waiter = Task { _ = await store.awaitDecision(for: request) }
        try await waitUntil { center.panes.count == 1 }
        let pane = try #require(center.panes.first)
        pane.attachDetails(
            originPath: "/repos/fail",
            details: [ResolveCardData(path: "A.swift", kind: .bothModified, oursText: "o", theirsText: "t")],
            errorMessage: nil)

        let cardA = try card(pane, path: "A.swift")
        #expect(!pane.stage(cardA))
        #expect(cardA.stageError != nil, "the refusal is what renders")
        #expect(!cardA.staged)
        #expect(store.pendingResolves.count == 1, "a failed apply never resolves the pending")

        #expect(pane.stage(cardA), "the human can retry after a refusal")
        #expect(cardA.stageError == nil)
        #expect(log.count == 2)
        _ = waiter
    }

    @Test func submitCarriesEveryPathsResolutionStagedOrNot() async throws {
        let store = PendingResolveStore()
        let center = ResolveCenter(store: store)
        let log = ApplyLog()
        center.applyResolution = { _, resolution in try log.record(resolution) }

        let request = ResolveRequest(
            commonDir: "/repos/submit/.git", pathspec: nil, timeoutSeconds: 3600)
        let box = OutcomeBox()
        let waiter = Task { box.set(await store.awaitDecision(for: request)) }
        try await waitUntil { center.panes.count == 1 }
        let pane = try #require(center.panes.first)
        pane.attachDetails(
            originPath: "/repos/submit",
            details: [
                ResolveCardData(path: "A.swift", kind: .bothModified, oursText: "o", theirsText: "t"),
                ResolveCardData(path: "B.swift", kind: .deletedByUs, oursText: nil, theirsText: "t"),
            ],
            errorMessage: nil)

        // Card A stages; card B stays open. Submit still carries B — the
        // reply is the record of everything composed, and the
        // conflicts-remaining re-check is what reports what did not stage.
        try card(pane, path: "A.swift").selectedChoice = .useTheirs
        #expect(pane.stage(try card(pane, path: "A.swift")))
        try card(pane, path: "B.swift").selectedChoice = .keepModification
        try card(pane, path: "B.swift").note = "kept theirs' work"

        #expect(pane.submit())
        let outcome = try #require(await waitOrTimeout(box))
        #expect(outcome == .decided(.resolutions([
            PathResolution(path: "A.swift", kind: .bothModified, choice: .useTheirs),
            PathResolution(path: "B.swift", kind: .deletedByUs, choice: .keepModification, note: "kept theirs' work"),
        ])))
        _ = waiter
    }

    @Test func cancelStagesNothingAndReturnsCancelled() async throws {
        let store = PendingResolveStore()
        let center = ResolveCenter(store: store)
        let log = ApplyLog()
        center.applyResolution = { _, resolution in try log.record(resolution) }

        let request = ResolveRequest(
            commonDir: "/repos/cancel/.git", pathspec: nil, timeoutSeconds: 3600)
        let box = OutcomeBox()
        let waiter = Task { box.set(await store.awaitDecision(for: request)) }
        try await waitUntil { center.panes.count == 1 }
        let pane = try #require(center.panes.first)
        pane.attachDetails(
            originPath: "/repos/cancel",
            details: [
                ResolveCardData(path: "A.swift", kind: .bothModified, oursText: "o", theirsText: "t"),
                ResolveCardData(path: "B.swift", kind: .bothAdded, oursText: "o", theirsText: "t"),
            ],
            errorMessage: nil)

        try card(pane, path: "A.swift").selectedChoice = .useTheirs
        try card(pane, path: "B.swift").selectedChoice = .editedContent

        #expect(pane.cancel())
        #expect(log.count == 0, "cancel stages nothing — the apply seam is never called")
        let outcome = try #require(await waitOrTimeout(box))
        #expect(outcome == .decided(.cancelled), "cancel is a decided cancellation, not a resolution reply")
        try await waitUntil { center.panes.isEmpty }
        _ = waiter
    }

    @Test func aTypedOutcomeDisablesThePane() throws {
        let pane = ResolvePaneModel(pending: pending())
        pane.attachDetails(
            originPath: "/repos/a",
            details: [ResolveCardData(path: "A.swift", kind: .bothModified, oursText: "o", theirsText: "t")],
            errorMessage: nil)

        pane.recordOutcome(.timedOut)
        #expect(pane.outcomeLabel == "This resolve timed out before a decision was made.")
        #expect(!pane.decisionsEnabled)
        #expect(!pane.submit(), "a timed-out pane composes no reply")
        #expect(!pane.cancel())
        #expect(!pane.stage(try #require(pane.cards.first)))

        pane.recordOutcome(.superseded)
        #expect(pane.outcomeLabel == "This resolve was superseded by a newer request for the same repository.")
    }

    @Test func untrustedContentIsCarriedVerbatim() throws {
        let ours = "<<<<<<< HEAD\nours line\n=======\ntheirs line\n>>>>>>> feature\n"
        let base = "base\n"
        let theirs = "theirs\n"
        let pane = ResolvePaneModel(pending: pending())
        pane.attachDetails(
            originPath: "/repos/a",
            details: [ResolveCardData(
                path: "C.swift",
                kind: .bothModified,
                baseText: base,
                oursText: ours,
                theirsText: theirs)])
        let card = try card(pane, path: "C.swift")

        // The texts ride through the model byte for byte — nothing along
        // the delivery path interprets or rewrites them.
        #expect(card.sides.map(\.label) == ["Ours", "Base", "Theirs"])
        let side = try #require(card.sides.first(where: { $0.label == "Ours" }))
        #expect(side.text == ours, "blob content carried verbatim, conflict markers included")

        // The rendering path wraps each line verbatim as a context line of
        // the #0082 diff — the marker prefix is the renderer's, the text
        // after it is the blob's own line, uninterpreted.
        let diff = ResolveCardView.sideDiff(label: "Ours", path: "C.swift", text: ours)
        let lines = try #require(diff.hunks.first?.body)
        #expect(!lines.isEmpty)
        #expect(lines == ours.split(separator: "\n", omittingEmptySubsequences: false).map { " \($0)" })
        #expect(lines.contains(" <<<<<<< HEAD"), "conflict markers stay visible in the render source")
    }

    // MARK: - Helpers

    /// Bounded wait for the box's outcome, returning the moment it lands.
    private func waitOrTimeout(_ box: OutcomeBox, timeout: Duration = .seconds(300)) async throws -> ResolveOutcome {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let outcome = box.outcome { return outcome }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitTimeout()
    }
}
