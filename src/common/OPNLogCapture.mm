#include "OPNLogCapture.h"
#include "common/OPNSentry.h"

#import <AppKit/AppKit.h>
#include <fcntl.h>
#include <unistd.h>

namespace OPN {

static const unsigned long long kOPNMaxCapturedLogBytes = 2ull * 1024ull * 1024ull;
static const unsigned long long kOPNTrimmedCapturedLogBytes = 1536ull * 1024ull;

static NSString *OPNLogCapturePath() {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"OpenNOW"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    return [directory stringByAppendingPathComponent:@"OpenNOW-current.log"];
}

static NSData *OPNDataByKeepingTail(NSData *data, NSUInteger maximumLength) {
    if (data.length <= maximumLength) return data;
    return [data subdataWithRange:NSMakeRange(data.length - maximumLength, maximumLength)];
}

static void OPNTrimLogIfNeeded(NSString *path, NSUInteger incomingLength) {
    NSDictionary<NSFileAttributeKey, id> *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long currentSize = [attributes fileSize];
    if (currentSize + incomingLength <= kOPNMaxCapturedLogBytes) return;

    NSData *existingData = [NSData dataWithContentsOfFile:path];
    if (existingData.length == 0) return;

    NSData *tailData = OPNDataByKeepingTail(existingData, (NSUInteger)kOPNTrimmedCapturedLogBytes);
    NSString *marker = [NSString stringWithFormat:@"=== OpenNOW log trimmed at %@ to keep captured logs bounded ===\n", NSDate.date];
    NSMutableData *trimmedData = [NSMutableData dataWithData:[marker dataUsingEncoding:NSUTF8StringEncoding]];
    [trimmedData appendData:tailData];
    [trimmedData writeToFile:path atomically:YES];
}

static void OPNAppendDataToLog(NSData *data) {
    if (data.length == 0) return;
    data = OPNDataByKeepingTail(data, (NSUInteger)kOPNMaxCapturedLogBytes);
    NSString *path = OPNLogCapturePath();
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }
    OPNTrimLogIfNeeded(path, data.length);
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (__unused NSException *exception) {
    }
    [handle closeFile];
}

static BOOL OPNLogLineContainsAny(NSString *line, NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if ([line containsString:needle]) return YES;
    }
    return NO;
}

static BOOL OPNIsCoreGraphicsInvalidContextLine(NSString *line) {
    return OPNLogLineContainsAny(line, @[
        @"CGContextSetFillColorWithColor: invalid context",
        @"CGContextSaveGState: invalid context",
        @"CGContextSetFlatness: invalid context",
        @"CGContextAddPath: invalid context",
        @"CGContextDrawPath: invalid context",
        @"CGContextRestoreGState: invalid context",
    ]);
}

static BOOL OPNIsKnownFrameworkNoiseLine(NSString *line) {
    if (line.length == 0) return NO;
    if (OPNIsCoreGraphicsInvalidContextLine(line)) return NO;

    return OPNLogLineContainsAny(line, @[
        @"[StateRestoration] -[NSPersistentUIRemoteStorageClient readCrashData]",
        @"[connection] nw_endpoint_flow_failed_with_error",
        @"[connection] nw_connection_copy_protocol_metadata_internal",
        @"[connection] nw_connection_copy_connected_local_endpoint",
        @"[connection] nw_connection_copy_connected_path",
        @"[connection] nw_connection_copy_connected_remote_endpoint",
        @"[connection] nw_connection_copy_metadata",
        @"[connection] nw_flow_add_write_request",
        @"[connection] nw_write_request_report",
        @"[tcp] tcp_input",
        @"[tcp] tcp_output",
        @"[logging-persist]",
        @"[carc]",
        @"[plugin] AddInstanceForFactory",
        @"CoreSVG has logged an error",
    ]);
}

static BOOL OPNShouldIncludeCopiedLogLine(NSString *line) {
    return !OPNIsKnownFrameworkNoiseLine(line);
}

static BOOL OPNShouldPersistCapturedLogLine(NSString *line) {
    return !OPNIsKnownFrameworkNoiseLine(line);
}

static BOOL OPNCapturedLineOriginatedFromAppLogger(NSString *line) {
    if (line.length == 0) return YES;
    if ([line hasPrefix:@"[Sentry]"]) return YES;
    if ([line hasPrefix:@"[OpenNOW]"]) return YES;
    if ([line hasPrefix:@"[AppDelegate]"]) return YES;
    if ([line hasPrefix:@"[CatalogBrowse]"]) return YES;
    if ([line hasPrefix:@"[CatalogView]"]) return YES;
    if ([line hasPrefix:@"[GameCard]"]) return YES;
    if ([line hasPrefix:@"[StreamVC]"]) return YES;
    if ([line hasPrefix:@"[StreamView]"]) return YES;
    if ([line hasPrefix:@"[Recording]"]) return YES;
    if ([line hasPrefix:@"[LibWebRTC]"]) return YES;
    if ([line hasPrefix:@"[Signaling]"]) return YES;
    if ([line hasPrefix:@"[SessionManager]"]) return YES;
    if ([line hasPrefix:@"[PollSession]"]) return YES;
    if ([line hasPrefix:@"[ClaimSession]"]) return YES;
    if ([line hasPrefix:@"[GameService]"]) return YES;
    if ([line hasPrefix:@"[LogCapture]"]) return YES;
    return NO;
}

