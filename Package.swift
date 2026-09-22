// swift-tools-version: 6.3

import PackageDescription
import CompilerPluginSupport

// MARK: - Example target helpers
//
// Every per-file example target has the identical shape:
// `path: <directory>`, exclude every sibling source, include only
// the named source, and default to the macro-first InnoRouter umbrella.
// Hand-rolling that for nine targets repeats
// the same exclude list nine times and is the source of every
// "added a new example, forgot to update sibling exclude lists"
// drift. The two helpers below collapse the boilerplate to a
// single call site that takes the file name, derives the exclude
// list from the directory contents declaratively, and keeps the
// rest of the manifest readable.

/// Human-facing examples for the canonical runtime surface.
private let exampleSources: [String] = [
    "MacrosExample.swift",
    "DeepLinkExample.swift",
    "TabRestorationExample.swift",
]

/// The umbrella-only macro fixture stays isolated so its dependency boundary
/// cannot be weakened by another example target.
private let soloSmokeSources: [String] = [
    "DeveloperToolsSmoke.swift",
    "MacrosSmoke.swift",
]

/// All smoke sources under `ExamplesSmoke/`. Used both to derive
/// the shared target's `sources` (everything not in
/// `soloSmokeSources`) and the per-file solo targets' `exclude`
/// lists.
private let smokeSources: [String] = [
    "DeepLinkSmoke.swift",
    "DeveloperToolsSmoke.swift",
    "MacrosSmoke.swift",
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
    dependencies: [Target.Dependency] = ["InnoRouter"]
) -> Target {
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
    source: String,
    dependencies: [Target.Dependency] = ["InnoRouter"]
) -> Target {
    .target(
        name: name,
        dependencies: dependencies,
        path: "ExamplesSmoke",
        exclude: smokeSources.filter { $0 != source } + ["README.md"],
        sources: [source],
        swiftSettings: [.swiftLanguageMode(.v6)]
    )
}

private let privacyManifestResources: [Resource] = [
    .process("PrivacyInfo.xcprivacy"),
]

private let inspectorResources: [Resource] = privacyManifestResources + [
    .process("Localizable.xcstrings"),
]

