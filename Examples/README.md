# Examples — human-facing, idiomatic surface

Files under `Examples/` exist to **show how a real adopter writes
code against the latest InnoRouter surface**. They are read by
new users, copied into apps, and rendered in the README.

Each `Examples/<Name>Example.swift` has a 1:1 partner under
`ExamplesSmoke/<Name>Smoke.swift` (see
[`ExamplesSmoke/README.md`](../ExamplesSmoke/README.md) for the
counterpart's rules). The
[`scripts/check-examples-parity.sh`](../scripts/check-examples-parity.sh)
gate enforces that pairing.

## What belongs here

- Complete, idiomatic snippets that build standalone.
- Macro-driven surface (`@Router`, `RouterHost`,
  `@EnvironmentRouter`, …) as the default simple path, with the lower-level
  store and intent APIs where the example genuinely needs them — see
  [`MacrosExample.swift`](MacrosExample.swift).
- The full headline feature surface (deep-link pipeline + auth
  policy + flow projection + middleware) where the example narrates a
  real adoption path — see
  [`SampleAppExample.swift`](SampleAppExample.swift).

## What does NOT belong here

- Speculative or aspirational APIs that have not landed yet.
- Code that depends on private helpers (`@_spi`, internal-only
  protocols).
- Large unrelated features bundled into one example file. Add a new
  `<Name>Example.swift` (and its smoke partner) instead.

## When to edit which side

| Change | Edit `Examples/` | Edit `ExamplesSmoke/` |
| --- | --- | --- |
| Rename a public symbol | ✅ | ✅ |
| Add a new macro-driven surface | ✅ (idiomatic example) | ✅ in `MacrosSmoke.swift` when the default consumer contract changes |
| Add a non-macro public API used in multiple examples | ✅ | ✅ |
| Add a one-off compile-stability regression test | ➖ | ✅ (`*Smoke.swift` only) |
| Bug fix in narrative prose / comments | ✅ | ➖ |
| Add a brand-new example | ✅ (new `<Name>Example.swift`) | ✅ (new `<Name>Smoke.swift` + `Package.swift` target + `principle-gates.sh` build entry) |

When you add a new `<Name>Example.swift`, the parity gate also
requires:

1. `ExamplesSmoke/<Name>Smoke.swift` — compiler-stable mirror.
2. A target named `InnoRouter<Name>Example` in `Package.swift`.
3. A `swift build --target InnoRouter<Name>Example` line in
   `scripts/principle-gates.sh` under the *human-facing example
   targets* block.

Skipping any of those three fails the parity gate.

## Build / verify locally

```bash
swift build --target InnoRouter<Name>Example
./scripts/check-examples-parity.sh
```

The full pipeline runs through
[`scripts/principle-gates.sh`](../scripts/principle-gates.sh) —
see [`Docs/CI-gates.md`](../Docs/CI-gates.md) for the complete gate
list.
