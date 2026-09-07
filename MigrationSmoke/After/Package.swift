// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "InnoRouterMigrationAfter",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "CanonicalMigrationProbe",
            dependencies: [
                .product(name: "InnoRouter", package: "InnoRouter"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
