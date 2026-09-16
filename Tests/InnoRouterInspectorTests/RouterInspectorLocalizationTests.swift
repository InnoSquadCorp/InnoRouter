import Foundation
import Testing
@testable import InnoRouterInspector

@Suite("Inspector localization")
struct RouterInspectorLocalizationTests {
    private struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Translation: Decodable {
                struct Unit: Decodable {
                    let value: String
                }

                let stringUnit: Unit
            }

            let localizations: [String: Translation]
        }

        let strings: [String: Entry]
    }

    @Test("Explicit locale selects the package translation independently of the process")
    func explicitLocale() {
        #expect(routerInspectorLocalized("Start recording", locale: Locale(identifier: "ko")) == "기록 시작")
        #expect(routerInspectorLocalized("Start recording", locale: Locale(identifier: "en")) == "Start recording")
    }

    @Test("Every compiled translation matches its reviewed catalog value")
    func compiledResources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/InnoRouterInspector/Localizable.xcstrings"))
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        let sourceCatalog = try RouterInspectorSourceCatalog(data: data)
        #expect(catalog.strings.count == 66)
        for (key, entry) in catalog.strings {
            #expect(entry.localizations.count == 15)
            for (language, translation) in entry.localizations {
                #expect(routerInspectorLocalized(key, locale: Locale(identifier: language)) == translation.stringUnit.value)
                #expect(sourceCatalog.localized(key, preferredLanguages: [language]) == translation.stringUnit.value)
            }
            #expect(routerInspectorLocalized(key, locale: Locale(identifier: "en")) == key)
            #expect(routerInspectorLocalized(key, locale: Locale(identifier: "fi-FI")) == key)
            #expect(sourceCatalog.localized(key, preferredLanguages: ["en"]) == key)
            #expect(sourceCatalog.localized(key, preferredLanguages: ["fi-FI"]) == key)
        }
        #expect(sourceCatalog.localized("Start recording", preferredLanguages: ["ko-KR"]) == "기록 시작")
        #expect(sourceCatalog.localized("Start recording", preferredLanguages: ["zh-TW"]) == "開始記錄")
        #expect(sourceCatalog.localized("Start recording", preferredLanguages: ["fi-FI", "ja-JP"]) == "記録を開始")
        #expect(sourceCatalog.localized("Unknown key", preferredLanguages: ["ko"]) == "Unknown key")
    }

    @Test("Regional locales resolve the intended language and script", arguments: [
        ("ko-KR", "기록 시작"),
        ("ja-JP", "記録を開始"),
        ("zh-CN", "开始记录"),
        ("zh-TW", "開始記錄"),
        ("pt-BR", "Iniciar registro"),
        ("en-GB", "Start recording"),
    ])
    func regionalLocales(identifier: String, expected: String) {
        #expect(routerInspectorLocalized("Start recording", locale: Locale(identifier: identifier)) == expected)
    }

    @Test("Switching language does not retain a previously rendered failure")
    func failureLanguageChanges() {
        let key = RouterInspectorScenarioFailure.importFailed.localizationKey
        #expect(routerInspectorLocalized(key, locale: Locale(identifier: "ko")) == "시나리오 가져오기에 실패했습니다")
        #expect(routerInspectorLocalized(key, locale: Locale(identifier: "de")) == "Szenarioimport fehlgeschlagen")
        #expect(routerInspectorLocalized(key, locale: Locale(identifier: "en")) == "Scenario import failed")
        #expect(RouterInspectorScenarioFailure.startFailed.localizationKey == "Scenario recording could not start")
        #expect(RouterInspectorScenarioFailure.stopFailed.localizationKey == "Scenario recording could not stop")
    }
}
