# ExamplesSmoke — compiler-stable mirror for CI

Files under `ExamplesSmoke/` exist for one reason: to keep the
public InnoRouter surface compiling under
[`scripts/principle-gates.sh`](../scripts/principle-gates.sh) on
every commit, including one downstream expansion through the default
macro-first umbrella.

They are **not** documentation. Adopters should read
[`Examples/`](../Examples/) instead — that's where the idiomatic,
macro-driven code lives.

## What belongs here

- Plain Swift covering the same public symbols that the matching
  `Examples/<Name>Example.swift` exercises.
- Conservative runtime patterns in the ordinary mirrors.
- `MacrosSmoke.swift` mirrors `Examples/MacrosExample.swift` and deliberately
  proves that `import InnoRouter` exposes `@Router`, `@TabItem`, `@DeepLink`,
  `@Routable`, and `@CasePathable` without a second product or import.
- Smoke-only files that exercise surface area not yet narrated by an
  example. These are listed in
  [`scripts/check-examples-parity.sh`](../scripts/check-examples-parity.sh)
  under `SMOKE_ONLY_ALLOWLIST` (today: `ModalSmoke.swift`).

## What does NOT belong here

- Macro edge cases. Expansion diagnostics and detailed behavior coverage live
  in `Tests/InnoRouterMacrosTests/` and
  `Tests/InnoRouterMacrosBehaviorTests/`; this directory keeps only the
  downstream consumer smoke.
- Comments explaining the InnoRouter API. Smoke files are CI fixtures,
  not tutorials — keep prose minimal.
- Any pattern an adopter would not realistically write.

## When to edit which side

See the table in [`Examples/README.md`](../Examples/README.md#when-to-edit-which-side).
The short rule:

> If a public symbol changes, both sides change.

## Adding a new smoke fixture

| Reason | New `<Name>Smoke.swift` | New `<Name>Example.swift` | New manifest target |
| --- | --- | --- | --- |
| Mirror an existing example | ✅ | already exists | ✅ (`InnoRouter<Name>ExampleSmoke` if solo, or fold into `InnoRouterExamplesSmoke`) |
| Cover surface that has no example yet | ✅ + add to `SMOKE_ONLY_ALLOWLIST` | ➖ | ✅ |
| Compile-stability regression test | ✅ + allowlist | ➖ | ✅ |

The `SMOKE_ONLY_ALLOWLIST` is intentionally short — the default
expectation is one-to-one with `Examples/`. Adding a name there
should come with a comment in `check-examples-parity.sh` explaining
why no narrative example exists yet.

## Build / verify locally

```bash
swift build --target InnoRouterExamplesSmoke
swift build --target InnoRouter<Name>ExampleSmoke   # solo smokes
swift build --target InnoRouterMacroFirstSmoke
./scripts/check-examples-parity.sh
```

See [`Docs/CI-gates.md`](../Docs/CI-gates.md#gates) for how the
smoke build fits into the principle-gates pipeline.
