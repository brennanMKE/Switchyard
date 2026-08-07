// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "YardKit",
    // Matches the app target's MACOSX_DEPLOYMENT_TARGET. Declaring v15 linked
    // against a Homebrew libgit2 built for 26.0 and warned on every build.
    platforms: [.macOS(.v26)],
    products: [
        // The engine. Standalone by design: no XPC, no app, no launch agent.
        .library(name: "YardGit", targets: ["YardGit"]),
        // Everything shared between the app, the broker, and the CLI.
        .library(name: "YardKit", targets: ["YardKit"]),
        .executable(name: "switchyard", targets: ["switchyard"]),
    ],
    targets: [
        // libgit2 comes in through a system library target for development.
        // This route depends on Homebrew and therefore cannot ship — a
        // prebuilt xcframework replaces it before the CLI is embedded in the
        // app bundle (#0050). See docs/engine-findings.md, route A vs B.
        .systemLibrary(
            name: "Clibgit2",
            path: "Sources/Clibgit2",
            pkgConfig: "libgit2",
            providers: [.brew(["libgit2"])]
        ),
        .target(
            name: "YardGit",
            dependencies: ["Clibgit2"],
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
    ]
)
