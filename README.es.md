# InnoRouter

[English](README.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

Navegación tipada para SwiftUI basada en macros: un enum de rutas, un árbol de estado recursivo y una sola autoridad mutable.

Versión estable actual: **7.0.0**, publicada el 8 de octubre de 2026. El tag apunta a `33b0da7639105cfa8e6f5acffa3badb91b5e0254`. Esta guía describe esa versión; los informes de candidatos conservan su alcance histórico.

[Release 7.0.0](https://github.com/InnoSquadCorp/InnoRouter/releases/tag/7.0.0) · [Swift Package Index](https://swiftpackageindex.com/InnoSquadCorp/InnoRouter)

## Requisitos e instalación

- Swift 6.3+ (`swift-tools-version: 6.3`)
- iOS / iPadOS / Mac Catalyst 18+, macOS 15+, tvOS 18+, watchOS 11+, visionOS 2+

Añade la dependencia y el producto a los arrays correspondientes de Package.swift. `from:` permite actualizaciones compatibles 7.x; usa `exact: "7.0.0"` para fijar la versión. Las aplicaciones importan `InnoRouter`; `InnoRouterTesting` e `InnoRouterInspector` son productos opcionales.

```swift skip package-manifest-fragment
.package(url: "https://github.com/InnoSquadCorp/InnoRouter.git", from: "7.0.0")

.product(name: "InnoRouter", package: "InnoRouter")
```

## Inicio rápido en 30 segundos

El host posee el store. `@EnvironmentRouter` envía acciones y `@EnvironmentRouterState` observa estado de solo lectura; ambos necesitan un host del mismo tipo. Mantén los stores externos en un propietario estable, nunca los reconstruyas en `body`.

```swift compile
import SwiftUI
import InnoRouter

@Router
enum AppRoute {
    case settings
    case detail(id: String)

    var destination: some View {
        switch self {
        case .settings: Text("Settings")
        case .detail(let id): Text("Detail \(id)")
        }
    }
}

struct HomeView: View {
    @EnvironmentRouter(AppRoute.self) private var router
    @EnvironmentRouterState(AppRoute.self) private var routerState

    var body: some View {
        Button("Open detail") { router.go(.detail(id: "42")) }
            .disabled(routerState.presentation != nil)
    }
}

struct AppRoot: View {
    var body: some View {
        RouterHost(AppRoute.self) { HomeView() }
    }
}
```

## Estado, autoridad e inicialización que puede fallar

`RouterState` es de solo lectura externa. Modifica un `RouterStateDraft`, valida con `try build(resourceBudget:)` y crea un `RouterPlan(state:)`. El plan describe un destino exacto; `RouterAction`, cambios incrementales. Solo `RouterStore` confirma cambios. `RouterScope` proyecta un subárbol y reenvía acciones, sin poseer otro store.

`RouterStore<AppRoute>()` y `AppRoute.makeRouterStore()` no lanzan errores. Con estado inicial, rutas o configuración necesitas `try`. Un renderer con store externo requiere `hostDescriptor`; el ejemplo declara la raíz de pila predeterminada. Captura los errores durante la configuración y muestra una vista de recuperación, sin ocultarlos con `try!` o un estado vacío arbitrario.

```swift skip contextual-fragment
@MainActor
func makeConfiguredStore() throws -> RouterStore<AppRoute> {
    try AppRoute.makeRouterStore(configuration: .init(hostDescriptor: .init(
        root: .stack,
        rootDeclarations: [.init(meaning: .declarationID("router.root"))]
    )))
}
```

## Resultados, políticas y cancelación

Cada petición pasa por reduce → prepare → commit. Solo una transición aplicada asigna el estado completo e incrementa la revisión una vez. unchanged, rejected y deferred no confirman el candidato. Gestiona los cuatro casos de `RouterOutcome`. Este fragmento se ejecuta en el actor principal y reutiliza `AppRoute`.

```swift skip contextual-fragment
let store = AppRoute.makeRouterStore()
switch await store.perform(.push(.detail(id: "42"))) {
case .applied(_, _, _, let revision): print("Committed", revision)
case .unchanged: break
case .deferred(_, _, _, let deferral): print("Deferred", deferral)
case .rejected(_, _, _, let reason): print("Rejected", reason)
}
```

Las políticas inspeccionan candidatos inmutables durante las suspensiones. Rechazo, cancelación, preparación obsoleta y acciones inválidas no cambian el estado confirmado. `RouterRequestKey` admite `keepFirst` / `replacePending`; otras peticiones mantienen FIFO. Limita colas, tiempos de espera y aplazamientos. `deferRequest` libera la ejecución; reanudar comprueba la revisión salvo rebase explícito. La cancelación prevalece incluso si una política tarda en responder y no coopera. `RouterRejectionReason` distingue desbordamiento, timeout, caducidad y cancelación.

## Pestañas, vistas divididas y duración de los ámbitos

Marca raíces sin parámetros con `@TabItem`; deja destinos normales en el mismo enum. `RouterTabHost` conserva historiales independientes. Fija IDs explícitos antes de renombrar casos; los cambios de rutas Codable necesitan migraciones. Construye hosts con entradas mediante `try`, fuera de `body`. `RouterSplitHost` y `RouterThreeColumnSplitHost` necesitan IDs estables de columnas. Usa `RouterTabCatalog.hostDescriptor()` y cambia topología/significado atómicamente con `replaceHost(with:descriptor:context:)`. Restaurar o reemplazar un subárbol caduca la autoridad de sus ámbitos anteriores; vuelve a obtenerlos. `RouterHost(store:)` sigue sin lanzar errores y expone `validationFailure` y recuperación.

Compón enums de funciones independientes con `@FeatureRoute` y `RouterFeatureHost`. Los hijos usan `@EnvironmentRouter` y `@EnvironmentRouterState` con las políticas, cola, revisión y commit del store padre. La función debe poseer todo su subárbol; mezclar valores de padre e hijo falla explícitamente. Las ventanas y escenas inmersivas siguen bajo la raíz de composición de la app.

[Examples/MacrosExample.swift](Examples/MacrosExample.swift)

## Enlaces profundos y autenticación pendiente

Declara listas literales de esquemas y hosts permitidos. `RouterHost` procesa `onOpenURL`; rechaza entradas malformadas y orígenes no autorizados. El ejemplo acepta URLs HTTPS de productos en example.com. `RouterLinkPipeline` crea un `RouterPlan`; una política de autenticación puede conservar el destino completo sin navegación parcial. `RouterPendingLinkSlot` controla reemplazo, cancelación y reanudación. `RouterPendingLinkPersistenceDriver` persiste la continuación en almacenamiento elegido por la app; una restauración lenta no sustituye un enlace más reciente. `inspectorCatalog: true` y `explainDeepLink(_:)` habilitan diagnósticos de solo lectura.

```swift compile
import SwiftUI
import InnoRouter

@Router(deepLinkSchemes: ["https"], deepLinkHosts: ["example.com"])
enum LinkedRoute {
    @DeepLink("/products/:id")
    case product(id: String)

    var destination: some View {
        switch self {
        case .product(let id): Text("Product \(id)")
        }
    }
}
```

## Presentaciones con resultados tipados

La declaración, el llamador y el destino necesitan el mismo tipo de ruta y host. Este fragmento necesita ese contexto; no es una app completa. La petición generada comprueba el tipo del resultado en ambos extremos. El UUID de presentación y una única finalización poseen el valor. Una devolución obsoleta o cancelación no puede cerrar una presentación sustituta. Dismiss, cancelación, rechazo y valor son resultados distintos. No conserves autoridad de finalización después de la presentación.

```swift skip contextual-fragment
@Router
enum SettingsRoute {
    @PresentationResult(Bool.self)
    case settings
    var destination: some View { Text("Settings") }
}

// In a view under a matching SettingsRoute host:
// @EnvironmentRouter(SettingsRoute.self) private var router
let request = SettingsRoute.Presentation.settings
switch await router.present(request) {
case .value(let saved): print(saved)
case .dismissed: break
case .cancelled: break
case .rejected(let reason): print(reason)
}
// In the presented destination, using its matching environment router:
try await router.finishPresentation(request, returning: true)
```

## Restauración e historial de navegación

Conserva `RouterRestorationDriver` y el almacenamiento elegido; conecta `routerStateRestoration(_:)` a una raíz estable. Versiona `RouterSnapshotCodec`, migra cambios de rutas/esquema y comprueba resultados. Para pestañas cambiantes comparte un catálogo entre `RouterTabRestorationTopology`, `catalog.hostDescriptor(orphanPolicy: .preserveDormant)` y renderer. Las ramas inactivas no pueden ser renderers seleccionados. Una restauración obsoleta no debe reemplazar navegación nueva. Los límites de snapshots son finitos y provisionales: mide antes de ampliarlos. La terminación abrupta no garantiza un último guardado.

`RouterHistory` ofrece atrás/adelante y checkpoints acotados mediante planes exactos y políticas normales; conserva badges y presentaciones y no abre ni cierra escenas. Usa `reset(sessionKey:)` al cambiar cuenta/documento. Reset o stop invalida movimientos suspendidos.

La persistencia de snapshots requiere rutas Codable; las migraciones del payload/esquema son responsabilidad de la aplicación.

[Tab restoration](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Restoring-Tab-Navigation.md) · [Examples/TabRestorationExample.swift](Examples/TabRestorationExample.swift)

## Escenas, integración y adaptación de plataforma

Declara rutas sin parámetros con `@Scene(.window)` / `@Scene(.immersiveSpace)` e instala `RouterSceneDriver` junto a las escenas correspondientes. Usa identidad UUID de ventana y callbacks `routerWindowLifecycle` / `routerImmersiveSpaceLifecycle`; en visionOS, `RouterImmersiveSpaceScene` conserva identidad de activación nativa. Cada escena posee su subárbol dentro del mismo store, según disponibilidad de plataforma. `RouterPlatformCapabilities.current` describe soporte; `RouterEvent.platformAdapted` informa alternativas. `RouterUIKitBridge` / `RouterAppKitBridge` usan la misma autoridad. `RouterOpenURLIntentBuilder`, `RouterShortcutCatalog`, `routerHandoff` y `continueRouterHandoff` comparten el contrato URL; Handoff solo acepta HTTP(S).

## Pruebas, Inspector y observabilidad

`RouterTestStore` ejecuta reducer y políticas reales sin host. `RouterActionSequence` conserva contexto. `RouterInspectorRecorder` ofrece timelines limitados con payload oculto, diffs, importación/exportación y replay puro sin mutar el store real. La importación admite por defecto 8 MiB y 5.000 entradas. `RouterObservability` aporta logs/signposts sin payload ni envío de analytics.

`RouterScenarioRecorder` captura controles y `RouterScenarioRunner` reproduce cancelaciones y aplazamientos. El formato de fixture v9 admite v8 solo de navegación; versiones antiguas/desconocidas requieren nueva captura. Los fixtures raw contienen payload de la app y necesitan exportación explícita. `RouterScenarioSourceGenerator.generateFiles` exige expectativas del desarrollador. Inspector incluye inglés y 15 traducciones, independientemente de los siete README.

[Inspector localization](Docs/inspector-localization.md) · [AI skill: Codex / Claude Code](skills/README.md)

## Migración y documentación histórica

6.x → 7 rompe compatibilidad: drafts de estado, inicialización que lanza errores, declaraciones de host fijas, presupuestos finitos, generaciones de autorización y resultados ligados a su duración. Desde 5.x también debes sustituir stores/intents independientes y productos granulares retirados. No copies API archivadas a una app actual. El índice histórico conserva los siete idiomas.

- [Release 7.0.0](https://github.com/InnoSquadCorp/InnoRouter/releases/tag/7.0.0)
- [DocC 7.0.0](https://innosquadcorp.github.io/InnoRouter/7.0.0/)
- [6.x → 7](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-7.md)
- [5.x → 6](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-6.md)
- [Historical translations / 과거 번역 / traducciones históricas / historische Übersetzungen / 历史译本 / 過去の翻訳 / исторические переводы](Docs/Archive/README-translations.md)
- [CHANGELOG](CHANGELOG.md)
- [Navigation reference (English)](Docs/Navigation-Guide.md) · [상세 가이드 (한국어)](Docs/Navigation-Guide.ko.md)

## Validación y contribuciones

Los siete inicios rápidos comparten ejemplos API y contratos. Las comprobaciones estáticas no demuestran compilación Swift, renderizado DocC, comportamiento nativo ni revisión humana de traducciones. Ejecuta los gates con herramientas Apple antes del merge. `--no-parallel` evita agotar el pool cooperativo con dobles síncronos de restauración. No ejecutes builds SwiftPM simultáneos en el mismo directorio temporal.

```bash
python3 scripts/check-readme-translations.py
swift test --jobs 2 --no-parallel
./scripts/check-public-api.sh
./scripts/check-docs-consistency.sh
./scripts/check-docs-code-blocks.sh
./scripts/principle-gates.sh
```

[CONTRIBUTING](CONTRIBUTING.md) · [RELEASING](RELEASING.md) · [Automation policy](Docs/automation-policy.md)

## Licencia y apoyo

Licencia MIT. Se agradecen contribuciones, informes de errores y correcciones de documentación.

[LICENSE](LICENSE) · [GitHub Sponsors](https://github.com/sponsors/InnoSquadCorp) · [Patreon](https://www.patreon.com/15188938/join)
