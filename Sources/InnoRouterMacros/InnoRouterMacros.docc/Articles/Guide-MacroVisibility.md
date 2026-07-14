# `@Routable` / `@CasePathable` access level inference

Starting in 4.0.0 the `@Routable` and `@CasePathable` macros
infer the access level of every generated member from the
enclosing enum. The previous behaviour emitted everything as
`public`, which leaked CasePath surface for `internal` and
`private` enums that never intended that visibility.

## What gets generated, and at what level

For every `@Routable` (or `@CasePathable`) enum the macros emit:

- `enum Cases { … }` containing one `static let` per case.
- `func is(_ casePath:) -> Bool`.
- `subscript(case:) -> Value?`.

The access keyword applied to all four is inferred from the
enclosing enum:

| Enum modifier | Generated members |
|---|---|
| `public enum Foo` | `public` |
| `package enum Foo` | `package` |
| `internal enum Foo` (or no modifier) | `internal` |
| `fileprivate enum Foo` | `fileprivate` |
| `private enum Foo` | `fileprivate` (lowest level the macro can emit while still letting same-file `is(_:)` and `subscript(case:)` callers reach the cases) |

Each case `static let` also receives any `@available(...)`
attribute attached to the enum case, so a case gated on an OS
version no longer produces a CasePath member with a wider
availability than the underlying case.

## Compatibility for pre-OSS snapshots

Before the 4.0.0 OSS release, internal macro snapshots always emitted
`public`. Teams that tested those snapshots should check three
patterns:

1. **Enum and CasePath usage already match.** No action — the
   generated members tighten to `internal` / `fileprivate` /
   `fileprivate` matching the enum and the consumer code keeps
   compiling because it was within the same module already.
2. **Enum is not `public` but a sibling module reads the
   generated CasePath members.** Mark the enum `public`. The
   pre-OSS behaviour was effectively widening the surface for you;
   4.0.0 makes the boundary explicit.
3. **Enum cases are gated on `@available(...)`.** The generated
   CasePath members now carry the same availability. If a
   downstream call site compiled under a wider availability
   window before, narrow the enclosing function or branch on
   `if #available(...)` to match.

## Why `private` enums emit `fileprivate`

Swift does not let an extension method (the macro emits
`is(_:)` / `subscript(case:)` as members on the enum itself,
not on a generated extension) reference a `private`
declaration in its own scope when that declaration came from
a distinct macro plugin call. Falling back to `fileprivate`
gives the same effective scope for any caller in the same file
without breaking the macro expansion.

## Opt-out

The macros do not expose a visibility override. Mark the enclosing
enum `public` when its generated members must be public; otherwise the
members follow the declaration's effective access level.
