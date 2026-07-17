// swift-tools-version: 6.3

import Foundation
import PackageDescription

let innoRouterDependency: Package.Dependency

if let version = ProcessInfo.processInfo.environment["INNOROUTER_CONSUMER_VERSION"] {
    guard let exactVersion = Version(version) else {
        fatalError("INNOROUTER_CONSUMER_VERSION must be a valid semantic version")
    }

    innoRouterDependency = .package(
        url: "https://github.com/InnoSquadCorp/InnoRouter.git",
        exact: exactVersion
    )
} else {
    innoRouterDependency = .package(path: "..")
}

let package = Package(
    name: "InnoRouterConsumerSmoke",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    dependencies: [innoRouterDependency],
    targets: [
        .target(
            name: "InnoRouterMacroFirstExternalConsumer",
            dependencies: [
                .product(name: "InnoRouter", package: "InnoRouter"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "InnoRouterSpatialExternalConsumer",
            dependencies: [
                .product(name: "InnoRouterSpatial", package: "InnoRouter"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "InnoRouterSpatialExternalConsumerTests",
            dependencies: [
                "InnoRouterSpatialExternalConsumer",
                .product(name: "InnoRouterCore", package: "InnoRouter"),
                .product(name: "InnoRouterSpatial", package: "InnoRouter"),
                .product(name: "InnoRouterSwiftUI", package: "InnoRouter"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
