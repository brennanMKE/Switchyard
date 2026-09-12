// BrokerAgentRegistrationTests.swift
//
// #0354. Tests for the broker registration state machine — no SMAppService
// registration performed, no XPC, no broker process. The mapping table is
// pure; the controller is exercised through the `AgentServiceServicing`
// seam, so a failing register()/unregister() is simulated, never performed
// against launchd.
//
// `@unknown default` has no test: `SMAppService.Status` is an imported
// Objective-C enum, and Swift cannot fabricate a case outside the known
// set (`init?(rawValue:)` returns nil for unknown values) — the same shape
// Batty's own mapping tests ship with.

import Foundation
import ServiceManagement
import Testing
@testable import Switchyard

struct BrokerAgentRegistrationStateTests {
    @Test func mapsNotRegistered() {
        #expect(BrokerAgentRegistrationState(status: .notRegistered) == .notRegistered)
    }

    @Test func mapsNotFoundToNotRegistered() {
        // `.notFound` and `.notRegistered` both mean "nothing registered"
        // from the UI's point of view — neither implies the broker was
        // ever reachable.
        #expect(BrokerAgentRegistrationState(status: .notFound) == .notRegistered)
    }

    @Test func mapsRequiresApproval() {
        #expect(BrokerAgentRegistrationState(status: .requiresApproval) == .requiresApproval)
    }

    @Test func mapsEnabled() {
        #expect(BrokerAgentRegistrationState(status: .enabled) == .enabled)
    }
}

/// A seam whose calls throw on demand and whose status is scriptable, so
/// the controller's capture and refresh behaviour is driven without
/// launchd.
@MainActor
private final class FakeAgentService: AgentServiceServicing {
    private struct Fault: LocalizedError {
        let errorDescription: String?
    }

    var status: SMAppService.Status = .notRegistered
    var registerError: (any Error)?
    var unregisterError: (any Error)?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError { throw unregisterError }
    }

    static func fault(_ text: String) -> any Error {
        Fault(errorDescription: text)
    }
}

@MainActor
struct BrokerAgentControllerErrorCaptureTests {
    @Test("A failing register() is captured, not silent")
    func registerFailureIsCaptured() {
        let fake = FakeAgentService()
        fake.registerError = FakeAgentService.fault("launchd rejected the registration")
        let controller = BrokerAgentController(service: fake)

        controller.register()

        #expect(controller.lastErrorDescription == "launchd rejected the registration")
        #expect(controller.state == .notRegistered)
        #expect(fake.registerCallCount == 1)
    }

    @Test("A succeeding register() clears any previously captured error")
    func registerSuccessClearsTheCapturedError() {
        let fake = FakeAgentService()
        fake.registerError = FakeAgentService.fault("first attempt failed")
        let controller = BrokerAgentController(service: fake)
        controller.register()
        #expect(controller.lastErrorDescription != nil)

        fake.registerError = nil
        controller.register()

        #expect(controller.lastErrorDescription == nil)
    }

    @Test("A throw while the status reads enabled is the benign already-registered case")
    func benignAlreadyRegisteredThrowIsNotAnError() {
        let fake = FakeAgentService()
        fake.status = .enabled
        fake.registerError = FakeAgentService.fault("already registered")
        let controller = BrokerAgentController(service: fake)

        controller.register()

        #expect(controller.state == .enabled)
        #expect(controller.lastErrorDescription == nil)
    }

    @Test("A failing unregister() is captured")
    func unregisterFailureIsCaptured() {
        let fake = FakeAgentService()
        fake.unregisterError = FakeAgentService.fault("launchd has no such job")
        let controller = BrokerAgentController(service: fake)

        controller.unregister()

        #expect(controller.lastErrorDescription == "launchd has no such job")
        #expect(fake.unregisterCallCount == 1)
    }

    @Test("refresh() reads the current status into the published state")
    func refreshReadsTheCurrentStatus() {
        let fake = FakeAgentService()
        fake.status = .requiresApproval
        let controller = BrokerAgentController(service: fake)

        #expect(controller.state == .requiresApproval)

        fake.status = .notRegistered
        controller.refresh()

        #expect(controller.state == .notRegistered)
    }
}

@MainActor
struct AgentRegistrarRoutingTests {
    @Test("registerIfNeeded routes through the controller and surfaces requiresApproval")
    func registerIfNeededSurfacesRequiresApproval() {
        let fake = FakeAgentService()
        fake.status = .requiresApproval
        let registrar = AgentRegistrar(controller: BrokerAgentController(service: fake))

        registrar.registerIfNeeded()

        #expect(registrar.state == .requiresApproval)
        #expect(registrar.lastErrorDescription == nil)
        #expect(fake.registerCallCount == 1)
    }

    @Test("registerIfNeeded short-circuits on an enabled state without registering")
    func registerIfNeededShortCircuitsOnEnabled() {
        let fake = FakeAgentService()
        fake.status = .enabled
        let registrar = AgentRegistrar(controller: BrokerAgentController(service: fake))

        registrar.registerIfNeeded()

        #expect(registrar.state == .enabled)
        #expect(fake.registerCallCount == 0)
    }

    @Test("registerIfNeeded surfaces a failing registration's captured text")
    func registerIfNeededSurfacesTheCapturedError() {
        let fake = FakeAgentService()
        fake.registerError = FakeAgentService.fault("launchd rejected the registration")
        let registrar = AgentRegistrar(controller: BrokerAgentController(service: fake))

        registrar.registerIfNeeded()

        #expect(registrar.state == .notRegistered)
        #expect(registrar.lastErrorDescription == "launchd rejected the registration")
    }

    @Test("repair unregisters then registers, and a benign unregister failure is cleared by success")
    func repairRegistersAfterUnregister() {
        let fake = FakeAgentService()
        fake.unregisterError = FakeAgentService.fault("launchd has no such job")
        let registrar = AgentRegistrar(controller: BrokerAgentController(service: fake))

        registrar.repair()

        #expect(fake.unregisterCallCount == 1)
        #expect(fake.registerCallCount == 1)
        #expect(registrar.lastErrorDescription == nil)
        #expect(registrar.state == .notRegistered)
    }
}
