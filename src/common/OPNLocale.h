#pragma once

#include <string>
#include <vector>

namespace OPN {

std::string CurrentGFNLocale();
std::string CurrentGFNLocaleURLPathComponent();
std::vector<std::string> GFNLocaleFallbacksForLocale(const std::string &locale);
std::vector<std::string> CurrentGFNLocaleFallbacks();
std::vector<std::string> CurrentGFNLocaleURLPathComponentFallbacks();

}
