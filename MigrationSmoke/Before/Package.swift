// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "InnoRouterMigrationBefore",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(
            url: "https://github.com/InnoSquadCorp/InnoRouter.git",
            exact: "5.2.1"
        ),
    ],
    targets: [
        .executableTarget(
            name: "LegacyMigrationProbe",
            dependencies: [
                .product(name: "InnoRouter", package: "InnoRouter"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
