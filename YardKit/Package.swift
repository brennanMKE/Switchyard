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
        .executableTarget(
            name: "switchyard",
            dependencies: ["YardKit"],
            path: "Sources/switchyard"
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
