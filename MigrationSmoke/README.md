# 5.2.1 to 6.0 migration smoke

This pair is intentionally two independent downstream packages.

- `Before` resolves the exact published `5.2.1` tag and executes the former
  `NavigationStore` / `NavigationCommand` stack scenario.
- `After` resolves the current checkout, keeps the route declaration
  macro-first, and executes the equivalent scenario through `RouterStore` /
  `RouterAction`.

`scripts/migration-consumer-smoke.sh` builds and runs both, compares their
encoded final path, and also checks the expected semantic result. It is
migration evidence, not a compatibility shim: no 5.x authority is restored to
the 6.0 product.
