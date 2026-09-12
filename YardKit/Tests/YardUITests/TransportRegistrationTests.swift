// TransportRegistrationTests.swift
//
// #0354's pane-side contract: the registration error's surfacing, the
// Repair button's visibility, the approval instruction, and the
// ping-gated reachability rule. Same discipline as TransportStatusTests:
// no `@testable`, no `SMAppService` — every state is constructed from
// plain values, which is the whole point of the value-driven model.

import Testing
import YardKit
import YardUI

@MainActor
@Test("requiresApproval carries the exact System Settings instruction")
func approvalInstructionNamesTheSettingsPath() {
    #expect(TransportStatusModel().approvalInstruction
        == "Approve in System Settings → General → Login Items & Extensions")
}

@MainActor
@Test("The error row renders exactly when a last error is set")
func errorRowVisibilityFollowsTheCapturedError() {
    #expect(!TransportStatusModel().showsErrorRow)
    #expect(TransportStatusModel(lastErrorDescription: "launchd rejected the registration").showsErrorRow)
    #expect(!TransportStatusModel(lastErrorDescription: nil).showsErrorRow)
}

@MainActor
@Test("The Repair button renders only for notRegistered with a captured error")
func repairButtonVisibilityPerStateAndError() {
    let statuses = AgentStatus.allCases
    #expect(statuses.count == 4)
    for status in statuses {
        for error: String? in [nil, "launchd rejected the registration"] {
            let model = TransportStatusModel(agentStatus: status, lastErrorDescription: error)
            #expect(model.showsRepairButton == (status == .notRegistered && error != nil))
        }
    }
}

@MainActor
@Test("The exact reachability wordings: not probed, reachable, not reachable")
func reachabilityWordingPerRoundTripOutcome() {
    #expect(TransportStatusModel().reachabilityLabel == "Not probed yet")
    #expect(TransportStatusModel(brokerPingSucceeded: true).reachabilityLabel == "Reachable")
    #expect(TransportStatusModel(brokerPingSucceeded: false).reachabilityLabel == "Not reachable")
}

@MainActor
@Test("Registration belief never claims reachable; only a ping round-trip does")
func registrationBeliefNeverProducesReachable() {
    // .enabled + endpoint registered + clients connected — everything the
    // registration machinery can believe — must still not read "Reachable".
    let model = TransportStatusModel(
        agentStatus: .enabled, endpointRegistered: true, clientCount: 2)
    #expect(model.reachabilityLabel != "Reachable")
    #expect(model.reachabilityLabel == "Not probed yet")

    // Only the real round-trip flips it.
    model.brokerPingSucceeded = true
    #expect(model.reachabilityLabel == "Reachable")

    // And a failed round-trip un-claims it, even with .enabled still set.
    model.brokerPingSucceeded = false
    #expect(model.reachabilityLabel == "Not reachable")
    #expect(model.agentStatus == .enabled)
}

@MainActor
@Test("The model carries an invocable action for the Repair button")
func repairActionIsInvocableThroughTheModel() {
    let model = TransportStatusModel(
        agentStatus: .notRegistered, lastErrorDescription: "launchd rejected the registration")
    var repaired = false
    #expect(model.repair == nil)
    model.repair = { repaired = true }
    model.repair?()
    #expect(repaired)
}

@MainActor
@Test("The pane builds its body from every #0354 state at the app target's access level")
func transportStatusPaneBuildsFromTheNewStates() {
    let approving = TransportStatusModel(agentStatus: .requiresApproval)
    let failing = TransportStatusModel(
        agentStatus: .notRegistered,
        lastErrorDescription: "launchd rejected the registration",
        brokerPingSucceeded: false)
    let healthy = TransportStatusModel(
        agentStatus: .enabled, endpointRegistered: true, brokerPingSucceeded: true)
    for pane in [TransportStatusPane(model: approving), TransportStatusPane(model: failing), TransportStatusPane(model: healthy)] {
        _ = pane.body
    }
    #expect(failing.showsRepairButton)
    #expect(!approving.showsRepairButton)
    #expect(healthy.reachabilityLabel == "Reachable")
}
