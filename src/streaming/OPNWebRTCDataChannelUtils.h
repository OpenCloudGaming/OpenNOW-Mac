#pragma once

#import <Foundation/Foundation.h>

#include <cstdint>
#include <string>

namespace OPN {

uint32_t OPNReadU32LE(const uint8_t *data);
std::string OPNValidUtf8StringFromBytes(const uint8_t *data, size_t len);
std::string OPNClipboardTextFromJsonData(NSData *data);

}
