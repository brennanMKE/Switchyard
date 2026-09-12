// SettingsPresentationTests.swift
//
// #0352. The Settings screen's state→presentation mapping, tested at the
// pure seam in YardUI — no app, no SMAppService, no filesystem, no dialogs.
// The four CLI install states are each asserted against their exact
// rendered strings (per-state tests, the house idiom from
// BrokerAgentRegistrationTests); the broker guidance is asserted for every
// AgentStatus case.
//
// Imports are NOT @testable — the mapping is part of the public surface the
// app target consumes, and @testable would mask a member silently dropping
// to internal (the #0116 failure class).

import Testing
import YardKit
import YardUI

// MARK: - CLI install states, one test per state

@Test("notInstalled renders its status, its install caption, and no warning colour")
func cliNotInstalledRendering() {
    #expect(SettingsPresentation.cliStatusText(for: .notInstalled) == "Not installed")
    let detail = SettingsPresentation.cliDetailText(
        for: .notInstalled, installPath: ServiceNames.cliInstallPath)
    #expect(
        detail == "Installing creates \(ServiceNames.cliInstallPath) as a link into this app.")
    #expect(SettingsPresentation.cliEmphasis(for: .notInstalled) == .primary)
}

@Test("installedHere renders the affirmed status against the real install path")
func cliInstalledHereRendering() {
    #expect(SettingsPresentation.cliStatusText(for: .installedHere) == "Installed")
    let detail = SettingsPresentation.cliDetailText(
        for: .installedHere, installPath: ServiceNames.cliInstallPath)
    #expect(detail == "\(ServiceNames.cliInstallPath) points into this app.")
    #expect(SettingsPresentation.cliEmphasis(for: .installedHere) == .primary)
}

@Test("installedElsewhere names the stale target with the self-healing note")
func cliInstalledElsewhereRendering() {
    let staleTarget = "/Users/demo/Downloads/Old.app/Contents/Resources/bin/switchyard"
    let state = CLIInstaller.State.installedElsewhere(staleTarget)
    #expect(SettingsPresentation.cliStatusText(for: state) == "Installed elsewhere")
    let detail = SettingsPresentation.cliDetailText(
        for: state, installPath: ServiceNames.cliInstallPath)
    #expect(
        detail
            == "A stale link points to \(staleTarget). Installing will replace it with a link into this app.")
    #expect(SettingsPresentation.cliEmphasis(for: state) == .caution)
}

@Test("blockedByFile renders the never-clobbered remedy in the warning colour")
func cliBlockedByFileRendering() {
    #expect(SettingsPresentation.cliStatusText(for: .blockedByFile) == "Blocked by a file")
    let detail = SettingsPresentation.cliDetailText(
        for: .blockedByFile, installPath: ServiceNames.cliInstallPath)
    #expect(
        detail
            == "\(ServiceNames.cliInstallPath) already exists and is not a symlink this app created. Remove it yourself, then try installing again.")
    #expect(SettingsPresentation.cliEmphasis(for: .blockedByFile) == .warning)
}

// MARK: - CLI controls per state

@Test("Install renders for every state but installedHere; Uninstall for every state but notInstalled")
func cliButtonVisibilityPerState() {
    let states: [CLIInstaller.State] = [
        .notInstalled, .installedHere,
        .installedElsewhere("/somewhere/else/switchyard"), .blockedByFile,
    ]
    #expect(states.count == 4)
    for state in states {
        #expect(SettingsPresentation.showsInstallButton(for: state) == (state != .installedHere))
        #expect(
            SettingsPresentation.showsUninstallButton(for: state) == (state != .notInstalled))
    }
    // Every state asserted explicitly, so a loop bug cannot hide a case:
    #expect(SettingsPresentation.showsInstallButton(for: .notInstalled))
    #expect(!SettingsPresentation.showsInstallButton(for: .installedHere))
    #expect(SettingsPresentation.showsInstallButton(for: .installedElsewhere("/x/switchyard")))
    #expect(SettingsPresentation.showsInstallButton(for: .blockedByFile))
    #expect(!SettingsPresentation.showsUninstallButton(for: .notInstalled))
    #expect(SettingsPresentation.showsUninstallButton(for: .installedHere))
    #expect(SettingsPresentation.showsUninstallButton(for: .installedElsewhere("/x/switchyard")))
    #expect(SettingsPresentation.showsUninstallButton(for: .blockedByFile))
}

// MARK: - Broker guidance per registration state

@MainActor
@Test("Only requiresApproval carries guidance, and it is the model's exact instruction")
func brokerGuidancePerStatus() {
    // The wording's single source is the transport model; the mapping only
    // decides when it shows. Assert the exact instruction too, so the
    // Settings screen's guidance text is pinned the same way the pane's is.
    let instruction = TransportStatusModel().approvalInstruction
    #expect(instruction == "Approve in System Settings → General → Login Items & Extensions")

    let statuses = AgentStatus.allCases
    #expect(statuses.count == 4)
    for status in statuses {
        let guidance = SettingsPresentation.brokerGuidance(
            for: status, approvalInstruction: instruction)
        #expect(guidance == (status.showsApprovalButton ? instruction : nil))
    }
    #expect(
        SettingsPresentation.brokerGuidance(for: .requiresApproval, approvalInstruction: instruction)
            == instruction)
    #expect(SettingsPresentation.brokerGuidance(for: .enabled, approvalInstruction: instruction) == nil)
    #expect(
        SettingsPresentation.brokerGuidance(for: .notRegistered, approvalInstruction: instruction)
            == nil)
    #expect(SettingsPresentation.brokerGuidance(for: .notFound, approvalInstruction: instruction) == nil)
}