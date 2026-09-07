# InnoRouter 6 examples

These examples are intentionally macro-first and compile against the single
public `InnoRouter` runtime product.

- `MacrosExample.swift` demonstrates the default host, native tabs and split
  view, presentations, and environment actions generated from `@Router`.
- `DeepLinkExample.swift` demonstrates fail-closed `@DeepLink` resolution in a
  macro-first host.

The matching files in `ExamplesSmoke/` are compiler-stable CI fixtures. The
independent package under `ConsumerSmoke/` proves the actual downstream product
boundary for the runtime, testing support, and inspector.

```bash
swift build --target InnoRouterMacrosExample
swift build --target InnoRouterDeepLinkExample
swift build --target InnoRouterMacroFirstSmoke
./scripts/external-consumer-smoke.sh
```
