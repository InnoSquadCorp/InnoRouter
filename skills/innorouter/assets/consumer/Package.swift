// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "RouterSkillConsumer",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18), .watchOS(.v11), .visionOS(.v2)],
    dependencies: [
        // Unreleased 7.0.0 candidate, captured from main. Not a release tag.
        .package(url: "https://github.com/InnoSquadCorp/InnoRouter.git",
                 revision: "851c63f095e49b700c3a0aa8152a3521a39977e7"),
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
