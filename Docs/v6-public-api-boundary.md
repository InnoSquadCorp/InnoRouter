# InnoRouter 6 Public API Boundary

## Default path

The supported first choice is deliberately small:

1. declare routes with `@Router` and case macros;
2. install one macro-first host;
3. mutate navigation through `EnvironmentRouter`;
4. observe it through `@EnvironmentRouterState`.

`RouterStore`, `RouterState`, `RouterAction`, `RouterPlan`, policies, snapshots,
and system catalogs are the canonical advanced layer behind that path. They
are not alternate navigation authorities.

## Product boundary

Only three library products are selectable:

- `InnoRouter` — the macro, canonical runtime, hosts, deep links, snapshots,
  and Apple system integrations;
- `InnoRouterTesting` — host-less transition assertions;
- `InnoRouterInspector` — opt-in, payload-redacted developer diagnostics.

The umbrella baseline is the union of `InnoRouterCore`,
`InnoRouterDeepLink`, `InnoRouterSwiftUI`, `InnoRouterMacros`, and
`InnoRouterSystem`. Omitting a re-exported canonical module from symbol
extraction is a gate failure.

## Freeze policy

The checked-in baselines detect any declaration change. A separate maximum
symbol budget prevents baseline regeneration from silently accepting API
growth:

| Product | Maximum symbols |
| --- | ---: |
| `InnoRouter` | 1,193 |
| `InnoRouterInspector` | 207 |
| `InnoRouterTesting` | 252 |

`Baselines/PublicAPI/symbol-budgets.tsv` is the machine-readable source for
these numbers, and the documentation gate rejects drift from this table. An
intentional addition therefore needs both a reviewed API diff and a deliberate
budget edit. Removal does not require lowering the budget in the same patch,
which leaves room to review the semantic change before tightening the ceiling.

Deep-link execution uses one public result vocabulary,
`RouterLinkExecution`. Hosts emit the same value returned by explicit store
handling; a second event enum is forbidden by the budget gate.

The release-tooling growth includes four umbrella symbols for runtime
version identity, typed snapshot migration, and Instruments signposts; eight
Inspector symbols for one diagnostic-bundle value and its recorder exports;
and eight Testing symbols for one versioned action-sequence value. The follow-up
boundary review adds one typed snapshot-version error, two Inspector symbols
for strict bundle decoding/import, and six Testing symbols for contextual
action steps. Sequence replay now uses each stored context, so the pre-release
`replay(on:context:)` surface becomes `replay(on:)`. None creates another state
authority or alternative routing vocabulary. The fixture schema is finalized
before the first 6.0.0 tag; unpublished action-only fixtures are not a supported
migration format.

The 6.1.0 snapshot boundary adds ten umbrella symbols for explicit
envelope/payload limits, typed size failures, and bounded file storage. Existing
initializers retain their 6.0 behavior; no new navigation authority or storage
selection is introduced.

Automatic partial restoration adds two umbrella symbols: one opt-in driver
initializer and one latest-attempt report. It reuses the existing Store,
validator, topology, transition, and persistence contracts.

Explicit persisted tab identity adds one `@TabItem` overload. The generated
typed tab and catalog stay unchanged; only the opt-in scope identity is
decoupled from the route case spelling.

Run both checks with:

```sh
./scripts/check-public-api.sh
./scripts/check-public-api-budget.sh
```

The release workflow must regenerate or verify the symbol graphs with the
pinned Swift 6.3 toolchain before publication.
