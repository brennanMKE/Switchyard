// SettingsView.swift
//
// #0352: the Settings scene (Cmd-,) — the CLI install state, the broker
// status, and the app version in one place. A user diagnosing "why does
// `switchyard` not work" reads the answer here without touring the File
// menu and the transport pane; the 2026-09-11 demo failure (#0354) had no
// surface that said so.
//
// The CLI row's shape and the four-state presentation idiom are adapted
// from BattyKit/Sources/BattyKit/Views/SettingsView.swift (MIT License —
// Copyright 2026 Brennan Stehling); this notice is retained for the
// adapted portions. Nothing of the machinery is Batty's: the inspection is
// the package's `CLIInstaller`, the actions are `CLIInstallActions` (#0222
// — the same ones the File-menu items funnel through), and the broker half
// binds the transport pane's own `TransportStatusModel` — the SAME
// observables the pane binds, never a second controller reading
// SMAppService in parallel.
//
// The state→presentation mapping lives in YardUI's `SettingsPresentation`
// (pure, package-tested); the About section's bundle-derived version line
// is app-target and lives in `AboutPresentation` below.

import SwiftUI
import YardKit
import YardUI

struct SettingsView: View {
    /// The transport pane's own model — the same instance `ContentView`'s
    /// transport disclosure binds. One source of truth: a registration
    /// refresh or a broker ping written by the bridge shows on both
    /// surfaces at once. Nothing here reads `SMAppService` directly.
    let transport: TransportStatusModel

    /// The bridge's refresh, injected by the app so opening the window
    /// re-reads the registrar — the user may have just approved the login
    /// item, and there is no notification for that. `nil` in tests.
    let refreshOnAppear: (() -> Void)?

    init(transport: TransportStatusModel, refreshOnAppear: (() -> Void)? = nil) {
        self.transport = transport
        self.refreshOnAppear = refreshOnAppear
    }

    var body: some View {
        Form {
            Section("Command Line Tool") {
                CLIInstallRow()
            }
            Section("Broker") {
                BrokerStatusRow(model: transport)
            }
            Section("About") {
                Text(AboutPresentation.versionText(bundleInfo: Bundle.main.infoDictionary))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 480, minHeight: 320)
        .onAppear { refreshOnAppear?() }
    }
}

// MARK: - CLI install section

/// The four-state inspection rendered as Install/Uninstall. The state is
/// inspected on appear and re-inspected after every act; the controls' logic
/// is `SettingsPresentation`'s (package-tested), the acts are
/// `CLIInstallActions`' — the same machinery the File-menu items use, so
/// the two surfaces can never diverge on what install/uninstall does.
private struct CLIInstallRow: View {
    /// The four-state inspection. `nil` until the first inspection — a
    /// placeholder covers that window rather than claiming a state.
    @State private var state: CLIInstaller.State?

    private var installDestination: URL {
        URL(filePath: ServiceNames.cliInstallPath, directoryHint: .notDirectory)
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ServiceNames.cliName)
                Text("Symlinks \(ServiceNames.cliName) to \(ServiceNames.cliInstallPath). Not required to run Switchyard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let state {
                    Text(SettingsPresentation.cliStatusText(for: state))
                    if let detail = SettingsPresentation.cliDetailText(
                        for: state, installPath: ServiceNames.cliInstallPath)
                    {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(captionColour(for: state))
                            .textSelection(.enabled)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                // The durability gate (#0353): when THIS bundle would
                // produce a doomed link, the refusal renders inline before
                // any click — the same report the act presents as an alert,
                // so the diagnosis does not wait for a dialog that will
                // refuse anyway.
                if let refusal = CLIInstaller.installPreconditionReport(
                    bundle: Bundle.main.bundleURL, destination: installDestination)
                {
                    Text(refusal.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                    Text(refusal.detail)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if let state {
                if SettingsPresentation.showsInstallButton(for: state) {
                    // The ellipsis: the act opens a dialog before completing,
                    // the same convention the File-menu item carries.
                    Button("Install…") {
                        act { CLIInstallActions.install() }
                    }
                }
                if SettingsPresentation.showsUninstallButton(for: state) {
                    Button("Uninstall", role: .destructive) {
                        act { CLIInstallActions.uninstall() }
                    }
                }
                if state == .installedHere {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .onAppear { refresh() }
    }

    /// Runs one CLIInstallActions act and re-inspects, so the row shows the
    /// world as it is after the act — including a cancelled dialog, which
    /// presents nothing and changes nothing.
    private func act(_ action: () -> CLIInstaller.Report?) {
        CLIInstallActions.present(action())
        refresh()
    }

    /// One `stat`, the same inspection the state machine itself performs.
    private func refresh() {
        state = CLIInstaller.inspect(
            installDestination,
            expecting: CLIInstaller.bundledCLI(inBundle: Bundle.main.bundleURL)
        )
    }

    private func captionColour(for state: CLIInstaller.State) -> Color {
        switch SettingsPresentation.cliEmphasis(for: state) {
        case .primary:
            return .primary
        case .caution:
            return .orange
        case .warning:
            return .red
        }
    }
}

// MARK: - Broker section

/// The broker's live status, bound to the SAME model the transport pane
/// binds — the bridge's `TransportStatusModel`. Every value and every action
/// comes from the model (the registration state, the approval guidance, the
/// captured error, the Repair closure, and the ping-gated reachability);
/// nothing here holds a second copy or touches `SMAppService` directly.
private struct BrokerStatusRow: View {
    let model: TransportStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: model.agentStatus.symbolName)
                    .foregroundStyle(model.agentStatus == .enabled ? Color.green : Color.secondary)
                Text(model.agentStatus.label)
                Spacer()
                // Reachability is a round-trip fact only (#0354): this reads
                // "Not probed yet" until a real ping completes, no matter how
                // healthy the registration state looks.
                Text(model.reachabilityLabel)
                    .foregroundStyle(model.brokerPingSucceeded == true ? Color.primary : Color.secondary)
            }
            if let guidance = SettingsPresentation.brokerGuidance(
                for: model.agentStatus, approvalInstruction: model.approvalInstruction)
            {
                Text(guidance)
                    .foregroundStyle(.secondary)
                Button("Open System Settings > Login Items") {
                    model.openLoginItems?()
                }
            }
            if let error = model.lastErrorDescription {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if model.showsRepairButton {
                Button("Repair") {
                    model.repair?()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - About

/// The About section's pure mapping from a bundle's info dictionary —
/// app-target because the shape is `Bundle.main`'s `infoDictionary`;
/// tested in SwitchyardTests/SettingsStateTests.swift.
nonisolated enum AboutPresentation {
    /// `Version X (N)` when both values exist and differ; the build number is
    /// elided when it repeats the short version. A bundle with only a build
    /// number renders `Build N`; nothing readable renders the honest
    /// fallback rather than an empty line.
    static func versionText(bundleInfo: [String: Any]?) -> String {
        let short = bundleInfo?["CFBundleShortVersionString"] as? String
        let build = bundleInfo?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where short != build:
            return "Version \(short) (\(build))"
        case let (short?, _):
            return "Version \(short)"
        case let (nil, build?):
            return "Build \(build)"
        default:
            return "Version unavailable"
        }
    }
}