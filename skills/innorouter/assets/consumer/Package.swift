// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "RouterSkillConsumer",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18), .watchOS(.v11), .visionOS(.v2)],
    dependencies: [
        // Published 7.0.0; Package.resolved and support.json bind the reviewed commit.
        .package(url: "https://github.com/InnoSquadCorp/InnoRouter.git",
                 exact: "7.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
    ],
    targets: [
        .target(name: "RouterSkillExample", dependencies: [
            .product(name: "InnoRouter", package: "InnoRouter"),
        ]),
        .testTarget(name: "RouterSkillExampleTests", dependencies: [
            "RouterSkillExample",
            .product(name: "InnoRouterTesting", package: "InnoRouter"),
        ]),
    ]
)
