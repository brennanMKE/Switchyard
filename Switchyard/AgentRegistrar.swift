// AgentRegistrar.swift
//
// Ported from ../../RemoteControl/RemoteControl/AgentRegistrar.swift (MIT,
// same author — see CLAUDE.md and issue #0049's planning update). Copyright
// the original author; substantial portions retained here under the same
// MIT terms as this project.

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

    /// `plistName` is resolved relative to `Contents/Library/LaunchAgents/`, so
    /// this is a bare filename, not a path.
    private let service = SMAppService.agent(plistName: ServiceNames.agentPlistName)

    private(set) var status: SMAppService.Status

    init() {
        status = service.status
    }

    /// Re-reads the status from the system.
    ///
    /// Worth calling on every activation: the user may have just flipped the
    /// switch in System Settings, and there is no notification for that.
    func refreshStatus() {
        let previous = status
        status = service.status
        if previous != status {
            Self.logger.info("status \(previous.label, privacy: .public) → \(self.status.label, privacy: .public)")
        }
    }

    /// Registers the agent, treating an already-registered service as success.
    func registerIfNeeded() {
        refreshStatus()

        guard status != .enabled else {
            Self.logger.info("already enabled — launchd owns \(ServiceNames.machServiceName, privacy: .public)")
            return
        }

        do {
            try service.register()
            refreshStatus()
            switch status {
            case .enabled:
                Self.logger.info("registered — launchd owns \(ServiceNames.machServiceName, privacy: .public)")
            case .requiresApproval:
                Self.logger.notice(
                    "registered but awaiting approval — enable \"\(ServiceNames.appName, privacy: .public)\" under System Settings → General → Login Items & Extensions"
                )
            default:
                Self.logger.notice("registered but status is \(self.status.label, privacy: .public)")
            }
        } catch {
            // Registering an already-registered service throws rather than
            // succeeding quietly, so this is not necessarily a real failure.
            refreshStatus()
            let message = error.localizedDescription
            if status == .enabled {
                Self.logger.info("already registered (register() threw: \(message, privacy: .public))")
            } else {
                Self.logger.error("register() failed: \(message, privacy: .public) [status \(self.status.label, privacy: .public)]")
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

        do {
            try service.unregister()
        } catch {
            // Expected when launchd has already lost the job. Not fatal — the
            // point of this call is to clear whatever state does exist.
            Self.logger.info("unregister during repair: \(error.localizedDescription, privacy: .public)")
        }
        refreshStatus()

        do {
            try service.register()
            refreshStatus()
            Self.logger.info("re-registered — status \(self.status.label, privacy: .public)")
        } catch {
            refreshStatus()
            Self.logger.error("re-registration failed: \(error.localizedDescription, privacy: .public) [status \(self.status.label, privacy: .public)]")
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
        Self.logger.info("opened System Settings → Login Items & Extensions")
    }
}

extension SMAppService.Status {
    var label: String {
        switch self {
        case .notRegistered: "Not registered"
        case .enabled: "Enabled"
        case .requiresApproval: "Requires approval"
        case .notFound: "Not found"
        @unknown default: "Unknown (\(rawValue))"
        }
    }

    /// Whether the CLI has any chance of reaching the broker in this state.
    var isOperational: Bool {
        self == .enabled
    }
}
