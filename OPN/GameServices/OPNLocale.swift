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

    @objc(currentGFNCatalogLocale)
    static func currentGFNCatalogLocale() -> String {
        gfnCatalogLocale(for: currentGFNLocale())
    }

    @objc(gfnCatalogLocaleForLocale:)
    static func gfnCatalogLocale(for locale: String) -> String {
        let normalized = normalizedLocale(locale)
        let separator = normalized.firstIndex(of: "_")
        let language = separator.map { String(normalized[..<$0]) } ?? normalized
        return language == "en" ? "en_US" : normalized
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
        // `Locale.current.identifier` carries ICU keywords when the region, calendar or measurement
        // system is overridden ("en_JP@rg=jpzzzz"); NVIDIA rejects those with SCHEMA_VIOLATION.
        let base = rawLocale.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let components = base.replacingOccurrences(of: "-", with: "_")
            .split(separator: "_", omittingEmptySubsequences: true)
        guard let language = components.first?.lowercased(), !language.isEmpty else { return "en_US" }
        guard let region = components.dropFirst().first(where: isRegionSubtag)?.uppercased() else {
            return language == "en" ? "en_US" : language
        }
        return "\(language)_\(region)"
    }

    /// Script and variant subtags ("zh_Hans_CN", "en_US_POSIX") sit where a region could, so the
    /// region is the first following subtag actually shaped like one.
    private static func isRegionSubtag(_ subtag: Substring) -> Bool {
        (subtag.count == 2 && subtag.allSatisfy(\.isLetter)) || (subtag.count == 3 && subtag.allSatisfy(\.isNumber))
    }

    private static func appendUnique(_ locale: String, to locales: inout [String]) {
        guard !locale.isEmpty, !locales.contains(locale) else { return }
        locales.append(locale)
    }
}
