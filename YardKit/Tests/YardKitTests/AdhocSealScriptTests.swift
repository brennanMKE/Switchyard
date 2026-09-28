// AdhocSealScriptTests.swift
//
// #0418: an unsigned build (CODE_SIGNING_ALLOWED=NO) leaves the app bundle
// linker-signed with no sealed resources, and SMAppService then refuses the
// broker agent's plist with -67056 (errSecCSResourcesNotFound). These tests
// drive scripts/adhoc-seal-app.sh against a throwaway bundle built exactly
// the way the linker leaves the real one, and pin that the two build paths
// (the Xcode build phase and make-release.sh) both invoke it.
//
// Ad-hoc signing (`codesign --sign -`) uses no identity and no keychain.

import Foundation
import Testing
@testable import YardKit

struct AdhocSealScriptTests {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit
            .deletingLastPathComponent()   // repo root
    }

    /// Runs a tool and returns its exit status and combined stdout+stderr.
    /// The pipe is drained before waiting, so a chatty tool cannot block.
    private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Builds `<dir>/Fake.app` shaped like the real bundle: a main
    /// executable, `Contents/MacOS/BrokerAgent`, the CLI at
    /// `Contents/Resources/bin/switchyard`, and the broker plist under
    /// `Contents/Library/LaunchAgents`. Every Mach-O comes straight from the
    /// linker, so each is `linker-signed` and the bundle has no seal —
    /// the state an unsigned Xcode build produces.
    private func makeLinkerSignedBundle(in dir: URL) throws -> URL {
        let app = dir.appendingPathComponent("Fake.app")
        let fm = FileManager.default
        for sub in ["Contents/MacOS", "Contents/Resources/bin", "Contents/Library/LaunchAgents"] {
            try fm.createDirectory(at: app.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let source = dir.appendingPathComponent("main.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        for binary in ["Contents/MacOS/Fake", "Contents/MacOS/BrokerAgent", "Contents/Resources/bin/switchyard"] {
            let compiled = try run("/usr/bin/xcrun", ["clang", source.path, "-o", app.appendingPathComponent(binary).path])
            try #require(compiled.status == 0, "clang failed: \(compiled.output)")
        }
        try fm.copyItem(
            at: repoRoot.appendingPathComponent("Support").appendingPathComponent(ServiceNames.agentPlistName),
            to: app.appendingPathComponent("Contents/Library/LaunchAgents").appendingPathComponent(ServiceNames.agentPlistName))
        let info: [String: Any] = [
            "CFBundleExecutable": "Fake",
            "CFBundleIdentifier": "test.adhoc-seal.fake",
            "CFBundlePackageType": "APPL",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    @Test func sealsALinkerSignedBundleSoItVerifiesStrictly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adhoc-seal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeLinkerSignedBundle(in: dir)

        // Before: the exact failure smd reports as -67056.
        let before = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        #expect(before.status != 0)
        #expect(before.output.contains("code has no resources but signature indicates they must be present"),
                "unexpected pre-seal verify output: \(before.output)")

        let sealed = try run("/bin/zsh", [repoRoot.appendingPathComponent("scripts/adhoc-seal-app.sh").path, app.path])
        #expect(sealed.status == 0, "adhoc-seal-app.sh failed: \(sealed.output)")

        let after = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        #expect(after.status == 0, "sealed bundle does not verify: \(after.output)")

        let bundle = try run("/usr/bin/codesign", ["-dv", app.path])
        #expect(bundle.output.contains("Sealed Resources version=2"), "bundle not sealed: \(bundle.output)")
        #expect(bundle.output.contains("Signature=adhoc"), "bundle not ad-hoc signed: \(bundle.output)")
        // #0434: no dylib in Contents/MacOS (the Release shape), so the
        // bundle keeps the hardened runtime #0418 measured.
        #expect(bundle.output.contains("flags=0x10002(adhoc,runtime)"), "Release-shaped bundle lost the hardened runtime: \(bundle.output)")

        // `--deep` never reaches Contents/Resources/bin, so the CLI must be
        // re-signed explicitly; BrokerAgent likewise. Linker-signed means the
        // script skipped it.
        for nested in ["Contents/Resources/bin/switchyard", "Contents/MacOS/BrokerAgent"] {
            let info = try run("/usr/bin/codesign", ["-dv", app.appendingPathComponent(nested).path])
            #expect(!info.output.contains("linker-signed"), "\(nested) left linker-signed: \(info.output)")
            #expect(info.output.contains("adhoc,runtime"), "\(nested) not ad-hoc with hardened runtime: \(info.output)")
        }
    }

    /// #0434: builds `<dir>/Fake.app` shaped like an unsigned **Debug**
    /// build — a stub main executable that links
    /// `@rpath/Fake.debug.dylib` in `Contents/MacOS`, the split Xcode makes
    /// when `ENABLE_DEBUG_DYLIB = YES`. Both Mach-Os come straight from the
    /// linker, as in the real build.
    private func makeDebugDylibBundle(in dir: URL) throws -> URL {
        let app = dir.appendingPathComponent("Fake.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let librarySource = dir.appendingPathComponent("lib.c")
        try Data("int fake_debug_value(void) { return 7; }\n".utf8).write(to: librarySource)
        let mainSource = dir.appendingPathComponent("main.c")
        try Data("int fake_debug_value(void);\nint main(void) { return fake_debug_value() == 7 ? 0 : 1; }\n".utf8)
            .write(to: mainSource)
        let dylib = macOS.appendingPathComponent("Fake.debug.dylib")
        let linkedLibrary = try run("/usr/bin/xcrun", [
            "clang", "-dynamiclib", librarySource.path, "-o", dylib.path,
            "-install_name", "@rpath/Fake.debug.dylib",
        ])
        try #require(linkedLibrary.status == 0, "clang -dynamiclib failed: \(linkedLibrary.output)")
        let linkedMain = try run("/usr/bin/xcrun", [
            "clang", mainSource.path, dylib.path, "-o", macOS.appendingPathComponent("Fake").path,
            "-Wl,-rpath,@executable_path",
        ])
        try #require(linkedMain.status == 0, "clang failed: \(linkedMain.output)")
        let info: [String: Any] = [
            "CFBundleExecutable": "Fake",
            "CFBundleIdentifier": "test.adhoc-seal.fake-debug",
            "CFBundlePackageType": "APPL",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    /// #0434: sealing must leave a Debug-shaped bundle LAUNCHABLE, not just
    /// verifiable. With `--options runtime` on the main executable, library
    /// validation refuses the ad-hoc debug dylib and dyld aborts the process
    /// (exit 134, "different Team IDs") while `codesign --verify` still
    /// passes. The fixture's executable is a four-line C program, not the
    /// app.
    @Test func sealedDebugDylibBundleStillLaunches() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adhoc-seal-debug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeDebugDylibBundle(in: dir)

        let sealed = try run("/bin/zsh", [repoRoot.appendingPathComponent("scripts/adhoc-seal-app.sh").path, app.path])
        #expect(sealed.status == 0, "adhoc-seal-app.sh failed: \(sealed.output)")

        let launched = try run(app.appendingPathComponent("Contents/MacOS/Fake").path, [])
        #expect(launched.status == 0, "sealed Debug-shaped bundle did not launch: \(launched.output)")
        #expect(!launched.output.contains("Library not loaded"), "dyld refused the debug dylib: \(launched.output)")

        let main = try run("/usr/bin/codesign", ["-dv", app.appendingPathComponent("Contents/MacOS/Fake").path])
        #expect(main.output.contains("Signature=adhoc"), "main executable not ad-hoc signed: \(main.output)")
        #expect(!main.output.contains("runtime"), "main executable kept the hardened runtime: \(main.output)")
    }

    @Test func refusesAPathThatIsNotABundle() throws {
        let result = try run("/bin/zsh", [
            repoRoot.appendingPathComponent("scripts/adhoc-seal-app.sh").path,
            FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString).app").path,
        ])
        #expect(result.status != 0)
        #expect(result.output.contains("not an app bundle"))
    }

    /// The seal must be the app target's LAST build phase — after the CLI
    /// and the broker are embedded — or it seals a bundle that is then
    /// modified, which invalidates the signature.
    @Test func xcodeProjectSealsAfterEveryEmbedPhase() throws {
        let pbxproj = try String(
            contentsOf: repoRoot.appendingPathComponent("Switchyard.xcodeproj/project.pbxproj"), encoding: .utf8)
        let phases = """
            59893A6AA309E3A9BC46E7F4 /* Embed Broker Agent Plist */,
            \t\t\t\t0418A0000000000000000001 /* Ad-hoc seal (unsigned builds) */,
            \t\t\t);
            """
        #expect(pbxproj.contains(phases), "the ad-hoc seal phase is not the app target's last build phase")
        #expect(pbxproj.contains("scripts/adhoc-seal-app.sh"))
        #expect(pbxproj.contains("CODE_SIGNING_ALLOWED:-YES}\\\" != \\\"NO\\\""),
                "the seal phase must be skipped when Xcode signs the build")
    }

    /// `xcodebuild archive` strips the binaries after the seal phase ran,
    /// which leaves "invalid signature (code or signature have been
    /// modified)" — measured 2026-09-26. make-release.sh re-seals the staged
    /// artifact and then verifies it.
    @Test func makeReleaseReSealsAndVerifiesTheArtifact() throws {
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/make-release.sh"), encoding: .utf8)
        #expect(script.contains(#"scripts/adhoc-seal-app.sh" "$ARTIFACT""#))
        #expect(script.contains(#"codesign --verify --deep --strict "$ARTIFACT""#))
    }
}
