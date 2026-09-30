import Foundation

/// Reads the unchanged catalog when the package toolchain does not compile it.
/// Inspector strings are plain labels, not plural or substitution templates.
struct RouterInspectorSourceCatalog: Sendable {
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

    private let translations: [String: [String: String]]
    private let languages: [String]

    init(data: Data) throws {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        var translations: [String: [String: String]] = [:]
        for (key, entry) in catalog.strings {
            for (language, translation) in entry.localizations {
                translations[language, default: [:]][key] = translation.stringUnit.value
            }
        }
        self.translations = translations
        languages = Array(Set(translations.keys).union(["en"])).sorted()
    }

    func localized(_ key: String, preferredLanguages: [String]) -> String {
        let language = Bundle.preferredLocalizations(
            from: languages,
            forPreferences: preferredLanguages + ["en"]
        ).first ?? "en"
        return translations[language]?[key] ?? key
    }
}
