// TransportStatus.swift
//
// #0216: shows a human what the XPC transport is doing — the Mach service
// name the broker publishes, the login-item status, whether the app's
// anonymous endpoint is currently registered with the broker, and how many
// CLI clients are connected. Two failures look identical from a terminal —
// the agent awaiting approval, and the app not running — and this pane
// exists to tell them apart.
//
// The model is VALUE-DRIVEN, and deliberately so: `SMAppService` cannot be
// touched from YardUI (ServiceManagement is app-target; a package test must
// be able to construct every pane state without the system ever being asked
// about the real agent, and no test may call `register()` — the model has
// no such method at all). The app target feeds the model from
// `AgentRegistrar.status` through a small adapter; see
// `Switchyard/TransportStatusBridge.swift`.

import SwiftUI
import YardKit

/// YardUI's own vocabulary for the login-item status, mirroring the four
/// cases of `SMAppService.Status` so no test — and no view — ever needs the
/// real type. `label` carries the exact wording the app target's
/// `SMAppService.Status.label` extension produces (#0049's vocabulary), so
/// the pane reads the same in both places.
///
/// `nonisolated` on purpose: this is stateless value vocabulary, and the
/// target's MainActor-by-default isolation would otherwise fence its
/// computed properties away from plain call sites and key paths.
nonisolated public enum AgentStatus: String, CaseIterable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case notFound

    /// Exact `SMAppService.Status.label` wording (see the extension at the
    /// bottom of the app target's `AgentRegistrar.swift`).
    public var label: String {
        switch self {
        case .notRegistered: "Not registered"
        case .enabled: "Enabled"
        case .requiresApproval: "Requires approval"
        case .notFound: "Not found"
        }
    }

    /// The pane shows "Open System Settings > Login Items" ONLY in this
    /// state — it is the one state a user action can resolve.
    public var showsApprovalButton: Bool {
        self == .requiresApproval
    }

    /// SF Symbol shown beside the status label. A string rather than an
    /// `Image` so it stays assertable without rendering anything.
    public var symbolName: String {
        switch self {
        case .notRegistered: "circle.slash"
        case .requiresApproval: "exclamationmark.triangle"
        case .enabled: "checkmark.circle"
        case .notFound: "questionmark.circle"
        }
    }
}

/// Everything the transport pane renders. Every property is settable so the
/// app can drive it live and a test can drive it to any state.
@Observable
public final class TransportStatusModel {
    /// The Mach service name the broker publishes. Defaults to the single
    /// source of truth; the pane renders it monospaced and selectable so a
    /// mismatch is legible and copyable.
    public var machServiceName: String

    /// The login-item status.
    public var agentStatus: AgentStatus

    /// Whether the app's anonymous endpoint is currently registered with
    /// the broker. The app writes this from the same place that hands the
    /// endpoint over (`AppXPCServer.registerWithBroker()`); nothing here
    /// guesses it.
    public var endpointRegistered: Bool

    /// How many CLI clients are connected. Carried as a plain settable
    /// value: the app's connection accounting does not export a count yet,
    /// so the model holds the value and the app-side adapter is the single
    /// wiring point.
    public var clientCount: Int

    /// The action behind the approval button. `@ObservationIgnored`: an
    /// action closure is not renderable state, and the app sets it once.
    /// The model never touches `SMAppService` itself — the app target
    /// supplies the closure that does.
    @ObservationIgnored public var openLoginItems: (() -> Void)?

    public init(
        machServiceName: String = ServiceNames.machServiceName,
        agentStatus: AgentStatus = .notRegistered,
        endpointRegistered: Bool = false,
        clientCount: Int = 0
    ) {
        self.machServiceName = machServiceName
        self.agentStatus = agentStatus
        self.endpointRegistered = endpointRegistered
        self.clientCount = clientCount
    }

    /// Endpoint wording. "Not registered" is the reading that pairs with
    /// "the CLI can't connect" — the pane's whole reason to exist.
    public var endpointLabel: String {
        endpointRegistered ? "Registered with the broker" : "Not registered"
    }

    /// Client wording: zero and several are DIFFERENT STATES, not a bare
    /// number — "None connected" is what a user checks first.
    public var clientCountLabel: String {
        clientCount == 0 ? "None connected" : "\(clientCount) connected"
    }
}

/// The pane itself: a pure function of the model. Semantic colours only —
/// `.green`/`.orange`/`.secondary` are adaptive system styles, so dark mode
/// needs nothing special and no `Color(red:...)` appears anywhere.
public struct TransportStatusPane: View {
    let model: TransportStatusModel

    public init(model: TransportStatusModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Transport")
                    .font(.headline)
                Spacer()
                Text(model.machServiceName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            row("Login item") {
                HStack(spacing: 4) {
                    Image(systemName: model.agentStatus.symbolName)
                        .foregroundStyle(tint)
                    Text(model.agentStatus.label)
                        .foregroundStyle(tint)
                }
            }
            if model.agentStatus.showsApprovalButton {
                Button("Open System Settings > Login Items") {
                    model.openLoginItems?()
                }
            }
            row("Endpoint") {
                Text(model.endpointLabel)
                    .foregroundStyle(model.endpointRegistered ? Color.primary : Color.secondary)
            }
            row("CLI clients") {
                Text(model.clientCountLabel)
                    .foregroundStyle(model.clientCount == 0 ? Color.secondary : Color.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Content: View>(
        _ name: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.callout)
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// Adaptive system colours only: `.green`/`.orange`/`.secondary` track
    /// the colour scheme, so this needs no dark-mode special-casing.
    private var tint: Color {
        switch model.agentStatus {
        case .enabled: .green
        case .requiresApproval: .orange
        case .notRegistered, .notFound: .secondary
        }
    }
}
