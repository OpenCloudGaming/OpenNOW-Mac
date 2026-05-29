#include "OPNLocale.h"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cctype>
#include <vector>

namespace OPN {

static std::string ASCIILower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return (char)std::tolower(character);
    });
    return value;
}

static std::string ASCIIUpper(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return (char)std::toupper(character);
    });
    return value;
}

static std::string NormalizedLocale(const std::string &rawLocale) {
    std::string normalized = rawLocale;
    std::replace(normalized.begin(), normalized.end(), '-', '_');
    if (normalized.empty()) return "en_US";

    size_t separator = normalized.find('_');
    if (separator == std::string::npos) {
        std::string language = ASCIILower(normalized);
        if (language == "en") return "en_US";
        return language;
    }

    std::string language = ASCIILower(normalized.substr(0, separator));
    std::string region = ASCIIUpper(normalized.substr(separator + 1));
    if (language.empty()) return "en_US";
    if (region.empty()) return language;
    return language + "_" + region;
}

std::string CurrentGFNLocale() {
    NSArray<NSString *> *preferredLanguages = NSLocale.preferredLanguages;
    for (NSString *language in preferredLanguages) {
        if (![language isKindOfClass:NSString.class] || language.length == 0) continue;
        std::string normalized = NormalizedLocale(language.UTF8String);
        if (!normalized.empty()) return normalized;
    }
    NSString *identifier = NSLocale.currentLocale.localeIdentifier;
    return NormalizedLocale(identifier.length > 0 ? identifier.UTF8String : "en_US");
}

std::string CurrentGFNLocaleURLPathComponent() {
    std::string locale = CurrentGFNLocale();
    std::replace(locale.begin(), locale.end(), '_', '-');
    return locale;
}

static void PushUniqueLocale(std::vector<std::string> &locales, const std::string &locale) {
    if (locale.empty()) return;
    if (std::find(locales.begin(), locales.end(), locale) == locales.end()) locales.push_back(locale);
}

std::vector<std::string> GFNLocaleFallbacksForLocale(const std::string &locale) {
    std::string normalized = NormalizedLocale(locale);
    std::vector<std::string> fallbacks;
    PushUniqueLocale(fallbacks, normalized);

    size_t separator = normalized.find('_');
    std::string language = separator == std::string::npos ? normalized : normalized.substr(0, separator);
    if (!language.empty() && language != "en") PushUniqueLocale(fallbacks, language);
    PushUniqueLocale(fallbacks, "en_US");
    return fallbacks;
}

std::vector<std::string> CurrentGFNLocaleFallbacks() {
    return GFNLocaleFallbacksForLocale(CurrentGFNLocale());
}

std::vector<std::string> CurrentGFNLocaleURLPathComponentFallbacks() {
    std::vector<std::string> result;
    for (std::string locale : CurrentGFNLocaleFallbacks()) {
        std::replace(locale.begin(), locale.end(), '_', '-');
        PushUniqueLocale(result, locale);
    }
    return result;
}

}
