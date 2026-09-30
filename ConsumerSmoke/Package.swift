// swift-tools-version: 6.3

import Foundation
import PackageDescription

let innoRouterDependency: Package.Dependency

// SwiftPM derives a dependency's identity differently per form, and the two
// branches below do not agree. A remote dependency takes it from the URL's
// last path component, which is always `InnoRouter`. A path dependency takes
// it from the directory name, which is the repository name in a normal
// checkout but the worktree name inside a `git worktree`. Each branch
// therefore records the identity its own dependency will resolve to.
let innoRouterPackage: String

if let version = ProcessInfo.processInfo.environment["INNOROUTER_CONSUMER_VERSION"] {
    guard let exactVersion = Version(version) else {
        fatalError("INNOROUTER_CONSUMER_VERSION must be a valid semantic version")
    }
    innoRouterDependency = .package(
        url: "https://github.com/InnoSquadCorp/InnoRouter.git",
        exact: exactVersion
    )
    innoRouterPackage = "InnoRouter"
} else {
    innoRouterDependency = .package(path: "..")
    innoRouterPackage = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .lastPathComponent
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
            name: "AccountFeature",
            dependencies: [
                .product(name: "InnoRouter", package: innoRouterPackage),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SearchFeature",
            dependencies: [
                .product(name: "InnoRouter", package: innoRouterPackage),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FeatureCompositionConsumer",
            dependencies: [
                "AccountFeature",
                "SearchFeature",
                .product(name: "InnoRouter", package: innoRouterPackage),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "InnoRouterMacroFirstExternalConsumer",
            dependencies: [
                .product(name: "InnoRouter", package: innoRouterPackage),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AvailabilityNegativeConsumer",
            dependencies: [
                "InnoRouterMacroFirstExternalConsumer",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ConditionalFeatureNegativeConsumer",
            dependencies: [
                .product(name: "InnoRouter", package: innoRouterPackage),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "InnoRouterDeveloperToolsExternalConsumerTests",
            dependencies: [
                "InnoRouterMacroFirstExternalConsumer",
                "FeatureCompositionConsumer",
                .product(name: "InnoRouter", package: innoRouterPackage),
                .product(name: "InnoRouterInspector", package: innoRouterPackage),
                .product(name: "InnoRouterTesting", package: innoRouterPackage),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
