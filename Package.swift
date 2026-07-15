// swift-tools-version: 6.3

import PackageDescription
import CompilerPluginSupport

// MARK: - Example target helpers
//
// Every per-file example target has the identical shape:
// `path: <directory>`, exclude every sibling source, include only
// the named source, and depend on the macro-first InnoRouter umbrella.
// Hand-rolling that for nine targets repeats
// the same exclude list nine times and is the source of every
// "added a new example, forgot to update sibling exclude lists"
// drift. The two helpers below collapse the boilerplate to a
// single call site that takes the file name, derives the exclude
// list from the directory contents declaratively, and keeps the
// rest of the manifest readable.

/// All human-facing example sources under `Examples/`.
///
/// Order is informational only — `exampleTarget` builds an
/// exclude list out of "everything except the named source". Adding
/// or removing an entry here is the single edit needed to add or
/// remove an example target.
private let exampleSources: [String] = [
    "StandaloneExample.swift",
    "CoordinatorExample.swift",
    "DeepLinkExample.swift",
    "SplitCoordinatorExample.swift",
    "AppShellExample.swift",
    "MultiPlatformExample.swift",
    "VisionOSImmersiveExample.swift",
    "SampleAppExample.swift",
]

/// Smoke files that live in their own per-file targets because they either
/// declare colliding top-level symbols or enforce a deliberately narrow
/// dependency contract. Everything outside this list shares
/// `InnoRouterExamplesSmoke`.
private let soloSmokeSources: [String] = [
    "StandaloneSmoke.swift",
    "CoordinatorSmoke.swift",
    "MacrosSmoke.swift",
]

/// All smoke sources under `ExamplesSmoke/`. Used both to derive
/// the shared target's `sources` (everything not in
/// `soloSmokeSources`) and the per-file solo targets' `exclude`
/// lists.
private let smokeSources: [String] = [
    "AppShellSmoke.swift",
    "CoordinatorSmoke.swift",
    "DeepLinkSmoke.swift",
    "MacrosSmoke.swift",
    "ModalSmoke.swift",
    "MultiPlatformSmoke.swift",
    "SampleAppSmoke.swift",
    "SplitCoordinatorSmoke.swift",
    "StandaloneSmoke.swift",
    "VisionOSImmersiveSmoke.swift",
]

/// Build a per-file `Examples/` target. The exclude list is
/// derived from `exampleSources` so adding a new example only
/// requires appending its file name to `exampleSources` and adding
/// one `exampleTarget(...)` call here. `README.md` is excluded
/// explicitly because SwiftPM otherwise warns about unhandled files
/// when a contributor-facing README sits in the source path.
private func exampleTarget(
    name: String,
    source: String,
    additionalDependencies: [Target.Dependency] = []
) -> Target {
    let dependencies: [Target.Dependency] = ["InnoRouter"] + additionalDependencies

    return .target(
        name: name,
        dependencies: dependencies,
        path: "Examples",
        exclude: exampleSources.filter { $0 != source } + ["README.md"],
        sources: [source],
        swiftSettings: [.swiftLanguageMode(.v6)]
    )
}

/// Build a per-file `ExamplesSmoke/` target. Used for solo smokes whose
/// top-level symbols collide or whose dependency graph is itself under test.
/// `README.md` is excluded for the same reason as `exampleTarget`.
private func soloSmokeTarget(
    name: String,
    source: String
) -> Target {
    .target(
        name: name,
        dependencies: ["InnoRouter"],
        path: "ExamplesSmoke",
        exclude: smokeSources.filter { $0 != source } + ["README.md"],
        sources: [source],
        swiftSettings: [.swiftLanguageMode(.v6)]
    )
}

private let privacyManifestResources: [Resource] = [
    .process("PrivacyInfo.xcprivacy"),
]

