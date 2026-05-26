#include "OPNLocale.h"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cctype>

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

}
