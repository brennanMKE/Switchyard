// SettingsPresentation.swift
//
// #0352: the Settings screen's state→presentation mapping, as pure
// functions a test can drive without the app, `SMAppService`, the
// filesystem, or a dialog. The Settings view (app target) renders from
// these; the states themselves come from the value-driven vocabulary the
// rest of YardUI already owns — `CLIInstaller.State` (the package's
// four-state install inspection, YardKit) and `AgentStatus` (the transport
// pane's registration vocabulary) — so the Settings screen and the
// surfaces it mirrors can never disagree about wording.
//
// The row shapes and the four-state presentation idiom are adapted from
// BattyKit/Sources/BattyKit/Views/SettingsView.swift (MIT License —
// Copyright 2026 Brennan Stehling); this notice is retained for the
// adapted portions. The wording and the seam are Switchyard's own.

import SwiftUI
import YardKit

/// `nonisolated` on purpose: stateless value vocabulary, and the target's
/// MainActor-by-default isolation would otherwise fence these members away
/// from plain call sites — the same shape `AgentStatus` takes.
nonisolated public enum SettingsPresentation {

    /// How strongly a CLI state's caption is emphasised. A value rather
    /// than a `Color` so the mapping stays assertable without rendering
    /// anything; the view keeps to adaptive system styles when mapping it.
    public enum Emphasis: Equatable, Sendable {
        /// Normal text: the state is either healthy or merely absent.
        case primary
        /// Orange caption: a stale link that installing will replace.
        case caution
        /// Red caption: something at the destination the app must not touch.
        case warning
    }

    /// The CLI section's one-line status for an inspected install state.
    /// Four states in, four exact strings out — never a boolean.
    public static func cliStatusText(for state: CLIInstaller.State) -> String {
        switch state {
        case .notInstalled: "Not installed"
        case .installedHere: "Installed"
        case .installedElsewhere: "Installed elsewhere"
        case .blockedByFile: "Blocked by a file"
        }
    }

    /// The caption under the status line, or `nil` for a state that needs
    /// no explanation. `installedElsewhere` names the stale target and
    /// carries the self-healing note: installing replaces it. `blockedByFile`
    /// names the never-clobbered rule and the remedy.
    public static func cliDetailText(
        for state: CLIInstaller.State,
        installPath: String
    ) -> String? {
        switch state {
        case .notInstalled:
            "Installing creates \(installPath) as a link into this app."
        case .installedHere:
            "\(installPath) points into this app."
        case .installedElsewhere(let target):
            "A stale link points to \(target). Installing will replace it with a link into this app."
        case .blockedByFile:
            "\(installPath) already exists and is not a symlink this app created. "
                + "Remove it yourself, then try installing again."
        }
    }

    /// The caption colour's semantic slot for a state. The mapping stays
    /// here (not in the view) so every state's emphasis is assertable.
    public static func cliEmphasis(for state: CLIInstaller.State) -> Emphasis {
        switch state {
        case .notInstalled, .installedHere: .primary
        case .installedElsewhere: .caution
        case .blockedByFile: .warning
        }
    }

    /// Whether the Install control renders for `state` — every state but
    /// `installedHere`, where installing is already this bundle's truth.
    /// The action re-inspects when clicked, so a stale reading self-corrects.
    public static func showsInstallButton(for state: CLIInstaller.State) -> Bool {
        state != .installedHere
    }

    /// Whether the Uninstall control renders. `blockedByFile` stays enabled
    /// on purpose: the action answers with a "nothing was removed" warning
    /// rather than silently ignoring a file it must not touch.
    public static func showsUninstallButton(for state: CLIInstaller.State) -> Bool {
        state != .notInstalled
    }

    /// The Broker section's guidance line: the System Settings path when the
    /// agent awaits approval, `nil` when the state carries no guidance of its
    /// own. The instruction text is passed in — `TransportStatusModel
    /// .approvalInstruction` is the wording's single source — so this mapping
    /// decides only WHEN it shows, never what it says.
    public static func brokerGuidance(
        for status: AgentStatus,
        approvalInstruction: String
    ) -> String? {
        status.showsApprovalButton ? approvalInstruction : nil
    }
}