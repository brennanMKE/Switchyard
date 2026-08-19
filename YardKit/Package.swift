// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "YardKit",
    // Matches the app target's MACOSX_DEPLOYMENT_TARGET. Declaring v15 linked
    // against a Homebrew libgit2 built for 26.0 and warned on every build.
    platforms: [.macOS(.v26)],
    products: [
        // The engine. Every git operation shells out through GitProcess; see #0103
        // for the libgit2 work, which is not a dependency of anything yet.
        .library(name: "YardGit", targets: ["YardGit"]),
        // Everything shared between the app, the broker, and the CLI.
        .library(name: "YardKit", targets: ["YardKit"]),
        // Views for the macOS app. Hosted in a package so they can be tested with
        // `swift test`, since UI tests cannot run under CLI-driven xcodebuild.
        .library(name: "YardUI", targets: ["YardUI"]),
        // Linked by the app; deliberately NOT a dependency of `switchyard`.
        .library(name: "YardCommands", targets: ["YardCommands"]),
        .executable(name: "switchyard", targets: ["switchyard"]),
    ],
    targets: [
        .target(
            name: "YardGit",
            dependencies: [],
            path: "Sources/YardGit"
        ),
        .target(
            name: "YardKit",
            dependencies: [],
            path: "Sources/YardKit"
        ),
        .target(
            name: "YardUI",
            dependencies: ["YardKit", "YardGit"],
            path: "Sources/YardUI",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Engine-backed command arms. Depends on BOTH the engine and the
        // envelope layer, and is linked by the app alone — guide §11 decision
        // 15. It exists so a command that opens a repository can be reached
        // from `swift test`: it cannot live in YardKit, which the CLI links,
        // and code in the app target has no test that can run here.
        .target(
            name: "YardCommands",
            dependencies: ["YardGit", "YardKit"],
            path: "Sources/YardCommands"
        ),
        .executableTarget(
            name: "switchyard",
            dependencies: ["YardKit"],
            path: "Sources/switchyard"
        ),
        // Development-only harness: links YardCommands (and therefore
        // YardGit) in-process so the engine can be run from the command line
        // before the app exists to talk to over XPC. `switchyard` above
        // stays XPC-only on purpose (guide §11 decision 11) -- this target
        // is the "other way to run it" #0337 adds alongside it, not a
        // replacement.
        .executableTarget(
            name: "yard-engine",
            dependencies: ["YardCommands", "YardKit"],
            path: "Sources/yard-engine"
        ),
        .testTarget(
            name: "YardGitTests",
            dependencies: ["YardGit"],
            path: "Tests/YardGitTests"
        ),
        .testTarget(
            name: "YardKitTests",
            dependencies: ["YardKit"],
            path: "Tests/YardKitTests"
        ),
        .testTarget(
            name: "YardCommandsTests",
            // YardKit too: #0337's composition test calls runYard directly
            // to assert the yard-engine fallback (runEngineCommand ??
            // runYard) without needing the executable target itself, which
            // SwiftPM does not allow a test target to depend on. YardGit for
            // FixtureRepository (#0343): the composition tests build their
            // own repository rather than depending on the test process's cwd.
            dependencies: ["YardCommands", "YardKit", "YardGit"],
            path: "Tests/YardCommandsTests"
        ),
        .testTarget(
            name: "YardUITests",
            // YardGit for FixtureRepository, which #0339's loader test needs
            // to build a real repository to load. YardKit for
            // ServiceNames.journalRefPrefix, which #0081's sidebar loader
            // test needs so it does not hardcode the journal ref namespace
            // string itself (ServiceNamesTests.noOtherSwiftSourceHardcodesTheIdentifiers).
            dependencies: ["YardUI", "YardGit", "YardKit"],
            path: "Tests/YardUITests"
        ),
        // Wire-shape tests: engine payloads encoding through YardKit's
        // envelope (#0129). The one test target that depends on both sides of
        // the boundary, on purpose. Imports are NOT @testable: the wire is a
        // public-caller contract, and @testable would mask a conformance that
        // silently dropped to internal (the #0116 failure class).
        .testTarget(
            name: "YardWireTests",
            dependencies: ["YardGit", "YardKit"],
            path: "Tests/YardWireTests"
        ),
        // Tests in this target import YardGit WITHOUT @testable so that any
        // member which silently drops back to internal is caught at compile-time
        // rather than passing in @testable-masked code. If this target doesn't
        // build, the public API contract is broken — see issue #0116.
        .testTarget(
            name: "YardGitPublicAPITests",
            dependencies: ["YardGit"],
            path: "Tests/YardGitPublicAPITests"
        ),
    ]
)
