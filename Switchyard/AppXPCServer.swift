// AppXPCServer.swift
//
// Ported from ../../RemoteControl/RemoteControl/AppXPCServer.swift (MIT,
// same author — see CLAUDE.md and issue #0047's planning update). Copyright
// the original author; substantial portions retained here under the same
// MIT terms as this project.
//
// Scoped to the anonymous listener and broker registration only. Serving
// accepted connections, long-lived sessions, heartbeats, teardown, and
// orphan reaping are #0213 — this file does not implement any of them.

import AppKit
import Foundation
import YardCommands
import YardKit
import YardUI
import os

/// The app's side of the direct CLI connection.
///
/// The app publishes an *anonymous* listener — it cannot publish a named
/// one, which is the entire reason the broker agent exists — and hands the
/// resulting endpoint to the broker. A CLI then asks the broker for that
/// endpoint and connects straight to the app. Nothing after the handoff
/// travels through the broker.
@MainActor
final class AppXPCServer {
    private static let logger = Logger(subsystem: ServiceNames.logSubsystem, category: "xpc")

    /// Anonymous listener. A named `NSXPCListener(machServiceName:)` would
    /// fail here: only launchd can own a service name.
    private let listener = NSXPCListener.anonymous()

    /// Must be held strongly — `NSXPCListener.delegate` is weak, and a
    /// delegate that is only locally owned is deallocated and connections
    /// are silently refused.
    private var listenerDelegate: ListenerDelegate?

    /// The app's connection to the broker, kept open for the process
    /// lifetime so the broker can detect the app going away and drop the
    /// stale endpoint.
    private var brokerConnection: NSXPCConnection?

    /// Claimed the first time the broker connection's error handler observes
    /// an actual failure, so repair runs at most once per launch.
    ///
    /// `nonisolated` and backed by a lock (see `RepairGate`), not an actor:
    /// the error handler closure below is `@Sendable` and fires on XPC's own
    /// queue, not the main actor, so the claim must be checkable synchronously
    /// from there without a hop.
    nonisolated private let repairGate = RepairGate()

    /// Runs the agent repair (unregister + re-register with `SMAppService`).
    /// Set by whoever owns the `AgentRegistrar` — `AppXPCServer` has no
    /// dependency on `ServiceManagement` itself, so it stays testable without
    /// one. Called at most once per launch, driven by `repairGate`.
    var repairHandler: (() -> Void)?

    /// The app's pending reviews (#0055) — one per repository, replaceable,
    /// each armed with its own timeout. Owned by the server so every accepted
    /// CLI connection shares one store (a pending review is not per-connection
    /// state) and round 2's sheet can bind to the same instance.
    private let pendingReviews = PendingReviewStore()

    /// The app's pending asks (#0056) — one FIFO queue per repository, the
    /// head presented and armed with its own timeout. Owned by the server
    /// for the same reason as `pendingReviews`: a pending ask is not
    /// per-connection state, and the sheet binds to the same instance.
    private let pendingAsks = PendingAskStore()

    /// The app's pending resolves (#0057) — one per repository, replaceable
    /// (the review semantics, not ask's queue), each armed with its own
    /// timeout. Owned by the server for the same reason as `pendingReviews`.
    private let pendingResolves = PendingResolveStore()

    /// #0055 round 2: the review sheet's bridge, over the same store. The
    /// app delegate hands `reviewBridge.center` to `ContentView`; the
    /// delegate threads the bridge into each `AppService` so a review
    /// request's diff reaches the sheet.
    let reviewBridge: ReviewSheetBridge

    /// #0056: the ask sheet's bridge, over the ask store — the same shape
    /// as `reviewBridge`.
    let askBridge: AskSheetBridge

    init() {
        reviewBridge = ReviewSheetBridge(store: pendingReviews)
        askBridge = AskSheetBridge(store: pendingAsks)
    }

    /// The store behind `reviewBridge` — what `ListenerDelegate` threads
    /// into each `AppService`.
    var pendingReviewStore: PendingReviewStore { pendingReviews }

