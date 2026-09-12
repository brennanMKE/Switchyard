// BrokerAgentController.swift
//
// Adapted from BattyKit/Sources/BattyKit/Settings/BrokerAgentController.swift
// (MIT License — Copyright 2026 Brennan Stehling), per Switchyard issue
// #0354. The four-state mapping and the controller shape carry over; the
// injected service seam, the logger, and the service resolution are
// Switchyard's own.

import ServiceManagement
import YardKit
import os

/// The broker agent's registration state, mapped from `SMAppService.Status`
/// through a pure function — the part that actually varies and is worth
/// testing, kept independent of `SMAppService` itself.
///
/// Deliberately *not* named or presented as a health state. `SMAppService
/// .status` can report `.enabled` while launchd has no such service
/// (observed directly in Batty after a `launchctl bootout`, and the
/// 2026-09-11 Switchyard demo failure ran the same shape the other way:
/// every log line said nothing was wrong while `launchctl print` could not
/// find the service at all). A broker round trip (ping) is the only thing
/// allowed to claim the broker is actually reachable — see
/// `TransportStatusModel.brokerPingSucceeded`. This type only ever
/// describes what `SMAppService` believes about registration.
///
/// `nonisolated` on purpose: this is stateless value vocabulary, and the
/// target's MainActor-by-default isolation would otherwise fence its
/// conformance away from plain call sites (and #expect's macro) — the same
/// shape YardUI's `AgentStatus` takes.
nonisolated enum BrokerAgentRegistrationState: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case unknown

    init(status: SMAppService.Status) {
        switch status {
        case .notRegistered, .notFound:
            self = .notRegistered
        case .requiresApproval:
            self = .requiresApproval
        case .enabled:
            self = .enabled
        @unknown default:
            self = .unknown
        }
    }

    /// Log wording, mirroring the `SMAppService.Status.label` vocabulary the
    /// registrar has always used, so a log line reads the same before and
    /// after #0354.
    var label: String {
        switch self {
        case .notRegistered: "Not registered"
        case .requiresApproval: "Requires approval"
        case .enabled: "Enabled"
        case .unknown: "Unknown"
        }
    }
}

/// The slice of `SMAppService` the controller needs, as a protocol so a
/// test can inject a service whose calls throw. Batty tests only the pure
/// mapping; Switchyard adds this seam so the error-capture behaviour — the
/// surfacing whose absence left #0354's failure invisible — is testable
/// without launchd ever being touched.
protocol AgentServiceServicing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

/// The real service handle for the embedded broker agent's plist.
struct SystemAgentService: AgentServiceServicing {
    private let service: SMAppService

    /// `plistName` is resolved relative to `Contents/Library/LaunchAgents/`,
    /// so this is a bare filename, not a path.
    init(plistName: String) {
        self.service = SMAppService.agent(plistName: plistName)
    }

    var status: SMAppService.Status { service.status }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}

/// Thin wrapper around `SMAppService.agent(plistName:)` for the broker
/// agent, plus a status the UI can bind to (through the transport bridge).
/// Registration and status belief only — whether the broker is actually
/// reachable is a ping question, never this type's answer.
///
/// Every failed `register()`/`unregister()` is captured in
/// `lastErrorDescription` for the UI, not only logged: #0354's failure was
/// invisible precisely because the diagnostics stopped at `os_log`.
@MainActor
@Observable
final class BrokerAgentController {
    private static let logger = Logger(subsystem: ServiceNames.logSubsystem, category: "broker-agent")

    /// What `SMAppService` currently believes about registration. Refreshed
    /// at construction, after every register/unregister call, and whenever
    /// `refresh()` runs.
    private(set) var state: BrokerAgentRegistrationState = .unknown

    /// `error.localizedDescription` from the last failed call, cleared on
    /// success. The pane's diagnosis text when the state is not healthy.
    private(set) var lastErrorDescription: String?

    private let service: any AgentServiceServicing

    /// The real service for the embedded agent's plist.
    convenience init() {
        self.init(service: SystemAgentService(plistName: ServiceNames.agentPlistName))
    }

    /// The injected seam for tests.
    init(service: any AgentServiceServicing) {
        self.service = service
        refresh()
    }

    /// Re-reads the status from the system into `state`.
    ///
    /// Worth calling on every activation: the user may have just flipped the
    /// switch in System Settings, and there is no notification for that.
    func refresh() {
        state = BrokerAgentRegistrationState(status: service.status)
    }

    /// Registers the agent, capturing any failure's text.
    ///
    /// Registering an already-registered service throws rather than
    /// succeeding quietly. When the post-throw status reads `.enabled`, that
    /// throw is the benign already-registered case — kept from the
    /// registrar's pre-#0354 rule — so `lastErrorDescription` stays empty
    /// and the pane never shows a phantom error next to "Enabled".
    func register() {
        do {
            try service.register()
            lastErrorDescription = nil
            Self.logger.info("broker agent register() succeeded")
        } catch {
            refresh()
            if state == .enabled {
                lastErrorDescription = nil
                Self.logger.info("already registered (register() threw: \(error.localizedDescription, privacy: .public))")
            } else {
                lastErrorDescription = error.localizedDescription
                Self.logger.error("broker agent register() failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        refresh()
    }

    /// Unregisters the agent, capturing any failure's text.
    func unregister() {
        do {
            try service.unregister()
            lastErrorDescription = nil
            Self.logger.info("broker agent unregister() succeeded")
        } catch {
            lastErrorDescription = error.localizedDescription
            Self.logger.error("broker agent unregister() failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }
}
