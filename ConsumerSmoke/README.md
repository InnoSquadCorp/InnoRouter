# External consumer smoke

This nested Swift package validates the InnoRouter 6 public boundary from a
real downstream package.

By default it resolves the local checkout:

```bash
./scripts/external-consumer-smoke.sh
```

After 6.0.0 is published, pass the bare semantic version to verify the exact
remote tag:

```bash
./scripts/external-consumer-smoke.sh 6.0.0
```

The runtime fixture depends only on `InnoRouter` and exercises `@Router`,
mixed tab/destination cases, native hosts, deep links, the canonical store, and
versioned snapshots. The test fixture imports the two optional developer
products and exercises `RouterTestStore` plus `RouterInspectorRecorder`.
