#pragma once

#import <Foundation/Foundation.h>

namespace OPN {

bool ProtocolDebugLoggingEnabled();
NSString *SanitizedProtocolJSONStringFromJSONObject(id object);
NSString *SanitizedProtocolJSONStringFromData(NSData *data);
NSString *ProtocolDebugCaptureFilename(NSString *label, unsigned long sequence);
void LogProtocolJSONObject(NSString *label, id object);
void LogProtocolJSONData(NSString *label, NSData *data);

}
