// AppSandboxSettingTests.swift
//
// #0423: guide §11 decision 5 — Switchyard ships unsandboxed. The app target
// carried the Xcode template's ENABLE_APP_SANDBOX = YES, which is inert in the
// unsigned builds agents make but becomes com.apple.security.app-sandbox in
// every SIGNED build. A sandboxed app cannot look up the unprefixed Mach
// service the broker publishes (see ServiceNames.machServiceName), so it
// never registers its endpoint and every CLI command exits 3
// (app_unavailable) — measured in the Tart VM, 2026-09-26. This pins the
// setting off.

import Foundation
import Testing

struct AppSandboxSettingTests {

    private var pbxproj: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // YardKitTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // YardKit
                .deletingLastPathComponent()   // repo root
                .appendingPathComponent("Switchyard.xcodeproj/project.pbxproj")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test func noTargetEnablesTheAppSandbox() throws {
        #expect(!(try pbxproj).contains("ENABLE_APP_SANDBOX = YES;"))
    }

    /// Both of the app target's configurations (Debug, Release) say NO
    /// explicitly, so a later Xcode template default cannot silently return.
    @Test func bothAppConfigurationsDisableTheSandbox() throws {
        let occurrences = (try pbxproj).components(separatedBy: "ENABLE_APP_SANDBOX = NO;").count - 1
        #expect(occurrences == 2)
    }
}
