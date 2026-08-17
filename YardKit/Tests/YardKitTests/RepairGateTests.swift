// RepairGateTests.swift

import Testing
@testable import YardKit

@Suite struct RepairGateTests {
    @Test func firstClaimSucceedsSubsequentClaimsFail() {
        let gate = RepairGate()
        #expect(gate.hasClaimed == false)

        #expect(gate.claim() == true)
        #expect(gate.hasClaimed == true)

        #expect(gate.claim() == false)
        #expect(gate.claim() == false)
        #expect(gate.hasClaimed == true)
    }

    @Test func concurrentClaimsYieldExactlyOneWinner() async {
        let gate = RepairGate()

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<100 {
                group.addTask {
                    gate.claim()
                }
            }
            var collected: [Bool] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        #expect(results.count == 100)
        let winners = results.filter { $0 }
        #expect(winners.count == 1)
        #expect(gate.hasClaimed == true)
    }

    @Test func freshGateIsIndependentOfAnotherGate() {
        let first = RepairGate()
        let second = RepairGate()

        #expect(first.claim() == true)

        #expect(second.hasClaimed == false)
        #expect(second.claim() == true)
    }
}
