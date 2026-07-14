# Macro-generated access levels

InnoRouter macros infer generated member visibility from the attached enum.
They do not widen an internal route into public API.

## `@Routable` and `@CasePathable`

For every `@Routable` (or `@CasePathable`) enum the macros emit:

- `enum Cases { … }` containing one `static let` per case.
- `func is(_ casePath:) -> Bool`.
- `subscript(case:) -> Value?`.

The access keyword applied to `Cases`, every case-path member, `is(_:)`, and
`subscript(case:)` is inferred from the enclosing enum:

| Enum modifier | Generated members |
|---|---|
| `public enum Foo` | `public` |
| `package enum Foo` | `package` |
| `internal enum Foo` (or no modifier) | `internal` |
| `fileprivate enum Foo` | `fileprivate` |
| `private enum Foo` | `fileprivate` (the narrowest level that remains reachable across the macro expansion) |

Each case `static let` also receives any `@available(...)` attribute attached
to the enum case, so a case gated on an OS version does not produce a
`CasePath` member with wider availability than the underlying case.

## `@Router`

``Router()`` adds `@MainActor` and `@ViewBuilder` to the developer-declared
instance `destination` property. It does not change that property's declared
access level.

The generated `static destination(for:)` protocol witness follows the enum's
effective access level. This means a public router can keep the instance hook
private while exposing only the witness required by ``DestinationRoute``:

```swift compile
import SwiftUI
import InnoRouter

@Router
public enum PublicRoute {
    case settings

    private var destination: some View {
        Text("Settings")
    }
}
```

For a `private` enum, the generated witness uses `fileprivate`, matching the
case-path macros' same-file fallback. Do not declare `: DestinationRoute`
yourself; `@Router` supplies the conformance and warns when the direct
conformance is redundant.

## Compatibility for pre-OSS snapshots

Before the 4.0.0 OSS release, internal macro snapshots always emitted
case-path members as `public`. Teams that tested those snapshots should check
three patterns:

1. **Enum and CasePath usage already match.** No action is needed. Generated
   members tighten to match the enum, and same-module consumer code keeps
   compiling.
2. **A sibling module reads generated members from a non-public enum.** Mark
   the enum `public`; the old expansion was widening the surface implicitly.
3. **Enum cases are gated on `@available(...)`.** Generated `CasePath` members
   now carry the same availability. Narrow the enclosing function or branch on
   `if #available(...)` at any downstream call site that used a wider window.

## Why `private` maps to `fileprivate`

Generated declarations can originate from distinct macro expansion roles.
Using `fileprivate` preserves same-file access between those declarations while
remaining narrower than module-wide `internal` visibility.

## Manual visibility control

The macros do not expose a visibility override. Mark the enclosing enum
`public` when its generated members must be public; otherwise generated members
follow the declaration's effective access level. If a generated surface is not
appropriate, remove the macro and write the conformance or case-path members
explicitly.
