// TransportStatusTests.swift
//
// #0216. This target imports YardUI WITHOUT `@testable`, so every member
// exercised here is part of the public surface the app target sees (#0116's
// failure class). No `SMAppService` appears anywhere in this file and no
// test can call `register()` — the model has no such method; every state is
// constructed from plain values, which is the whole point of the value-
// driven model.

import Testing
import YardKit
import YardUI

// MARK: - Agent status vocabulary

@Test("Every agent status carries the exact SMAppService.Status label wording")
func agentStatusLabelWording() throws {
    let statuses = AgentStatus.allCases
    #expect(statuses.count == 4)
    let expectedLabels: [AgentStatus: String] = [
        .notRegistered: "Not registered",
        .requiresApproval: "Requires approval",
        .enabled: "Enabled",
        .notFound: "Not found",
    ]
    for status in statuses {
        let expected = try #require(expectedLabels[status])
        #expect(status.label == expected)
    }
}

@Test("Only requiresApproval shows the approval button; the other three never do")
func approvalButtonVisibilityPerState() {
    let statuses = AgentStatus.allCases
    #expect(statuses.count == 4)
    for status in statuses {
        #expect(status.showsApprovalButton == (status == .requiresApproval))
    }
    #expect(AgentStatus.requiresApproval.showsApprovalButton)
    #expect(!AgentStatus.enabled.showsApprovalButton)
    #expect(!AgentStatus.notRegistered.showsApprovalButton)
    #expect(!AgentStatus.notFound.showsApprovalButton)
}

@Test("Every agent status names a non-empty, distinct SF Symbol")
func symbolNamesAreNonEmptyAndDistinct() {
    let statuses = AgentStatus.allCases
    #expect(statuses.count == 4)
    let symbols = statuses.map(\.symbolName)
    for symbol in symbols {
        #expect(!symbol.isEmpty)
    }
    #expect(Set(symbols).count == 4)
}

// MARK: - Model

@MainActor
@Test("The model's default mach service name is the real constant")
func machServiceNameIsTheRealConstant() {
    let model = TransportStatusModel()
    // The single source of truth lives in ServiceNames; nothing outside it
    // may hardcode the identifier (the guardian test enforces that), so the
    // pane is checked against the constant itself, never a copy of the
    // string.
    #expect(model.machServiceName == ServiceNames.machServiceName)
    #expect(!model.machServiceName.isEmpty)
}

@MainActor
@Test("Endpoint registered vs not renders different exact wording")
func endpointWordingReflectsRegistration() {
    let registered = TransportStatusModel(endpointRegistered: true)
    let unregistered = TransportStatusModel(endpointRegistered: false)
    #expect(registered.endpointLabel == "Registered with the broker")
    #expect(unregistered.endpointLabel == "Not registered")
    #expect(registered.endpointLabel != unregistered.endpointLabel)
}

@MainActor
@Test("Zero and several clients render different exact wording")
func clientCountWordingDistinguishesZeroFromSeveral() {
    let none = TransportStatusModel(clientCount: 0)
    #expect(none.clientCountLabel == "None connected")
    let several = TransportStatusModel(clientCount: 3)
    #expect(several.clientCountLabel == "3 connected")
    #expect(none.clientCountLabel != several.clientCountLabel)
}

@MainActor
@Test("Updating the model's values updates every derived rendering value")
func modelUpdatesFlowThroughDerivedValues() {
    let model = TransportStatusModel(
        agentStatus: .enabled, endpointRegistered: true, clientCount: 2)
    #expect(!model.agentStatus.showsApprovalButton)
    #expect(model.endpointLabel == "Registered with the broker")
    #expect(model.clientCountLabel == "2 connected")

    model.agentStatus = .requiresApproval
    #expect(model.agentStatus.showsApprovalButton)
    model.endpointRegistered = false
    #expect(model.endpointLabel == "Not registered")
    model.clientCount = 0
    #expect(model.clientCountLabel == "None connected")
}

@MainActor
@Test("The model carries an invocable action for the approval button")
func openLoginItemsActionIsInvocableThroughTheModel() {
    let model = TransportStatusModel(agentStatus: .requiresApproval)
    var opened = false
    model.openLoginItems = { opened = true }
    #expect(model.openLoginItems != nil)
    model.openLoginItems?()
    #expect(opened)
}

// MARK: - Views, at the access level the app target sees

@MainActor
@Test("TransportStatusPane is publicly constructible and its body builds from the model")
func transportStatusPaneIsPubliclyConstructible() {
    let model = TransportStatusModel(
        agentStatus: .requiresApproval, endpointRegistered: true, clientCount: 1)
    let pane = TransportStatusPane(model: model)
    // Fails to COMPILE if the initialiser or `body` is not public — the same
    // compile contract ContentViewPublicAPITests checks, which `@testable`
    // would silently mask. The falsifiable assertion below covers the rename.
    _ = pane.body
    #expect(String(describing: TransportStatusPane.self) == "TransportStatusPane")
}

@MainActor
@Test("ContentView accepts an injected transport model at a caller's access level")
func contentViewAcceptsInjectedTransportModel() {
    let view = ContentView(transportStatus: TransportStatusModel())
    _ = view.body
    #expect(String(describing: ContentView.self) == "ContentView")
}
