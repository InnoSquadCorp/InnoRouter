# Macro Dependency Cost Measurement

Date: 2026-07-15

Purpose: record the build-cost trade-off after making `@Router` part of the
default `InnoRouter` product for 5.0. The macro-first default favors adoption
DX; granular products remain the escape hatch for targets that value a smaller
build graph more than the generated declaration surface.

## Environment

```text
swift-driver version: 1.148.6 Apple Swift version 6.3.3
(swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
```

## Commands

```bash
swift package show-traits
/usr/bin/time -p swift build --target InnoRouter
/usr/bin/time -p swift build --target InnoRouterSwiftUI
/usr/bin/time -p swift build --target InnoRouterMacros

swift build --scratch-path <fresh-directory> --target InnoRouter --disable-automatic-resolution
swift build --scratch-path <fresh-directory> --target InnoRouterSwiftUI --disable-automatic-resolution
```

`swift package show-traits` exited successfully and printed no traits.

## Results

These local measurements are directional. The machine had active endpoint
security and simulator processes, so the absolute wall-clock values are not a
release budget.

| Build | Graph | real | user | sys |
|---|---|---:|---:|---:|
| Incremental `InnoRouter` | default macro-first umbrella | 4.38s | 1.23s | 0.67s |
| Incremental `InnoRouterSwiftUI` | granular runtime | 1.38s | 0.36s | 0.18s |
| Incremental `InnoRouterMacros` | granular macro surface | 4.69s | 1.21s | 0.69s |
| Fresh scratch `InnoRouter` | runtime + deep link + macro plugin | 46.90s | 84.06s | 22.77s |
| Fresh scratch `InnoRouterSwiftUI` | runtime, no plugin target build | 26.70s | 28.89s | 15.20s |

Both fresh scratch builds still fetched or created the package-level
`swift-syntax` working copy because it is declared in this package manifest.
Only the default umbrella built the compiler-plugin targets. In this run that
added about 20 seconds of wall time and 63 seconds of combined user/system CPU
time to a clean target build; warm builds reduced the absolute difference.

## Decision

Keep `InnoRouter` macro-first for 5.0:

- a normal app adds the `InnoRouter` product and uses `import InnoRouter`
- `@Router`, `RouterHost`, and `@EnvironmentRouter` form the default path
- a dedicated `InnoRouterMacroFirstSmoke` target proves that contract using no
  direct `InnoRouterMacros` dependency
- `InnoRouterCore`, `InnoRouterSwiftUI`, and `InnoRouterDeepLink` remain
  granular runtime products whose target build graphs omit the macro plugin

The measured clean-build cost is real and should be revisited if consumer
reports show it blocking adoption. A package trait or separate macro package
would be justified only with evidence that the granular products are not an
adequate escape hatch.

## Operating guidance

Re-run both fresh-scratch and incremental comparisons when bumping
`swift-syntax`, changing the umbrella graph, or changing the supported Swift
toolchain. Record wall and CPU time; wall time alone can hide parallel
SwiftSyntax compilation.

If tests fail at link time with a missing
`SwiftSyntaxMacrosTestSupport.assertMacroExpansion` symbol, first rule out stale
SwiftPM artifacts:

```bash
swift package clean
swift test
```

If the failure persists, verify a clean source build:

```bash
swift test \
  --scratch-path /tmp/innorouter-clean-scratch \
  --disable-experimental-prebuilts \
  --disable-automatic-resolution
```
