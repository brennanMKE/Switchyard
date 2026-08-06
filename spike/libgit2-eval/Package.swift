// swift-tools-version: 6.3
// SPIKE — throwaway. Deleted by #0005. Do not build on this.
//
// Route A under evaluation for #0001: systemLibrary target + Homebrew.

import PackageDescription

let package = Package(
    name: "libgit2-eval",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(
            name: "Clibgit2",
            path: "Sources/Clibgit2",
            pkgConfig: "libgit2",
            providers: [.brew(["libgit2"])]
        ),
        .executableTarget(
            name: "eval",
            dependencies: ["Clibgit2"],
            path: "Sources/eval"
        ),
        .executableTarget(
            name: "perf",
            dependencies: ["Clibgit2"],
            path: "Sources/perf"
        ),
    ]
)
