#import <Cocoa/Cocoa.h>
#include <string>
#include <vector>
#include "../common/OPNGameTypes.h"

@interface OPNEmailEntryView : NSView
@property (nonatomic, copy) void (^onSignInWithBrowser)(void);
@property (nonatomic, strong) NSButton *stayLoggedInToggle;
- (void)setLoginProviders:(const std::vector<OPN::GameProviderEndpoint> &)providers
      selectedProviderIdpId:(const std::string &)selectedProviderIdpId;
- (std::string)selectedProviderIdpId;
@end
