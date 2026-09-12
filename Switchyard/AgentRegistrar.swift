// AgentRegistrar.swift
//
// Ported from ../../RemoteControl/RemoteControl/AgentRegistrar.swift (MIT,
// same author — see CLAUDE.md and issue #0049's planning update). Copyright
// the original author; substantial portions retained here under the same
// MIT terms as this project.
//
// #0354: all `SMAppService` work routes through `BrokerAgentController`,
// which captures every failure's text and publishes the four-state
// registration mapping — surfaced to the transport pane through the
// `TransportStatusBridge`, never again only logged.

import Foundation
import ServiceManagement
import YardKit
import os

/// Registers the embedded broker launch agent with launchd.
///
/// Embedding the plist in the bundle is not enough on its own — launchd only
/// learns about the agent when the app calls `SMAppService.register()`. And
/// registration is not necessarily immediate: macOS may park it in
/// `requiresApproval` until the user enables the item under System Settings →
/// General → Login Items & Extensions. So the status is surfaced rather than
/// assumed, because "the CLI can't connect" and "you haven't approved the login
/// item yet" look identical from the terminal.
@MainActor
final class AgentRegistrar {
    private static let logger = Logger(subsystem: ServiceNames.logSubsystem, category: "agent")

    /// The controller owns the service handle, the state mapping, and the
    /// captured error text. Injectable for tests; the default resolves the
    /// embedded agent's plist from `ServiceNames`.
    private let controller: BrokerAgentController

    /// The registration state to surface — the controller's published
    /// value, refreshed on every call below.
    var state: BrokerAgentRegistrationState { controller.state }

    /// The captured text of the last failed register/unregister, if any —
    /// the pane's error row, not just a log line.
    var lastErrorDescription: String? { controller.lastErrorDescription }

    convenience init() {
        self.init(controller: BrokerAgentController())
    }

    init(controller: BrokerAgentController) {
        self.controller = controller
    }

    /// Re-reads the status from the system.
    ///
    /// Worth calling on every activation: the user may have just flipped the
    /// switch in System Settings, and there is no notification for that.
    func refreshStatus() {
        let previous = state
        controller.refresh()
        if previous != state {
            Self.logger.info("status \(previous.label, privacy: .public) → \(self.state.label, privacy: .public)")
        }
    }

    /// Registers the agent, treating an already-registered service as success.
    func registerIfNeeded() {
        refreshStatus()

        guard state != .enabled else {
            Self.logger.info("already enabled — launchd owns \(ServiceNames.machServiceName, privacy: .public)")
            return
        }

        controller.register()
        switch state {
        case .enabled:
            Self.logger.info("registered — launchd owns \(ServiceNames.machServiceName, privacy: .public)")
        case .requiresApproval:
            Self.logger.notice(
                "registered but awaiting approval — enable \"\(ServiceNames.appName, privacy: .public)\" under System Settings → General → Login Items & Extensions"
            )
        case .notRegistered, .unknown:
            if let message = controller.lastErrorDescription {
                Self.logger.error("register() did not take effect: \(message, privacy: .public) [status \(self.state.label, privacy: .public)]")
            } else {
                Self.logger.notice("registered but status is \(self.state.label, privacy: .public)")
            }
        }
    }

    /// Forces a re-registration by unregistering first.
    ///
    /// Needed because `SMAppService.status` can report `.enabled` while launchd
    /// has no such service — the two views genuinely disagree after a
    /// `launchctl bootout`, and possibly after other Background Task Management
    /// upsets. In that state `registerIfNeeded()` short-circuits on `.enabled`
    /// and the app can never repair itself, so the only way out is to stop
    /// trusting the status and re-register unconditionally.
    func repair() {
        Self.logger.notice("re-registering agent (unregister, then register)")

        controller.unregister()
        // Expected when launchd has already lost the job. Not fatal — the
        // point of this call is to clear whatever state does exist. The
        // captured text (if any) is logged here; the re-register below
        // either clears it on success or replaces it with its own.
        if let message = controller.lastErrorDescription {
            Self.logger.info("unregister during repair: \(message, privacy: .public)")
        }

        controller.register()
        Self.logger.info("re-registered — status \(self.state.label, privacy: .public)")
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
        Self.logger.info("opened System Settings → Login Items & Extensions")
    }
}
