# External consumer smoke

This nested Swift package validates InnoRouter from a downstream package
boundary rather than from a target declared in the framework's root manifest.

By default it resolves the repository checkout through a local path:

```bash
./scripts/external-consumer-smoke.sh
```

After a release is published, pass its bare semantic version to resolve the
exact remote tag and verify package discovery, product imports, macros, and
platform compilation:

```bash
./scripts/external-consumer-smoke.sh 5.0.0
```

`InnoRouterMacroFirstExternalConsumer` depends only on `InnoRouter`.
`InnoRouterSpatialExternalConsumer` depends only on `InnoRouterSpatial`.
`InnoRouterSpatialExternalConsumerTests` links and runs the Spatial product,
its generated `@SceneRouter` surface, public API, and the complete visionOS
runtime regression suite in a simulator. The platform workflow owns simulator
discovery and executes that suite through the nested package's
`InnoRouterConsumerSmoke-Package` scheme.
