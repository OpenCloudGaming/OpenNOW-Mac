import Foundation
import Testing
@testable import OpenNOW

@Suite("Locale normalization")
struct LocaleNormalizationTests {
    @Test("ICU keyword overrides are dropped")
    func dropsICUKeywords() {
        #expect(OPNLocale.normalizedLocale("en_JP@rg=jpzzzz") == "en_JP")
        #expect(OPNLocale.normalizedLocale("en_US@calendar=gregorian;measure=metric") == "en_US")
        #expect(OPNLocale.normalizedLocale("ja@rg=jpzzzz") == "ja")
    }

    @Test("Language and region survive normalization")
    func keepsLanguageAndRegion() {
        #expect(OPNLocale.normalizedLocale("en-JP") == "en_JP")
        #expect(OPNLocale.normalizedLocale("ja_jp") == "ja_JP")
        #expect(OPNLocale.normalizedLocale("pt-br") == "pt_BR")
        #expect(OPNLocale.normalizedLocale("en") == "en_US")
    }

    @Test("Script and variant subtags are not mistaken for a region")
    func skipsNonRegionSubtags() {
        #expect(OPNLocale.normalizedLocale("zh_Hans_CN") == "zh_CN")
        #expect(OPNLocale.normalizedLocale("en_US_POSIX") == "en_US")
        #expect(OPNLocale.normalizedLocale("zh_Hant") == "zh")
    }

    @Test("Empty and malformed input falls back to en_US")
    func fallsBackToEnglish() {
        #expect(OPNLocale.normalizedLocale("") == "en_US")
        #expect(OPNLocale.normalizedLocale("@rg=jpzzzz") == "en_US")
    }
}
