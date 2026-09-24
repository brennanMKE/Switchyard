// BranchMapLabelsTests.swift — the branch map's lane labels (#0413)

import Testing
import YardUI

private func labelChip(_ name: String, _ kind: RefChip.Kind = .localBranch, head: Bool = false) -> RefChip {
    RefChip(name: name, kind: kind, isHead: head)
}

@Test func aLaneLabelShowsTwoNamesAndFoldsTheRest() {
    let chips = [
        labelChip("uitest-main", head: true), labelChip("alpha-fork"), labelChip("spike-side"),
        labelChip("origin/uitest-side", .remoteBranch),
    ]
    #expect(BranchMapLabels.title(chips) == "uitest-main, alpha-fork +2")
}

@Test func aLaneLabelWithOneOrTwoNamesFoldsNothing() {
    #expect(BranchMapLabels.title([labelChip("main")]) == "main")
    #expect(BranchMapLabels.title([labelChip("main"), labelChip("origin/main", .remoteBranch)]) == "main, origin/main")
}

@Test func aLaneLabelSpeaksEveryNameAfterLane() {
    let chips = [labelChip("feature"), labelChip("origin/feature", .remoteBranch), labelChip("other")]
    #expect(BranchMapLabels.accessibilityLabel(chips) == "Lane feature, origin/feature, other")
}