let package = Package(
    name: "InnoRouter",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
    ],
    products: [
        // MARK: - Umbrella
        .library(
            name: "InnoRouter",
            targets: ["InnoRouter"]
        ),

        // MARK: - Core Runtime
        .library(
            name: "InnoRouterCore",
            targets: ["InnoRouterCore"]
        ),

        // MARK: - SwiftUI Integration
        .library(
            name: "InnoRouterSwiftUI",
            targets: ["InnoRouterSwiftUI"]
        ),

        // MARK: - Spatial Scene Integration
        .library(
            name: "InnoRouterSpatial",
            targets: ["InnoRouterSpatial"]
        ),

        // MARK: - DeepLink
        .library(
            name: "InnoRouterDeepLink",
            targets: ["InnoRouterDeepLink"]
        ),

        // MARK: - App-Boundary Effects
        .library(
            name: "InnoRouterEffects",
            targets: ["InnoRouterEffects"]
        ),

        // MARK: - Macros
        .library(
            name: "InnoRouterMacros",
            targets: ["InnoRouterMacros"]
        ),

        // MARK: - Test Harness
        .library(
            name: "InnoRouterTesting",
            targets: ["InnoRouterTesting"]
        ),
    ],
    dependencies: [
        // Swift Syntax for Macros.
        //
        // Pinned `upToNextMinor` because swift-syntax compatibility
        // is tracked by major release lines such as 602.x and 603.x.
        // The macro plugin uses SwiftSyntaxBuilder / SwiftDiagnostics
        // directly (see `MacroDiagnostic.swift`, `RoutableMacro.swift`),
        // so this constraint allows 603.0.x patch backports while
        // preventing a silent jump to the next major line. Dependabot
        // opens those updates explicitly so macro fixtures and
        // public-API baselines can move alongside the bump.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", .upToNextMinor(from: "603.0.2")),
    ],
    targets: [
        // MARK: - Core Runtime Target
        .target(
            name: "InnoRouterCore",
            resources: privacyManifestResources,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - DeepLink Target
        .target(
            name: "InnoRouterDeepLink",
            dependencies: ["InnoRouterCore"],
            resources: privacyManifestResources,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - SwiftUI Target
        .target(
            name: "InnoRouterSwiftUI",
            dependencies: ["InnoRouterCore"],
            resources: privacyManifestResources,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Spatial Scene Target
        .target(
            name: "InnoRouterSpatial",
            dependencies: ["InnoRouterCore"],
            resources: privacyManifestResources,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Umbrella Target
        .target(
            name: "InnoRouter",
            dependencies: ["InnoRouterCore", "InnoRouterSwiftUI", "InnoRouterDeepLink", "InnoRouterMacros"],
            path: "Sources/InnoRouterUmbrella",
            resources: privacyManifestResources,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Effects Target
        .target(
            name: "InnoRouterEffects",
            dependencies: [
                "InnoRouterCore",
                "InnoRouterDeepLink",
            ],
            path: "Sources/InnoRouterEffects",
            resources: privacyManifestResources,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Executable Target
        .executableTarget(
            name: "NavigationEnvironmentFailFastProbe",
            dependencies: ["InnoRouterCore", "InnoRouterSwiftUI"],
            path: "Sources/NavigationEnvironmentFailFastProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ChildCoordinatorFailFastProbe",
            dependencies: ["InnoRouterCore", "InnoRouterSwiftUI"],
            path: "Sources/ChildCoordinatorFailFastProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "InnoRouterPerformanceSmoke",
            dependencies: ["InnoRouter", "InnoRouterEffects"],
            path: "Sources/InnoRouterPerformanceSmoke",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Example Build Gates (human-facing Examples/*.swift)
        //
        // Per-file targets so that every example — the same source the README points
        // at — participates in `swift build`. Without this, macro-generated code in
        // `Examples/` is never exercised by a consumer site, so latent generator bugs
        // stay invisible until end-users hit them. The per-file split mirrors
        // `ExamplesSmoke/` because several examples reuse names like `HomeRoute`.
        // `exampleTarget(name:source:)` derives the exclude list from
        // `exampleSources` so adding a new example is a one-line append + one-line
        // call rather than nine sibling-list edits.
        exampleTarget(name: "InnoRouterStandaloneExample",       source: "StandaloneExample.swift"),
        exampleTarget(name: "InnoRouterCoordinatorExample",      source: "CoordinatorExample.swift"),
        exampleTarget(name: "InnoRouterDeepLinkExample",         source: "DeepLinkExample.swift"),
        exampleTarget(name: "InnoRouterSplitCoordinatorExample", source: "SplitCoordinatorExample.swift"),
        exampleTarget(name: "InnoRouterAppShellExample",         source: "AppShellExample.swift"),
        exampleTarget(name: "InnoRouterMultiPlatformExample",    source: "MultiPlatformExample.swift"),
        exampleTarget(
            name: "InnoRouterVisionOSImmersiveExample",
            source: "VisionOSImmersiveExample.swift",
            additionalDependencies: ["InnoRouterSpatial"]
        ),
        exampleTarget(
            name: "InnoRouterSampleAppExample",
            source: "SampleAppExample.swift",
            additionalDependencies: ["InnoRouterEffects"]
        ),

        // MARK: - Example Smoke Targets
        //
        // Most smoke files live in one shared target (`InnoRouterExamplesSmoke`)
        // because their top-level symbols don't collide. Two smokes
        // (`Standalone` and `Coordinator`) both declare `HomeRoute`, so they
        // stay in their own targets to avoid a module-level redeclaration.
        // `MacrosSmoke` stays solo to prove that the macro-first consumer
        // needs only the `InnoRouter` dependency. If a future smoke needs a
        // distinct name, add it to `smokeSources` and (if it does not collide
        // or enforce a narrower contract) leave it out of `soloSmokeSources`.
        .target(
            name: "InnoRouterExamplesSmoke",
            dependencies: ["InnoRouter", "InnoRouterEffects", "InnoRouterSpatial"],
            path: "ExamplesSmoke",
            exclude: soloSmokeSources + ["README.md"],
            sources: smokeSources.filter { !soloSmokeSources.contains($0) },
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        soloSmokeTarget(name: "InnoRouterStandaloneExampleSmoke",  source: "StandaloneSmoke.swift"),
        soloSmokeTarget(name: "InnoRouterCoordinatorExampleSmoke", source: "CoordinatorSmoke.swift"),
        soloSmokeTarget(name: "InnoRouterMacroFirstSmoke",          source: "MacrosSmoke.swift"),

        // MARK: - Macro Declarations (Public API)
        .target(
            name: "InnoRouterMacros",
            dependencies: ["InnoRouterCore", "InnoRouterSwiftUI", "InnoRouterMacrosPlugin"],
            resources: privacyManifestResources,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Test Harness Target
        //
        // Ships `NavigationTestStore`, `ModalTestStore`, and `FlowTestStore` so
        // consumers can assert navigation/modal/flow events host-lessly without
        // `@testable import`. Swift-Testing native (`Issue.record`).
        .target(
            name: "InnoRouterTesting",
            dependencies: ["InnoRouterCore", "InnoRouterSwiftUI"],
            resources: privacyManifestResources,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Macro Implementation (Compiler Plugin)
        .macro(
            name: "InnoRouterMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Tests
        .testTarget(
            name: "InnoRouterTests",
            dependencies: ["InnoRouter", "InnoRouterDeepLink", "InnoRouterEffects", "InnoRouterSwiftUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "InnoRouterSpatialTests",
            dependencies: ["InnoRouterCore", "InnoRouterSpatial"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "InnoRouterPlatformTests",
            dependencies: ["InnoRouterCore", "InnoRouterSwiftUI", "InnoRouterSpatial"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // InnoRouterMacrosPlugin is a CompilerPlugin built host-only
        // (macOS). Restricting this test target's dependencies to macOS
        // stops Xcode from pulling the macOS-built plugin .o into a
        // visionOS / tvOS / watchOS test binary linker step.
        // `@testable import InnoRouterMacrosPlugin` inside each test
        // file is additionally guarded by `#if
        // canImport(InnoRouterMacrosPlugin)` so the file is empty on
        // non-macOS platforms.
        .testTarget(
            name: "InnoRouterMacrosTests",
            dependencies: [
                .target(name: "InnoRouterMacrosPlugin", condition: .when(platforms: [.macOS])),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax", condition: .when(platforms: [.macOS])),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "InnoRouterMacrosBehaviorTests",
            dependencies: [
                // Macros product + plugin are host-only (macOS). Gate
                // the dependency so non-macOS test builds don't try to
                // link the macOS-built plugin .o into the test binary.
                // Each test file is additionally wrapped in
                // `#if canImport(InnoRouterMacrosPlugin)` so the module
                // is empty on non-macOS platforms.
                .target(name: "InnoRouterMacros", condition: .when(platforms: [.macOS])),
                "InnoRouterCore",
            ],
            // README.md documents the macOS-only constraint of this
            // target; it is human-facing only and must not be packaged
            // as a test resource.
            exclude: ["README.md"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "InnoRouterTestingTests",
            dependencies: [
                "InnoRouterTesting",
                "InnoRouter",
                "InnoRouterSwiftUI",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
