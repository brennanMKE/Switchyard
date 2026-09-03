// HookMarkerAgreementTests.swift — the marker variable spans two targets
// that cannot see each other (#0154)

import Testing
import YardGit
import YardKit

/// The hook arm gates on `ServiceNames.yardInvocationMarkerVariable`
/// (YardKit) and the decision core gates on `GitProcess.markerVariable`
/// (YardGit). The layering that keeps the CLI from linking the engine also
/// keeps either side from asserting the equality in source, so a rename on
/// one side could half-land: the arm would then misread the engine's own
/// transactions as foreign and ship them anyway (harmless — the core
/// re-gates), or silently drain stdin it did not need. This file exists
/// because it imports both sides of the boundary and nothing else can.
@Test func hookMarkerVariableAgreesBetweenEngineAndCLILayers() {
    #expect(GitProcess.markerVariable == ServiceNames.yardInvocationMarkerVariable)
}
