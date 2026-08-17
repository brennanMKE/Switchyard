// EndpointRegistryTests.swift

import Testing
@testable import YardKit

struct EndpointRegistryTests {

    @Test func storeMakesTheValueReadableAsCurrent() {
        let registry = EndpointRegistry<String>()
        let owner = EndpointRegistry<String>.Owner()

        registry.store("endpoint-a", owner: owner)

        #expect(registry.current == "endpoint-a")
    }

    @Test func currentIsNilBeforeAnythingIsStored() {
        let registry = EndpointRegistry<String>()

        #expect(registry.current == nil)
    }

    @Test func clearByTheRegisteringOwnerSucceedsAndRemovesTheValue() {
        let registry = EndpointRegistry<String>()
        let owner = EndpointRegistry<String>.Owner()
        registry.store("endpoint-a", owner: owner)

        let cleared = registry.clear(owner: owner)

        #expect(cleared)
        #expect(registry.current == nil)
    }

    @Test func clearByADifferentOwnerIsRejectedAndLeavesTheValueInPlace() {
        let registry = EndpointRegistry<String>()
        let registering = EndpointRegistry<String>.Owner()
        let intruder = EndpointRegistry<String>.Owner()
        registry.store("endpoint-a", owner: registering)

        let cleared = registry.clear(owner: intruder)

        #expect(!cleared)
        #expect(registry.current == "endpoint-a")
    }

    @Test func clearWithNoRegistrationYetIsRejected() {
        let registry = EndpointRegistry<String>()
        let owner = EndpointRegistry<String>.Owner()

        let cleared = registry.clear(owner: owner)

        #expect(!cleared)
        #expect(registry.current == nil)
    }

    @Test func aLaterStoreFromADifferentOwnerReplacesTheValueAndTheOwner() {
        let registry = EndpointRegistry<String>()
        let first = EndpointRegistry<String>.Owner()
        let second = EndpointRegistry<String>.Owner()
        registry.store("endpoint-a", owner: first)

        registry.store("endpoint-b", owner: second)

        #expect(registry.current == "endpoint-b")
        // The original owner can no longer clear -- ownership moved with the store.
        #expect(!registry.clear(owner: first))
        #expect(registry.current == "endpoint-b")
        #expect(registry.clear(owner: second))
        #expect(registry.current == nil)
    }

    @Test func ownerEqualityIsPerInstanceNotStructural() {
        let a = EndpointRegistry<String>.Owner()
        let b = EndpointRegistry<String>.Owner()

        #expect(a == a)
        #expect(a != b)
    }
}
