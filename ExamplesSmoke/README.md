# InnoRouter 6 smoke fixtures

These are compiler fixtures, not tutorials.

- `MacrosSmoke.swift` proves that one `import InnoRouter` exposes the macro,
  generated route metadata, canonical store, hosts, snapshots, and actions.
- `DeepLinkSmoke.swift` proves generated typed URL resolution through the same
  umbrella product.
- `DeveloperToolsSmoke.swift` proves the optional testing and inspector
  products compose with the canonical runtime on every supported platform.

```bash
swift build --target InnoRouterMacroFirstSmoke
swift build --target InnoRouterExamplesSmoke
swift build --target InnoRouterDeveloperToolsSmoke
```
