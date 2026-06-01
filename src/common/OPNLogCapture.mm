#include "OPNLogCapture.h"
#include "common/OPNSentry.h"

#import <AppKit/AppKit.h>

namespace OPN {

static NSString *OPNStringByReplacingMatches(NSString *message, NSString *pattern, NSString *replacement) {
    if (message.length == 0) return @"";
    NSError *error = nil;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                                options:NSRegularExpressionCaseInsensitive
                                                                                  error:&error];
    if (!expression) return message;
    NSRange fullRange = NSMakeRange(0, message.length);
    return [expression stringByReplacingMatchesInString:message
                                                options:0
                                                  range:fullRange
                                           withTemplate:replacement];
}

static NSString *OPNRedactedLogLine(NSString *line) {
    if (line.length == 0) return @"";
    NSString *redacted = line;
    redacted = OPNStringByReplacingMatches(redacted, @"\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b", @"[redacted-email]");
    redacted = OPNStringByReplacingMatches(redacted, @"\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b", @"[redacted-ip]");
    redacted = OPNStringByReplacingMatches(redacted, @"\\b[0-9A-F]{8}-[0-9A-F]{4}-[1-5][0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}\\b", @"[redacted-id]");
    redacted = OPNStringByReplacingMatches(redacted, @"\\b[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\b", @"[redacted-token]");
    redacted = OPNStringByReplacingMatches(redacted, @"(bearer|basic|gfnjwt)\\s+[^\\s,;]+", @"$1 [redacted-token]");
    redacted = OPNStringByReplacingMatches(redacted, @"((?:access|refresh|id|client)?_?token|authorization|password|secret|api[_-]?key|session[_-]?id|credential|ice[_-]?pwd)([=:]\\s*|\\\"\\s*:\\s*\\\")[^\\s,;\\}\\\"]+", @"$1$2[redacted-secret]");
    redacted = OPNStringByReplacingMatches(redacted, @"/Users/[^/\\s]+", @"/Users/[redacted-user]");
    return redacted;
}

static NSMutableArray<NSString *> *OPNInMemoryLogEvents() {
    static NSMutableArray<NSString *> *events = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        events = [NSMutableArray array];
    });
    return events;
}

void StartLogCapture() {
}

void AppendLogEvent(NSString *message) {
    if (message.length == 0) return;
    NSString *line = [NSString stringWithFormat:@"%@ %@", NSDate.date, OPNRedactedLogLine(message)];
    NSMutableArray<NSString *> *events = OPNInMemoryLogEvents();
    @synchronized (events) {
        [events addObject:line];
        while (events.count > 200) [events removeObjectAtIndex:0];
    }
}

void CopyCapturedLogToClipboard(NSString *reason) {
    if (reason.length > 0) {
        AppendLogEvent([NSString stringWithFormat:@"[Clipboard] Copying diagnostics to clipboard: %@", reason]);
    }

    NSMutableArray<NSString *> *events = OPNInMemoryLogEvents();
    NSString *log = @"";
    @synchronized (events) {
        log = [events componentsJoinedByString:@"\n"];
    }
    if (log.length == 0) {
        log = reason.length > 0 ? reason : @"OpenNOW diagnostics copy requested, but no in-memory events were available.";
    }

    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:log forType:NSPasteboardTypeString];
    OPN::LogInfo(@"[LogCapture] Copied diagnostics to clipboard (%lu chars)", (unsigned long)log.length);
}

NSString *CapturedLogPath() {
    return @"";
}

}
