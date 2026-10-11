# InnoRouter

[English](README.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

Typsichere, makrobasierte Navigation für SwiftUI: ein Routen-Enum, ein rekursiver Zustandsbaum und eine einzige veränderbare Zustandsinstanz.

Aktuelle stabile Version: **7.0.0**, veröffentlicht am 8. Oktober 2026. Der Tag verweist auf `33b0da7639105cfa8e6f5acffa3badb91b5e0254`. Dieser Leitfaden beschreibt diese Version; historische Prüfberichte behalten ihren ursprünglichen Geltungsbereich.

[Release 7.0.0](https://github.com/InnoSquadCorp/InnoRouter/releases/tag/7.0.0) · [Swift Package Index](https://swiftpackageindex.com/InnoSquadCorp/InnoRouter)

## Voraussetzungen und Installation

- Swift 6.3+ (`swift-tools-version: 6.3`)
- iOS / iPadOS / Mac Catalyst 18+, macOS 15+, tvOS 18+, watchOS 11+, visionOS 2+

Füge Abhängigkeit und Produkt in die passenden Arrays der Package.swift ein. `from:` erlaubt kompatible 7.x-Updates; `exact: "7.0.0"` fixiert die Version. Apps importieren `InnoRouter`; `InnoRouterTesting` und `InnoRouterInspector` sind optionale Produkte.

```swift skip package-manifest-fragment
.package(url: "https://github.com/InnoSquadCorp/InnoRouter.git", from: "7.0.0")

.product(name: "InnoRouter", package: "InnoRouter")
```

## Schnellstart in 30 Sekunden

Der Host besitzt den Store. `@EnvironmentRouter` sendet Aktionen, `@EnvironmentRouterState` beobachtet schreibgeschützten UI-Zustand. Beide brauchen einen passenden Host. Bewahre externe Stores an einer stabilen Anwendungsgrenze auf; erzeuge sie nicht erneut in `body`.

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

## Zustand, Zuständigkeit und fehlbare Initialisierung

`RouterState` ist von außen schreibgeschützt. Bearbeite einen `RouterStateDraft`, validiere mit `try build(resourceBudget:)` und erstelle `RouterPlan(state:)`. Ein Plan beschreibt den exakten Zielzustand, `RouterAction` inkrementelle Änderungen. Nur `RouterStore` übernimmt Navigation. `RouterScope` projiziert einen Teilbaum und leitet Aktionen weiter, ohne eigenen Store.

`RouterStore<AppRoute>()` und `AppRoute.makeRouterStore()` werfen keine Fehler. Anfangszustand, Pfade oder Konfiguration erfordern `try`. Ein Renderer mit externem Store benötigt `hostDescriptor`; das Beispiel deklariert die Standard-Stack-Wurzel. Behandle Fehler bei der Einrichtung und zeige eine Wiederherstellungsansicht, statt sie mit `try!` oder einem beliebigen leeren Zustand zu verbergen.

```swift skip contextual-fragment
@MainActor
func makeConfiguredStore() throws -> RouterStore<AppRoute> {
    try AppRoute.makeRouterStore(configuration: .init(hostDescriptor: .init(
        root: .stack,
        rootDeclarations: [.init(meaning: .declarationID("router.root"))]
    )))
}
```

## Ergebnisse, Richtlinien und Abbruch

Anfragen durchlaufen reduce → prepare → commit. Eine angewendete Transition weist den gesamten Zustand zu und erhöht die Revision genau einmal. unchanged, rejected und deferred übernehmen keinen Kandidaten. Behandle alle vier `RouterOutcome`-Fälle. Das Fragment läuft auf dem Main Actor und nutzt `AppRoute` von oben.

```swift skip contextual-fragment
let store = AppRoute.makeRouterStore()
switch await store.perform(.push(.detail(id: "42"))) {
case .applied(_, _, _, let revision): print("Committed", revision)
case .unchanged: break
case .deferred(_, _, _, let deferral): print("Deferred", deferral)
case .rejected(_, _, _, let reason): print("Rejected", reason)
}
```

Richtlinien prüfen unveränderliche Kandidaten auch über Unterbrechungen hinweg. Ablehnung, Abbruch, veraltete Vorbereitung und ungültige Aktionen ändern den bestätigten Zustand nicht. `RouterRequestKey` bietet `keepFirst` / `replacePending`; andere Anfragen bleiben FIFO. Begrenze Warteschlangen, Richtlinien-Timeouts und Aufschübe. `deferRequest` gibt die Ausführung frei; Fortsetzen prüft die Revision, sofern kein explizites Rebase gewählt wird. Abbruch gewinnt auch gegen verspätete, nicht kooperative Richtlinien. `RouterRejectionReason` unterscheidet Überlauf, Timeout, Ablauf und Abbruch.

## Tabs, geteilte Ansichten und Scope-Lebensdauer

Markiere parameterlose Wurzeln mit `@TabItem`; normale Ziele bleiben im selben Enum. `RouterTabHost` erhält getrennte Verläufe. Vergib stabile explizite IDs vor einer Umbenennung; Codable-Routenänderungen brauchen weiterhin Migrationen. Erzeuge Hosts mit Eingaben über `try` außerhalb von `body`. `RouterSplitHost` und `RouterThreeColumnSplitHost` benötigen stabile Spalten-Deklarations-IDs. Nutze `RouterTabCatalog.hostDescriptor()` und ändere Topologie/Bedeutung atomar mit `replaceHost(with:descriptor:context:)`. Wiederherstellung oder Austausch eines Teilbaums lässt alte Scope-Berechtigungen ablaufen; hole sie erneut. `RouterHost(store:)` bleibt nicht werfend und bietet `validationFailure` sowie Wiederherstellungs-UI.

Kombiniere unabhängige Feature-Enums mit `@FeatureRoute` und `RouterFeatureHost`. Untergeordnete `@EnvironmentRouter` und `@EnvironmentRouterState` nutzen Richtlinien, Warteschlange, Revision und Commit des Eltern-Stores. Das Feature muss seinen vollständigen Teilbaum besitzen; gemischte Eltern-/Kindwerte werden abgewiesen. Fenster und immersive Szenen bleiben in der Zuständigkeit der App-Kompositionswurzel.

[Examples/MacrosExample.swift](Examples/MacrosExample.swift)

## Deep Links und ausstehende Anmeldung

Verwende literale Positivlisten für Schemes und Hosts. `RouterHost` verarbeitet `onOpenURL`; fehlerhafte Eingaben und fremde Origins werden abgewiesen. Das Beispiel akzeptiert HTTPS-Produkt-URLs von example.com. `RouterLinkPipeline` erzeugt einen `RouterPlan`; Anmelderichtlinien können das gesamte Ziel ohne Teilnavigation zurückhalten. `RouterPendingLinkSlot` steuert Ersatz, Abbruch und Fortsetzung. `RouterPendingLinkPersistenceDriver` speichert die Fortsetzung im gewählten Speicher; eine langsame Wiederherstellung überschreibt keinen neueren Link. `inspectorCatalog: true` und `explainDeepLink(_:)` aktivieren schreibgeschützte Diagnostik.

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

## Präsentationen mit typisierten Ergebnissen

Deklaration, Aufrufer und Ziel benötigen denselben Routentyp und passenden Host. Dieses kontextabhängige Fragment ist keine vollständige App. Die erzeugte Anfrage prüft den Ergebnistyp an beiden Enden. Präsentations-UUID und genau eine Abschlussanfrage besitzen den Wert. Alte Rückrufe oder Abbruch schließen keine Ersatzpräsentation. Interaktives Schließen, Abbruch, Ablehnung und Rückgabewert bleiben verschieden. Bewahre Abschlussbefugnisse nicht über die Lebensdauer der Präsentation hinaus auf.

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

## Wiederherstellung und Navigationsverlauf

Halte `RouterRestorationDriver` mit anwendungseigenem Speicher stabil und binde `routerStateRestoration(_:)` an die Wurzel. Versioniere `RouterSnapshotCodec`, migriere Routen-/Schemaänderungen und prüfe Ergebnisse. Bei geänderten Tabs teilen `RouterTabRestorationTopology`, `catalog.hostDescriptor(orphanPolicy: .preserveDormant)` und Renderer denselben Katalog. Ruhende Zweige können keine ausgewählten Renderer werden. Veraltete Wiederherstellung darf neuere Navigation nicht überschreiben. Snapshot-Grenzen sind endliche vorläufige Werte: vor Erhöhung messen. Abruptes Beenden garantiert kein letztes Speichern.

`RouterHistory` bietet begrenztes Zurück/Vorwärts und Checkpoints über exakte Pläne und normale Richtlinien. Badges und Präsentationen bleiben erhalten; Szenen werden weder geöffnet noch geschlossen. Nutze `reset(sessionKey:)` an Konto-/Dokumentgrenzen. Reset oder Stop entwertet unterbrochene Bewegungen.

Snapshot-Persistenz benötigt Codable-Routen; Payload-/Schema-Migrationen definiert die Anwendung.

[Tab restoration](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Restoring-Tab-Navigation.md) · [Examples/TabRestorationExample.swift](Examples/TabRestorationExample.swift)

## Szenen, Systemintegration und Plattformanpassung

Deklariere parameterlose `@Scene(.window)` / `@Scene(.immersiveSpace)` und installiere `RouterSceneDriver` neben passenden App-Szenen. Nutze Fenster-UUIDs und `routerWindowLifecycle` / `routerImmersiveSpaceLifecycle`; auf visionOS trägt `RouterImmersiveSpaceScene` die native Aktivierungsidentität. Jede Szene besitzt einen Teilbaum im selben Store; Plattformverfügbarkeit gilt weiterhin. `RouterPlatformCapabilities.current` beschreibt Unterstützung, `RouterEvent.platformAdapted` meldet Ersatzdarstellungen. `RouterUIKitBridge` / `RouterAppKitBridge` verwenden denselben Store. `RouterOpenURLIntentBuilder`, `RouterShortcutCatalog`, `routerHandoff` und `continueRouterHandoff` teilen den URL-Vertrag; Handoff akzeptiert nur HTTP(S).

## Tests, Inspector und Beobachtbarkeit

`RouterTestStore` führt produktive Reducer und Richtlinien ohne Host aus. `RouterActionSequence` erhält den Kontext. `RouterInspectorRecorder` bietet begrenzte, payload-bereinigte Zeitleisten, Diffs, Import/Export und reines Reducer-Replay ohne Änderung des Live-Stores. Importgrenzen: 8 MiB und 5.000 Einträge. `RouterObservability` liefert payload-freie Logs/Signposts ohne Analytics-Übertragung.

`RouterScenarioRecorder` zeichnet Ausführungssteuerung auf; `RouterScenarioRunner` spielt auch Abbrüche und Aufschübe nach. Fixture-Format v9 unterstützt reine Navigationsfixtures v8; ältere/unbekannte Formate müssen neu erfasst werden. Rohe Fixtures enthalten App-Payloads und erfordern expliziten Export. `RouterScenarioSourceGenerator.generateFiles` benötigt Entwickler-Erwartungen. Inspector unterstützt Englisch plus 15 Übersetzungen, unabhängig von den sieben README-Sprachen.

[Inspector localization](Docs/inspector-localization.md) · [AI skill: Codex / Claude Code](skills/README.md)

## Migration und historische Dokumentation

6.x → 7 ist inkompatibel: Zustands-Drafts, werfende Einrichtung, feste Host-Deklarationen, endliche Budgets, Autorisierungsgenerationen und lebensdauergebundene Ergebnisse. Aus 5.x müssen zusätzlich unabhängige Stores/Intents und entfernte Einzelprodukte ersetzt werden. Übernimm keine archivierten APIs in aktuelle Apps. Der Archivindex verlinkt alle sieben historischen Übersetzungen.

- [Release 7.0.0](https://github.com/InnoSquadCorp/InnoRouter/releases/tag/7.0.0)
- [DocC 7.0.0](https://innosquadcorp.github.io/InnoRouter/7.0.0/)
- [6.x → 7](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-7.md)
- [5.x → 6](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-6.md)
- [Historical translations / 과거 번역 / traducciones históricas / historische Übersetzungen / 历史译本 / 過去の翻訳 / исторические переводы](Docs/Archive/README-translations.md)
- [CHANGELOG](CHANGELOG.md)
- [Navigation reference (English)](Docs/Navigation-Guide.md) · [상세 가이드 (한국어)](Docs/Navigation-Guide.ko.md)

## Validierung und Beiträge

Die sieben Schnellstarts teilen API-Beispiele und Vertragsumfang. Statische Prüfungen belegen keine Swift-Kompilierung, DocC-Darstellung, native Szenenfunktion oder menschliche Übersetzungsprüfung. Führe vor dem Merge die Apple-Toolchain-Gates aus. `--no-parallel` verhindert das Aushungern des kooperativen Pools durch synchrone Wiederherstellungs-Testdoubles. Keine gleichzeitigen SwiftPM-Builds im selben Scratch-Verzeichnis.

```bash
python3 scripts/check-readme-translations.py
swift test --jobs 2 --no-parallel
./scripts/check-public-api.sh
./scripts/check-docs-consistency.sh
./scripts/check-docs-code-blocks.sh
./scripts/principle-gates.sh
```

[CONTRIBUTING](CONTRIBUTING.md) · [RELEASING](RELEASING.md) · [Automation policy](Docs/automation-policy.md)

## Lizenz und Unterstützung

MIT-Lizenz. Beiträge, Fehlerberichte und Dokumentationskorrekturen sind willkommen.

[LICENSE](LICENSE) · [GitHub Sponsors](https://github.com/sponsors/InnoSquadCorp) · [Patreon](https://www.patreon.com/15188938/join)
