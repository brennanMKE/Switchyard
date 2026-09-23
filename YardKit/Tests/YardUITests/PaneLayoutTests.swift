// PaneLayoutTests.swift
//
// `PaneLayout` is `public`, so this target imports YardUI WITHOUT `@testable`
// -- matching RepositoryLoaderTests and ContentViewPublicAPITests, so a member
// that silently dropped to internal would fail to compile here (#0116's
// failure class), rather than being masked by `@testable` access.
//
// `import Foundation` is required here even though nothing below names a
// Foundation type directly: `PaneLayout`'s properties are `CGFloat`, and
// without a direct import (SE-0444 member import visibility) `#expect`'s
// diffing macro cannot see `CGFloat`'s `Equatable` conformance and silently
// reports two bit-identical values as unequal. Measured: the same `==`
// expression printed `true` via `String(describing:)` and failed via
// `#expect` in this file until this import was added.

import Testing
import Foundation
import YardUI

@Test("Every pane's minimum width is positive, so no pane can be dragged to unusable")
func paneMinimumWidthsAreAllPositive() {
    let minimums = [
        PaneLayout.sidebarMinWidth,
        PaneLayout.historyMinWidth,
        PaneLayout.detailMinWidth,
    ]
    #expect(minimums.count == 3)
    for minimum in minimums {
        #expect(minimum > 0)
    }
}

@Test("windowMinWidth is exactly the sum of the three pane minimums")
func windowMinWidthIsTheSumOfPaneMinimums() {
    let computedWidth = PaneLayout.windowMinWidth
    let computedSum = PaneLayout.sidebarMinWidth + PaneLayout.historyMinWidth + PaneLayout.detailMinWidth
    #expect(computedWidth == computedSum)
}

@Test("the window minimum is 840 pt, wide enough for a readable sidebar, graph and detail (#0409)")
func windowMinWidthIsReadable() {
    #expect(PaneLayout.windowMinWidth == 840)
    #expect(PaneLayout.sidebarMinWidth >= 200)
}
