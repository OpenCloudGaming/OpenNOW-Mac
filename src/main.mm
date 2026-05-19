#import "OPNAppDelegate.h"
#include "common/OPNSentry.h"

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        OPN::InitializeSentry();

        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;

        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];

        OPN::CloseSentry();
    }

    return 0;
}
