// swift-tools-version: 6.3
import Foundation
import PackageDescription

// SwiftPM derives a path dependency's identity from its directory name, which
// is the repository name in a normal checkout but the worktree name inside a
// `git worktree`. Deriving it from the manifest's own location keeps this
// package resolvable from either.
let innoRouterPackage = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .lastPathComponent

let package = Package(
    name: "RouterNativeSceneProbe",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "RouterNativeSceneProbe",
            dependencies: [.product(name: "InnoRouter", package: innoRouterPackage)]
        ),
        .executableTarget(
            name: "RouterInspectorProbe",
            dependencies: [
                .product(name: "InnoRouter", package: innoRouterPackage),
                .product(name: "InnoRouterInspector", package: innoRouterPackage),
                .product(name: "InnoRouterTesting", package: innoRouterPackage),
            ]
        ),
    ]
)
