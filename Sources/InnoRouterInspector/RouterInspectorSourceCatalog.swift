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
        #if canImport(Darwin)
        let language = Bundle.preferredLocalizations(
            from: languages,
            forPreferences: preferredLanguages + ["en"]
        ).first ?? "en"
        #else
        // Corelibs Bundle does not honor the explicit preference list on every
        // toolchain. Resolve catalog language/script identifiers with Foundation
        // Locale while retaining Darwin's native bundle matching unchanged.
        let language = preferredLanguage(preferredLanguages + ["en"])
        #endif
        return translations[language]?[key] ?? key
    }
    #if !canImport(Darwin)
    private func preferredLanguage(_ preferences: [String]) -> String {
        for preference in preferences {
            let normalized = preference.replacingOccurrences(of: "_", with: "-")
            if languages.contains(normalized) { return normalized }
            let requested = Locale.Language(identifier: normalized)
            if let match = languages.first(where: { candidate in
                let available = Locale.Language(identifier: candidate)
                return available.languageCode == requested.languageCode
                    && available.script == requested.script
            }) { return match }
        }
        return "en"
    }
    #endif
}
