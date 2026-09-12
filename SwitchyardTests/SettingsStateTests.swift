// SettingsStateTests.swift
//
// #0352. The app target's Settings surface, tested at the access level the
// app compiles it. The four CLI states and the broker guidance live in
// YardUI's `SettingsPresentation` and are covered by the package suite
// (YardKit/Tests/YardUITests/SettingsPresentationTests.swift); this file
// holds what only the app target can answer — the About section's
// bundle-derived version line, and that the view itself is constructible
// with the same value-driven transport model the transport pane binds.
//
// No SMAppService is touched, no XPC is opened, and no dialog is possible:
// constructing the view evaluates no filesystem state (the CLI row inspects
// in `.onAppear`, which does not fire on body construction).

import Foundation
import Testing
import YardUI
@testable import Switchyard

@MainActor
struct AboutPresentationTests {
    @Test("Short and build versions both present and different render as Version X (N)")
    func versionRendersShortAndBuild() {
        #expect(
            AboutPresentation.versionText(bundleInfo: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "45",
            ]) == "Version 1.2.3 (45)")
    }

    @Test("A build number equal to the short version is not repeated")
    func buildNumberRepeatingShortVersionIsElided() {
        #expect(
            AboutPresentation.versionText(bundleInfo: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "1.2.3",
            ]) == "Version 1.2.3")
    }

    @Test("A bundle with only a build number renders Build N")
    func buildOnlyBundleRendersBuildLabel() {
        #expect(
            AboutPresentation.versionText(bundleInfo: ["CFBundleVersion": "45"]) == "Build 45")
    }

    @Test("An absent or empty bundle info renders the honest fallback")
    func absentBundleInfoRendersFallback() {
        #expect(AboutPresentation.versionText(bundleInfo: nil) == "Version unavailable")
        #expect(AboutPresentation.versionText(bundleInfo: [:]) == "Version unavailable")
    }
}

@MainActor
struct SettingsViewConstructionTests {
    @Test("SettingsView accepts the transport model the pane binds, at the app's access level")
    func settingsViewAcceptsTheTransportModel() {
        // Fails to COMPILE if the initialiser or `body` is not
        // internal-or-public — the same compile contract the package's
        // ContentViewPublicAPITests checks, which @testable alone would
        // silently mask. The falsifiable assertion below covers the rename.
        let view = SettingsView(transport: TransportStatusModel())
        _ = view.body
        #expect(String(describing: SettingsView.self) == "SettingsView")
    }
}