static void OPNAppendCapturedLineToLog(NSData *lineData) {
    if (lineData.length == 0) return;
    NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
    if (line && !OPNShouldPersistCapturedLogLine(line)) return;
    if (line && !OPNCapturedLineOriginatedFromAppLogger(line)) {
        OPN::CaptureExternalLogLine(line);
    }

    NSMutableData *data = [lineData mutableCopy];
    const char newline = '\n';
    [data appendBytes:&newline length:sizeof(newline)];
    OPNAppendDataToLog(data);
}

static void OPNAppendCapturedDataToLog(NSData *data, NSMutableData *pendingLine) {
    if (data.length == 0) return;
    [pendingLine appendData:data];

    for (;;) {
        const void *bytes = pendingLine.bytes;
        NSRange newlineRange = [pendingLine rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                                options:0
                                                  range:NSMakeRange(0, pendingLine.length)];
        if (newlineRange.location == NSNotFound) return;

        NSData *lineData = [NSData dataWithBytes:bytes length:newlineRange.location];
        OPNAppendCapturedLineToLog(lineData);
        NSUInteger consumedLength = newlineRange.location + newlineRange.length;
        [pendingLine replaceBytesInRange:NSMakeRange(0, consumedLength) withBytes:nullptr length:0];
    }
}

static NSString *OPNFilteredCopiedLog(NSString *rawLog, NSUInteger *filteredLineCount) {
    if (rawLog.length == 0) return @"";

    NSMutableString *filteredLog = [NSMutableString stringWithCapacity:rawLog.length];
    __block NSUInteger skipped = 0;
    __block NSUInteger repeatedInvalidContextLines = 0;
    __block BOOL includedInvalidContextLine = NO;
    [rawLog enumerateLinesUsingBlock:^(NSString *line, BOOL *) {
        if (OPNIsCoreGraphicsInvalidContextLine(line)) {
            if (!includedInvalidContextLine) {
                [filteredLog appendString:line];
                [filteredLog appendString:@"\n"];
                includedInvalidContextLine = YES;
            } else {
                repeatedInvalidContextLines++;
            }
            return;
        }

        if (OPNShouldIncludeCopiedLogLine(line)) {
            [filteredLog appendString:line];
            [filteredLog appendString:@"\n"];
        } else {
            skipped++;
        }
    }];

    if (repeatedInvalidContextLines > 0) {
        [filteredLog appendFormat:@"\n=== Collapsed %lu repeated CGContext invalid-context line%@; fix the drawing call site separately. ===\n",
                                  (unsigned long)repeatedInvalidContextLines,
                                  repeatedInvalidContextLines == 1 ? @"" : @"s"];
    }
    if (skipped > 0) {
        [filteredLog appendFormat:@"\n=== Filtered %lu known framework noise line%@ from clipboard copy. ===\n",
                                   (unsigned long)skipped,
                                   skipped == 1 ? @"" : @"s"];
    }
    if (filteredLineCount) *filteredLineCount = skipped;
    return filteredLog;
}

void StartLogCapture() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = OPNLogCapturePath();
        NSString *header = [NSString stringWithFormat:@"=== OpenNOW log started %@ ===\n", NSDate.date];
        [header writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

        int pipeFds[2] = {-1, -1};
        if (pipe(pipeFds) != 0) return;

        int stdoutCopy = dup(STDOUT_FILENO);
        if (stdoutCopy < 0) {
            close(pipeFds[0]);
            close(pipeFds[1]);
            return;
        }

        fflush(stdout);
        fflush(stderr);
        dup2(pipeFds[1], STDOUT_FILENO);
        dup2(pipeFds[1], STDERR_FILENO);
        close(pipeFds[1]);
        int readFd = pipeFds[0];

        dispatch_queue_t queue = dispatch_queue_create("com.opennow.logcapture", DISPATCH_QUEUE_SERIAL);
        dispatch_async(queue, ^{
            char buffer[4096];
            NSMutableData *pendingLine = [NSMutableData data];
            for (;;) {
                ssize_t bytesRead = read(readFd, buffer, sizeof(buffer));
                if (bytesRead <= 0) break;
                NSData *data = [NSData dataWithBytes:buffer length:(NSUInteger)bytesRead];
                OPNAppendCapturedDataToLog(data, pendingLine);
                ssize_t written = 0;
                while (written < bytesRead) {
                    ssize_t n = write(stdoutCopy, buffer + written, (size_t)(bytesRead - written));
                    if (n <= 0) break;
                    written += n;
                }
            }
            OPNAppendCapturedLineToLog(pendingLine);
            close(readFd);
            close(stdoutCopy);
        });
    });
}

void AppendLogEvent(NSString *message) {
    if (message.length == 0) return;
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", NSDate.date, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    OPNAppendDataToLog(data);
}

void CopyCapturedLogToClipboard(NSString *reason) {
    if (reason.length > 0) {
        AppendLogEvent([NSString stringWithFormat:@"[Clipboard] Copying log to clipboard: %@", reason]);
    }

    NSString *path = OPNLogCapturePath();
    NSString *log = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (log.length == 0) {
        log = reason.length > 0 ? reason : @"OpenNOW log copy requested, but no captured log was available.";
    } else {
        NSString *filteredLog = OPNFilteredCopiedLog(log, nil);
        if (filteredLog.length > 0) log = filteredLog;
    }

    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:log forType:NSPasteboardTypeString];
    OPN::LogInfo(@"[LogCapture] Copied captured log to clipboard (%lu chars)", (unsigned long)log.length);
}

NSString *CapturedLogPath() {
    return OPNLogCapturePath();
}

}
