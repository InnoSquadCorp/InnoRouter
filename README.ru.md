# InnoRouter

[English](README.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

Типобезопасная навигация SwiftUI на основе макросов: один enum маршрутов, рекурсивное дерево состояния и единственный владелец изменений.

Текущая стабильная версия: **7.0.0**, опубликована 8 октября 2026 года. Тег указывает на `33b0da7639105cfa8e6f5acffa3badb91b5e0254`. Руководство описывает этот релиз; исторические отчёты сохраняют исходные границы проверки.

[Release 7.0.0](https://github.com/InnoSquadCorp/InnoRouter/releases/tag/7.0.0) · [Swift Package Index](https://swiftpackageindex.com/InnoSquadCorp/InnoRouter)

## Требования и установка

- Swift 6.3+ (`swift-tools-version: 6.3`)
- iOS / iPadOS / Mac Catalyst 18+, macOS 15+, tvOS 18+, watchOS 11+, visionOS 2+

Добавьте зависимость и продукт в соответствующие массивы Package.swift. `from:` разрешает совместимые обновления 7.x; `exact: "7.0.0"` фиксирует версию. Обычное приложение импортирует `InnoRouter`; `InnoRouterTesting` и `InnoRouterInspector` подключаются дополнительно.

```swift skip package-manifest-fragment
.package(url: "https://github.com/InnoSquadCorp/InnoRouter.git", from: "7.0.0")

.product(name: "InnoRouter", package: "InnoRouter")
```

## Быстрый старт за 30 секунд

Host владеет store. `@EnvironmentRouter` отправляет действия, `@EnvironmentRouterState` наблюдает состояние только для чтения. Им нужен соответствующий host. Храните внешний store у стабильного владельца приложения и не создавайте его заново внутри `body`.

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

## Состояние, полномочия и инициализация с ошибками

`RouterState` доступен извне только для чтения. Измените `RouterStateDraft`, проверьте через `try build(resourceBudget:)` и создайте `RouterPlan(state:)`. План задаёт точное целевое состояние, `RouterAction` — пошаговое изменение. Только `RouterStore` фиксирует навигацию. `RouterScope` проецирует поддерево и передаёт действия, не создавая второй store.

`RouterStore<AppRoute>()` и `AppRoute.makeRouterStore()` не бросают ошибок. Начальное состояние, пути или конфигурация требуют `try`. Для renderer с внешним store нужен `hostDescriptor`; пример объявляет стандартный корень стека. Обрабатывайте ошибки при настройке приложения и показывайте интерфейс восстановления, не скрывая их с помощью `try!` или произвольного пустого состояния.

```swift skip contextual-fragment
@MainActor
func makeConfiguredStore() throws -> RouterStore<AppRoute> {
    try AppRoute.makeRouterStore(configuration: .init(hostDescriptor: .init(
        root: .stack,
        rootDeclarations: [.init(meaning: .declarationID("router.root"))]
    )))
}
```

## Результаты, политики и отмена

Запрос проходит reduce → prepare → commit. Применённый переход целиком присваивает состояние и увеличивает ревизию ровно один раз. unchanged, rejected и deferred не фиксируют кандидата. Обработайте все четыре случая `RouterOutcome`. Фрагмент выполняется на main actor и использует `AppRoute` выше.

```swift skip contextual-fragment
let store = AppRoute.makeRouterStore()
switch await store.perform(.push(.detail(id: "42"))) {
case .applied(_, _, _, let revision): print("Committed", revision)
case .unchanged: break
case .deferred(_, _, _, let deferral): print("Deferred", deferral)
case .rejected(_, _, _, let reason): print("Rejected", reason)
}
```

Политики проверяют неизменяемых кандидатов даже через приостановки. Отказ, отмена, устаревшая подготовка и неверное действие не меняют зафиксированное состояние. `RouterRequestKey` поддерживает `keepFirst` / `replacePending`; остальные запросы сохраняют FIFO. Ограничивайте очередь, таймауты политик и отложенные запросы. `deferRequest` освобождает исполнение; возобновление проверяет ревизию, если явно не выбран rebase. Отмена побеждает даже поздний ответ политики, игнорирующей отмену. `RouterRejectionReason` различает переполнение, таймаут, истечение срока и отмену.

## Вкладки, разделённые представления и время жизни scope

Помечайте корни без параметров через `@TabItem`; обычные назначения оставляйте в том же enum. `RouterTabHost` сохраняет независимые истории. Перед переименованием case задайте стабильные ID; изменения Codable-маршрутов всё равно требуют миграции. Создавайте host с входными данными через `try` вне `body`. `RouterSplitHost` и `RouterThreeColumnSplitHost` требуют стабильных ID деклараций колонок. Используйте `RouterTabCatalog.hostDescriptor()`, а топологию и смысл меняйте атомарно через `replaceHost(with:descriptor:context:)`. Восстановление или замена поддерева прекращает полномочия прежних scope: получите их заново. `RouterHost(store:)` остаётся без throwing и предоставляет `validationFailure` и интерфейс восстановления.

Объединяйте независимые enum функций через `@FeatureRoute` и `RouterFeatureHost`. Дочерние `@EnvironmentRouter` и `@EnvironmentRouterState` используют политики, очередь, ревизию и commit родительского store. Функция должна владеть всем поддеревом; смешанные значения родителя и ребёнка явно отклоняются. Окнами и immersive-сценами управляет корень композиции приложения.

[Examples/MacrosExample.swift](Examples/MacrosExample.swift)

## Глубокие ссылки и ожидание авторизации

Задавайте схемы и host литеральными списками разрешённых значений. Подходящий `RouterHost` обрабатывает `onOpenURL`; неверные данные и запрещённые origin отклоняются. Пример принимает HTTPS-ссылки продуктов на example.com. `RouterLinkPipeline` создаёт `RouterPlan`; политика авторизации может удержать всю цель без частичного перехода. `RouterPendingLinkSlot` явно управляет заменой, отменой и возобновлением. `RouterPendingLinkPersistenceDriver` сохраняет продолжение в выбранном приложением хранилище; медленное восстановление не затирает новую ссылку. `inspectorCatalog: true` и `explainDeepLink(_:)` включают диагностику только для чтения.

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

## Представления с типизированным результатом

Объявление, вызывающий код и показанное назначение должны использовать одинаковый тип маршрута и подходящий host. Фрагмент требует этого контекста и не является готовым приложением. Сгенерированный запрос проверяет тип результата с обеих сторон; значение принадлежит точному UUID представления и одному запросу завершения. Устаревший callback или отмена не закрывает заменившее представление. Закрытие пользователем, отмена, отказ и значение различаются. Не храните полномочие завершения дольше жизни представления.

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

## Восстановление и история навигации

Сохраняйте `RouterRestorationDriver` и выбранное хранилище, подключайте `routerStateRestoration(_:)` к стабильному корню. Версионируйте `RouterSnapshotCodec`, мигрируйте изменения маршрутов/схемы и проверяйте результаты. При изменении вкладок используйте общий каталог для `RouterTabRestorationTopology`, `catalog.hostDescriptor(orphanPolicy: .preserveDormant)` и renderer. Неактивные ветки нельзя выбрать как renderer. Устаревшее восстановление не должно заменять новую навигацию. Лимиты снимков конечны и предварительны: измеряйте перед увеличением. Аварийное завершение не гарантирует последнего сохранения.

`RouterHistory` предоставляет ограниченную историю назад/вперёд и checkpoints через точные планы и обычные политики. Сохраняет badges и представления, не открывает и не закрывает сцены. Вызывайте `reset(sessionKey:)` на границе аккаунта/документа. Reset или stop делает приостановленные перемещения недействительными.

Для сохранения снимков нужны маршруты Codable; миграции payload/схемы определяет приложение.

[Tab restoration](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Restoring-Tab-Navigation.md) · [Examples/TabRestorationExample.swift](Examples/TabRestorationExample.swift)

## Сцены, интеграция и адаптация платформ

Объявляйте маршруты без параметров `@Scene(.window)` / `@Scene(.immersiveSpace)` и устанавливайте `RouterSceneDriver` рядом с соответствующими сценами приложения. Используйте UUID окна и callbacks `routerWindowLifecycle` / `routerImmersiveSpaceLifecycle`; на visionOS `RouterImmersiveSpaceScene` передаёт идентичность нативной активации. Каждая сцена имеет поддерево в общем store с учётом доступности платформ. `RouterPlatformCapabilities.current` описывает поддержку, `RouterEvent.platformAdapted` сообщает об адаптации. `RouterUIKitBridge` / `RouterAppKitBridge` используют того же владельца состояния. `RouterOpenURLIntentBuilder`, `RouterShortcutCatalog`, `routerHandoff` и `continueRouterHandoff` разделяют URL-контракт; Handoff принимает только HTTP(S).

## Тестирование, Inspector и наблюдаемость

`RouterTestStore` запускает рабочие reducer и политики без host. `RouterActionSequence` сохраняет контекст. `RouterInspectorRecorder` даёт ограниченные журналы без payload, diff, импорт/экспорт и чистый reducer replay без изменения рабочего store. Стандартный импорт ограничен 8 MiB и 5 000 записями. `RouterObservability` добавляет logs/signposts без payload и передачи аналитики.

`RouterScenarioRecorder` записывает управление исполнением, `RouterScenarioRunner` воспроизводит отмены и отсрочки. Формат fixture v9 поддерживает навигационные v8; старые/неизвестные форматы нужно записать заново. Необработанные fixtures содержат payload приложения и требуют явного экспорта. `RouterScenarioSourceGenerator.generateFiles` требует ожиданий, заданных разработчиком. Inspector поддерживает английский и 15 переводов отдельно от семи языков README.

[Inspector localization](Docs/inspector-localization.md) · [AI skill: Codex / Claude Code](skills/README.md)

## Миграция и историческая документация

6.x → 7 нарушает совместимость: drafts состояния, throwing-настройка, фиксированные декларации host, конечные бюджеты, поколения авторизации и результаты с ограниченным временем жизни. Из 5.x также нужно заменить независимые stores/intents и удалённые отдельные продукты. Не переносите архивные API в текущее приложение. Исторический индекс сохраняет все семь языков.

- [Release 7.0.0](https://github.com/InnoSquadCorp/InnoRouter/releases/tag/7.0.0)
- [DocC 7.0.0](https://innosquadcorp.github.io/InnoRouter/7.0.0/)
- [6.x → 7](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-7.md)
- [5.x → 6](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-6.md)
- [Historical translations / 과거 번역 / traducciones históricas / historische Übersetzungen / 历史译本 / 過去の翻訳 / исторические переводы](Docs/Archive/README-translations.md)
- [CHANGELOG](CHANGELOG.md)
- [Navigation reference (English)](Docs/Navigation-Guide.md) · [상세 가이드 (한국어)](Docs/Navigation-Guide.ko.md)

## Проверка и участие в разработке

Семь быстрых стартов используют общие API-примеры и охват контрактов. Статические проверки не доказывают компиляцию Swift, отображение DocC, работу нативных сцен или человеческую проверку перевода. Перед merge запускайте проверки Apple toolchain. `--no-parallel` предотвращает истощение cooperative pool синхронными тестовыми двойниками восстановления. Не запускайте SwiftPM builds одновременно в одном scratch-каталоге.

```bash
python3 scripts/check-readme-translations.py
swift test --jobs 2 --no-parallel
./scripts/check-public-api.sh
./scripts/check-docs-consistency.sh
./scripts/check-docs-code-blocks.sh
./scripts/principle-gates.sh
```

[CONTRIBUTING](CONTRIBUTING.md) · [RELEASING](RELEASING.md) · [Automation policy](Docs/automation-policy.md)

## Лицензия и поддержка

Лицензия MIT. Приветствуются вклад в разработку, сообщения об ошибках и исправления документации.

[LICENSE](LICENSE) · [GitHub Sponsors](https://github.com/sponsors/InnoSquadCorp) · [Patreon](https://www.patreon.com/15188938/join)
