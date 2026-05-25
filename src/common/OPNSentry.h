#pragma once

#import <Foundation/Foundation.h>

namespace OPN {

void InitializeSentry();
void CloseSentry();
bool ShouldLogInfo();
void LogInfo(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void LogError(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void CaptureExternalLogLine(NSString *line);

}