let package = Package(
    name: "InnoRouter",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
    ],
    products: [
        // InnoRouter 6 intentionally exposes one macro-first runtime product,
        // plus opt-in testing and inspector tools. The 5.x granular runtime,
        // effect, scene, spatial, and macro products are no longer separate
        // dependency choices.
        .library(
            name: "InnoRouter",
            targets: ["InnoRouter"]
        ),
        .library(
            name: "InnoRouterInspector",
            targets: ["InnoRouterInspector"]
        ),
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
        .package(url: "https://github.com/swiftlang/swift-syntax.git", .upToNextMinor(from: "604.0.0")),
    ],
    targets: [
        // MARK: - Macro Host Route-Pattern Grammar
        //
        // Package-only host target for compiler-plugin validation. The runtime
        // keeps an identical source copy inside InnoRouterDeepLink because a
        // downstream SwiftPM build cannot use one target as both a macro-host
        // dependency and a runtime dependency. A lint gate enforces byte-for-
        // byte parity between the two grammar files.
        .target(
            name: "InnoRouterPatternSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

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
            dependencies: ["InnoRouterCore", "InnoRouterDeepLink"],
            resources: privacyManifestResources,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Apple System Surfaces
        .target(
            name: "InnoRouterSystem",
            dependencies: [
                "InnoRouterCore",
                "InnoRouterDeepLink",
                "InnoRouterSwiftUI",
            ],
            resources: privacyManifestResources,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Developer Inspector Target
        .target(
            name: "InnoRouterInspector",
            dependencies: [
                "InnoRouterCore",
                "InnoRouterDeepLink",
                "InnoRouterSwiftUI",
            ],
            resources: inspectorResources,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Umbrella Target
        .target(
            name: "InnoRouter",
            dependencies: ["InnoRouterCore", "InnoRouterSwiftUI", "InnoRouterDeepLink", "InnoRouterMacros", "InnoRouterSystem"],
            path: "Sources/InnoRouterUmbrella",
            resources: privacyManifestResources,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Release-mode runtime baselines for the canonical v6 engine. This is
        // an executable gate, never a selectable library product.
        .executableTarget(
            name: "InnoRouterPerformanceSmoke",
            dependencies: [
                "InnoRouterCore",
                "InnoRouterDeepLink",
                "InnoRouterInspector",
                "InnoRouterSwiftUI",
                "InnoRouterTesting",
            ],
            path: "Sources/InnoRouterPerformanceSmoke",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Contract Probe
        //
        // This executable intentionally crashes when `EnvironmentRouter` is
        // used without a matching host. `principle-gates.sh` asserts both the
        // non-zero exit and the actionable authority diagnostic.
        // This executable walks a recursive `@FeatureRoute` graph through every
        // generated deep-link entry point. Without a traversal guard the
        // generated contracts re-enter their own type until the stack
        // overflows; `principle-gates.sh` asserts the zero exit.
        .executableTarget(
            name: "RouterRecursiveDeepLinkProbe",
            dependencies: ["InnoRouter", "InnoRouterDeepLink"],
            path: "Sources/RouterRecursiveDeepLinkProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .executableTarget(
            name: "RouterEnvironmentFailFastProbe",
            dependencies: ["InnoRouterCore", "InnoRouterSwiftUI"],
            path: "Sources/RouterEnvironmentFailFastProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Example Build Gates (human-facing Examples/*.swift)
        //
        // Per-file targets ensure the same source users copy from `Examples/`
        // compiles against the public umbrella product.
        exampleTarget(name: "InnoRouterMacrosExample", source: "MacrosExample.swift"),
        exampleTarget(name: "InnoRouterDeepLinkExample", source: "DeepLinkExample.swift"),
        exampleTarget(name: "InnoRouterTabRestorationExample", source: "TabRestorationExample.swift"),

        // MARK: - Example Smoke Targets
        //
        // Deep-link and macro fixtures exercise the two canonical entry paths.
        .target(
            name: "InnoRouterExamplesSmoke",
            dependencies: ["InnoRouter"],
            path: "ExamplesSmoke",
            exclude: soloSmokeSources + ["README.md"],
            sources: smokeSources.filter { !soloSmokeSources.contains($0) },
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        soloSmokeTarget(
            name: "InnoRouterDeveloperToolsSmoke",
            source: "DeveloperToolsSmoke.swift",
            dependencies: ["InnoRouter", "InnoRouterInspector", "InnoRouterTesting"]
        ),
        soloSmokeTarget(name: "InnoRouterMacroFirstSmoke", source: "MacrosSmoke.swift"),

        // MARK: - Macro Declarations (Public API)
        .target(
            name: "InnoRouterMacros",
            dependencies: [
                "InnoRouterCore",
                "InnoRouterDeepLink",
                "InnoRouterSwiftUI",
                "InnoRouterMacrosPlugin",
            ],
            resources: privacyManifestResources,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Test Harness Target
        //
        // Ships `RouterTestStore` so consumers can assert the canonical
        // reduce/prepare/commit lifecycle host-lessly without `@testable import`.
        // Swift-Testing native (`Issue.record`).
        .target(
            name: "InnoRouterTesting",
            dependencies: ["InnoRouterCore", "InnoRouterSwiftUI", "InnoRouterInspector"],
            resources: privacyManifestResources,
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Macro Implementation (Compiler Plugin)
        .macro(
            name: "InnoRouterMacrosPlugin",
            dependencies: [
                "InnoRouterPatternSupport",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Tests
        .testTarget(
            name: "InnoRouterExampleTests",
            dependencies: ["InnoRouter", "InnoRouterTabRestorationExample"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "InnoRouterTests",
            dependencies: ["InnoRouter", "InnoRouterDeepLink", "InnoRouterSwiftUI", "InnoRouterSystem"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "InnoRouterInspectorTests",
            dependencies: ["InnoRouter", "InnoRouterInspector"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // This target is intentionally macro-free. Xcode flattens a root
        // package test target's macro dependency into the simulator test
        // bundle and attempts to link the host-only plugin object. tvOS and
        // watchOS runtime tests stay here; visionOS public/runtime integration
        // runs from ConsumerSmoke as a real downstream package dependency.
        .testTarget(
            name: "InnoRouterPlatformTests",
            dependencies: ["InnoRouterCore", "InnoRouterDeepLink", "InnoRouterSwiftUI"],
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
                "InnoRouterDeepLink",
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
                "InnoRouterInspector",
                "InnoRouter",
                "InnoRouterSwiftUI",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
