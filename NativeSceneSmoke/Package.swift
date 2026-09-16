// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "RouterNativeSceneProbe",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "RouterNativeSceneProbe",
            dependencies: [.product(name: "InnoRouter", package: "InnoRouter")]
        ),
        .executableTarget(
            name: "RouterInspectorProbe",
            dependencies: [
                .product(name: "InnoRouter", package: "InnoRouter"),
                .product(name: "InnoRouterInspector", package: "InnoRouter"),
                .product(name: "InnoRouterTesting", package: "InnoRouter"),
            ]
        ),
    ]
)
