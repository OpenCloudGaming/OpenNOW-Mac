#include "OPNDeviceIdentity.h"
#import <Foundation/Foundation.h>

namespace OPN {

std::string StableCloudmatchDeviceId() {
    static std::string cachedDeviceId;
    if (!cachedDeviceId.empty()) return cachedDeviceId;

    NSString *supportDir = [@"~/Library/Application Support/OpenNOW" stringByExpandingTildeInPath];
    NSString *path = [supportDir stringByAppendingPathComponent:@"device-id.plist"];
    NSString *legacyPath = [@"~/Library/Application Support/com.nvidia.gfn-device-id" stringByExpandingTildeInPath];
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!existing) existing = [NSDictionary dictionaryWithContentsOfFile:legacyPath];

    NSString *deviceId = [existing[@"deviceId"] isKindOfClass:NSString.class] ? existing[@"deviceId"] : nil;
    if (deviceId.length == 0) deviceId = NSUUID.UUID.UUIDString.lowercaseString;

    NSDictionary *directoryAttributes = @{NSFilePosixPermissions: @(0700)};
    [[NSFileManager defaultManager] createDirectoryAtPath:supportDir
                              withIntermediateDirectories:YES
                                               attributes:directoryAttributes
                                                    error:nil];
    NSDictionary *plist = @{@"deviceId": deviceId};
    [plist writeToFile:path atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0600)}
                                     ofItemAtPath:path
                                           error:nil];

    cachedDeviceId = deviceId.UTF8String;
    return cachedDeviceId;
}

}