    /// The store behind `askBridge` — what `ListenerDelegate` threads into
    /// each `AppService`.
    var pendingAskStore: PendingAskStore { pendingAsks }

    /// The store behind the resolve pane (round 2, #0057) — what
    /// `ListenerDelegate` threads into each `AppService`.
    var pendingResolveStore: PendingResolveStore { pendingResolves }

    // MARK: - Lifecycle

    /// Resumes the anonymous listener.
    ///
    /// Accepting a connection is declined for now — exporting a real service
    /// interface to accepted CLIs is #0213. The listener still needs to be
    /// live so its `endpoint` is a real, resumed one by the time it is
    /// handed to the broker.
    func start() {
        let delegate = ListenerDelegate(
            pendingReviews: pendingReviews,
            pendingAsks: pendingAsks,
            pendingResolves: pendingResolves,
            reviewBridge: reviewBridge,
            askBridge: askBridge)
        listenerDelegate = delegate
        listener.delegate = delegate
        listener.resume()
        Self.logger.info("anonymous listener resumed")
    }

    // MARK: - Broker registration

    /// Hands the anonymous listener's endpoint to the broker.
    ///
    /// Called at launch and again whenever the broker connection is
    /// interrupted. The broker can be killed and restarted independently of
    /// the app, and an endpoint registered with a dead broker is worth
    /// nothing, so re-registering is not optional.
    func registerWithBroker() {
        // Reuse the existing connection if there is one: after an
        // *interruption* the connection object is still usable, and
        // recreating it needlessly loses the invalidation handler wiring.
        let connection = brokerConnection ?? makeBrokerConnection()

        // `@Sendable` is load-bearing, not decoration. Foundation types this
        // parameter as a plain `(any Error) -> Void`, so a closure written
        // inside this @MainActor method inherits main-actor isolation and
        // Swift emits an isolation assertion at its entry. XPC then calls it
        // on its own queue and the process dies with SIGTRAP in
        // _swift_task_checkIsolatedSwift. Marking the closure @Sendable
        // makes it nonisolated, which is what it must be.
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in
                Self.logger.error("broker connection error: \(message, privacy: .public)")
            }

            // This is where a *failed call* is actually observed — repair is
            // driven from here, at most once per launch, never from
            // `service.status`. The claim itself must happen synchronously,
            // on whatever queue XPC calls this on, so two overlapping
            // failures cannot both win it.
            guard let self, self.repairGate.claim() else { return }
            Task { @MainActor [weak self] in
                Self.logger.notice("broker call failed — repairing agent registration")
                self?.repairHandler?()
                self?.registerWithBroker()
            }
        }

        guard let broker = proxy as? BrokerProtocol else {
            Self.logger.error("broker proxy does not conform to BrokerProtocol")
            return
        }

        // registerAppEndpoint is a one-way call: no reply block, so it
        // returns immediately whether or not the broker received it, and
        // failures only surface asynchronously through the error handler
        // above. Do not treat a successful return here as proof that
        // registration happened.
        broker.registerAppEndpoint(listener.endpoint)
        Self.logger.info("endpoint handed to broker")
    }

    private func makeBrokerConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: ServiceNames.machServiceName)
        // Set before resume(), or calls silently do nothing.
        connection.remoteObjectInterface = XPCInterfaces.broker

        // Interruption: the broker died but this connection object can be
        // reused. Re-register, because the restarted broker has an empty
        // registry.
        //
        // @Sendable for the same reason as the error handler above — these
        // are plain `() -> Void` in Foundation, and without it they inherit
        // main-actor isolation and trap when XPC calls them off the main
        // queue.
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                Self.logger.notice("broker connection interrupted, re-registering")
                self?.registerWithBroker()
            }
        }

        // Invalidation: permanently dead. The connection object cannot be
        // reused, so drop it; the next registerWithBroker() builds a fresh
        // one.
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                Self.logger.notice("broker connection invalidated")
                self?.brokerConnection = nil
            }
        }

        connection.resume()
        brokerConnection = connection
        return connection
    }
}

// MARK: - Listener delegate

