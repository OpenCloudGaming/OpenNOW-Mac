#pragma once

#include <string>

namespace OPN {

std::string UserFacingGFNErrorMessage(const std::string &errorMessage,
                                      const std::string &gameTitle = std::string());
std::string UserFacingGFNErrorMessage(const std::string &errorMessage,
                                      const std::string &gameTitle,
                                      bool sessionWasConnected);

}
