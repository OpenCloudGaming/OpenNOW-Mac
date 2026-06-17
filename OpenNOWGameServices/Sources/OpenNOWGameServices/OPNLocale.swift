import Foundation

@objc(OPNLocale)
final class OPNLocale: NSObject {
    @objc(currentGFNLocale)
    static func currentGFNLocale() -> String {
        for language in Locale.preferredLanguages where !language.isEmpty {
            return normalizedLocale(language)
        }
        return normalizedLocale(Locale.current.identifier.isEmpty ? "en_US" : Locale.current.identifier)
    }

    @objc(currentGFNLocaleURLPathComponent)
    static func currentGFNLocaleURLPathComponent() -> String {
        currentGFNLocale().replacingOccurrences(of: "_", with: "-")
    }

    @objc(gfnLocaleFallbacksForLocale:)
    static func gfnLocaleFallbacks(for locale: String) -> [String] {
        let normalized = normalizedLocale(locale)
        var fallbacks: [String] = []
        appendUnique(normalized, to: &fallbacks)

        let separator = normalized.firstIndex(of: "_")
        let language = separator.map { String(normalized[..<$0]) } ?? normalized
        if !language.isEmpty, language != "en" {
            appendUnique(language, to: &fallbacks)
        }
        appendUnique("en_US", to: &fallbacks)
        return fallbacks
    }

    @objc(currentGFNLocaleFallbacks)
    static func currentGFNLocaleFallbacks() -> [String] {
        gfnLocaleFallbacks(for: currentGFNLocale())
    }

    @objc(currentGFNLocaleURLPathComponentFallbacks)
    static func currentGFNLocaleURLPathComponentFallbacks() -> [String] {
        var result: [String] = []
        for locale in currentGFNLocaleFallbacks() {
            appendUnique(locale.replacingOccurrences(of: "_", with: "-"), to: &result)
        }
        return result
    }

    @objc(normalizedLocale:)
    static func normalizedLocale(_ rawLocale: String) -> String {
        let normalized = rawLocale.replacingOccurrences(of: "-", with: "_")
        if normalized.isEmpty { return "en_US" }

        guard let separator = normalized.firstIndex(of: "_") else {
            let language = normalized.lowercased()
            return language == "en" ? "en_US" : language
        }

        let language = String(normalized[..<separator]).lowercased()
        let regionStart = normalized.index(after: separator)
        let region = String(normalized[regionStart...]).uppercased()
        if language.isEmpty { return "en_US" }
        return region.isEmpty ? language : "\(language)_\(region)"
    }

    private static func appendUnique(_ locale: String, to locales: inout [String]) {
        guard !locale.isEmpty, !locales.contains(locale) else { return }
        locales.append(locale)
    }
}
