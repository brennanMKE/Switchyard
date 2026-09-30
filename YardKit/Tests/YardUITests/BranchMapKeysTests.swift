// BranchMapKeysTests.swift
//
// #0557: which arrow presses step the branch map's selection. A plain arrow
// key arrives carrying `.function` (and a keypad arrow `.numericPad`); both
// must step. ⌘, ⌥, ⌃ and ⇧ pass through to the menu bar (#0383).

import SwiftUI
import Testing
import YardUI

@Test func aPlainArrowStepsTheLane() {
    #expect(BranchMapKeys.stepsLane([]))
    #expect(BranchMapKeys.stepsLane(.function))
    #expect(BranchMapKeys.stepsLane([.function, .numericPad]))
}

@Test func aModifiedArrowPassesThrough() {
    #expect(!BranchMapKeys.stepsLane([.function, .command, .option]))
    #expect(!BranchMapKeys.stepsLane([.function, .command]))
    #expect(!BranchMapKeys.stepsLane([.function, .option]))
    #expect(!BranchMapKeys.stepsLane([.function, .control]))
    #expect(!BranchMapKeys.stepsLane([.function, .shift]))
}