/// `nonisolated` because XPC invokes this on its own queues, and the app
/// target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
private nonisolated final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let pendingReviews: PendingReviewStore
    private let pendingAsks: PendingAskStore
    private let pendingResolves: PendingResolveStore
    private let reviewBridge: ReviewSheetBridge
    private let askBridge: AskSheetBridge

    init(
        pendingReviews: PendingReviewStore,
        pendingAsks: PendingAskStore,
        pendingResolves: PendingResolveStore,
        reviewBridge: ReviewSheetBridge,
        askBridge: AskSheetBridge
    ) {
        self.pendingReviews = pendingReviews
        self.pendingAsks = pendingAsks
        self.pendingResolves = pendingResolves
        self.reviewBridge = reviewBridge
        self.askBridge = askBridge
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // Both must be set BEFORE resume(), or calls silently do nothing — no
        // error, no reply, no crash. Same rule as the client side.
        connection.exportedInterface = XPCInterfaces.appService
        connection.exportedObject = AppService(
            pendingReviews: pendingReviews,
            pendingAsks: pendingAsks,
            pendingResolves: pendingResolves,
            reviewBridge: reviewBridge,
            askBridge: askBridge)
        connection.resume()
        return true
    }
}

// MARK: - Exported service

/// The object exported to an accepted CLI connection.
///
/// One instance per accepted connection: `ListenerDelegate` creates one each
/// time `shouldAcceptNewConnection` fires, the connection retains it as its
/// `exportedObject`, and it is released when that connection invalidates. No
/// session state lives here — that is #0213, deliberately after this.
///
/// `nonisolated` for the same reason as `ListenerDelegate`: XPC reaches this
/// object on its own queues, not the main actor, and the app target compiles
/// with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
private nonisolated final class AppService: NSObject, AppServiceProtocol {
    private static let logger = Logger(
        subsystem: ServiceNames.logSubsystem, category: "app-service")

    /// The server's shared pending-review store, threaded through the
    /// delegate. All accepted connections register into the same store.
    private let pendingReviews: PendingReviewStore

    /// The server's shared pending-ask store (#0056) — same discipline.
    private let pendingAsks: PendingAskStore

    /// The server's shared pending-resolve store (#0057) — same discipline.
    private let pendingResolves: PendingResolveStore

    /// #0055 round 2: delivers a registered request's resolved context and
    /// diff to the review sheets.
    private let reviewBridge: ReviewSheetBridge

    /// #0056: delivers a registered ask's resolved context to the ask
    /// sheets (tab routing only — an ask has no diff).
    private let askBridge: AskSheetBridge

    init(
        pendingReviews: PendingReviewStore,
        pendingAsks: PendingAskStore,
        pendingResolves: PendingResolveStore,
        reviewBridge: ReviewSheetBridge,
        askBridge: AskSheetBridge
    ) {
        self.pendingReviews = pendingReviews
        self.pendingAsks = pendingAsks
        self.pendingResolves = pendingResolves
        self.reviewBridge = reviewBridge
        self.askBridge = askBridge
        super.init()
    }

    func appPing(reply: @escaping @Sendable (String) -> Void) {
        // Bundle.main.infoDictionary is safe to read from any queue, so no
        // main-actor hop is needed here.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        reply(version ?? "unknown")
    }

    /// Forwards to `performCommand`, the single body both sides of the wire
    /// run — kept in `YardKit` so the package test suite exercises the exact
    /// bytes this app sends, rather than a copy that could drift from it.
    ///
    /// #0084: a request names its repository by its working directory, so
    /// the request also opens that repository through the SAME focus-or-open
    /// rule every other entry point uses (`RepositoryTabs.open(path:)`).
    /// When the repository has no tab yet, the new one attaches to the
    /// user's active window (`openInFrontmostWindow`), and the activation
    /// below brings the app's frontmost window forward — `NSApp.windows`
    /// ordering is only visible here, which is what makes this half
    /// app-target code, checked by #0054's manual script. The hop is
    /// fire-and-forget: the CLI's reply must not wait on UI work, and a
    /// refusal is logged rather than shown as a modal the user never asked
    /// for.
    func perform(
        arguments: [String],
        workingDirectory: String,
        reply: @escaping @Sendable (Data, Int32) -> Void
    ) {
        if !workingDirectory.isEmpty {
            Task { @MainActor in
                NSApp.activate()
                let outcome = RepositoryTabs.shared.openInFrontmostWindow(
                    path: workingDirectory,
                    windowStore: .shared
                )
                if case .refused(let path, let detail) = outcome {
                    Self.logger.error(
                        "XPC open refused for \(path, privacy: .public): \(detail, privacy: .public)")
                }
            }
        }
        // #0057: the engine-backed commands run here first — the composition
        // `EngineCommands.runEngineCommand` documents as the app's (`… ?? `
        // `runYard`), and the one the resolve arm's post-reply conflicts
        // re-check rides (`perform(arguments: ["conflicts"])`).
        if let engine = runEngineCommand(arguments: arguments, workingDirectory: workingDirectory) {
            reply(Data(engine.stdout.utf8), Int32(engine.exitCode.rawValue))
            return
        }
        let result = performCommand(arguments: arguments, workingDirectory: workingDirectory)
        reply(result.stdout, result.exitCode)
    }

    /// Forwards to `runReferenceTransactionHook` (YardCommands), the single
    /// body the package tests exercise — same pattern as `perform` above.
    /// The hook arm (#0154) connects with `launchIfNeeded: false`, so this
    /// only ever runs for an app that was already up, and the reply is the
    /// decision's exit code — 0 by #0042's totality invariant; the arm
    /// exits 0 regardless.
    func performReferenceTransactionHook(
        state: String,
        environment: [String: String],
        standardInput: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Int32) -> Void
    ) {
        reply(runReferenceTransactionHook(
            state: state,
            environment: environment,
            standardInput: standardInput,
            workingDirectory: workingDirectory))
    }

    /// Forwards to `runReviewRequest` (YardCommands), the single body the
    /// package tests exercise — same pattern as `perform` above. The reply
    /// may take minutes: the serving body runs on its own task and the reply
    /// block is called when the human decides, the pending review times out,
    /// or it is superseded — long after this method returns.
    func performReview(
        request: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Data) -> Void
    ) {
        let store = pendingReviews
        let bridge = reviewBridge
        Task {
            let outcomeData = await runReviewRequest(
                requestData: request,
                workingDirectory: workingDirectory,
                store: store,
                onPending: { requestData, context, files, errorMessage in
                    Task { @MainActor in
                        bridge.pendingDidRegister(
                            request: requestData,
                            context: context,
                            files: files,
                            errorMessage: errorMessage)
                    }
                })
            reply(outcomeData)
        }
    }

    /// Forwards to `runAskRequest` (YardCommands), the single body the
    /// package tests exercise — same pattern as `performReview` above. The
    /// reply may take minutes: the serving body runs on its own task and
    /// the reply block is called when the human answers the head of the
    /// repository's queue, the head times out — long after this method
    /// returns.
    func performAsk(
        request: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Data) -> Void
    ) {
        let store = pendingAsks
        let bridge = askBridge
        Task {
            let outcomeData = await runAskRequest(
                requestData: request,
                workingDirectory: workingDirectory,
                store: store,
                onPending: { requestData, context in
                    Task { @MainActor in
                        bridge.pendingDidRegister(request: requestData, context: context)
                    }
                })
            reply(outcomeData)
        }
    }

    /// Forwards to `runResolveRequest` (YardCommands), the single body the
    /// package tests exercise — same pattern as `performReview` above. The
    /// reply may take minutes: the serving body runs on its own task and the
    /// reply block is called when the human answers, the request times out,
    /// or it is superseded — long after this method returns.
    ///
    /// `onPending` is nil in round 1: the conflict details the serving body
    /// computes are delivered when the resolve pane's bridge lands (#0057
    /// round 2), the way `reviewBridge` was threaded in for #0055's sheet.
    func performResolve(
        request: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Data) -> Void
    ) {
        let store = pendingResolves
        Task {
            let outcomeData = await runResolveRequest(
                requestData: request,
                workingDirectory: workingDirectory,
                store: store)
            reply(outcomeData)
        }
    }
}
