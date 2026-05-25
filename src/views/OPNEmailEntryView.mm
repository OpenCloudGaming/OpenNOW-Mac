#import "OPNEmailEntryView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNUIHelpers.h"
#import "../common/OPNAuthTypes.h"
#import "../auth/OPNAuthService.h"

@interface OPNEmailEntryView ()
@property (nonatomic, strong) NSPopUpButton *providerPopup;
@end

@implementation OPNEmailEntryView {
    std::vector<OPN::GameProviderEndpoint> _providers;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self buildUI];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)buildUI {
    using namespace OPN;

    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 500)];
    content.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    content.frame = NSMakeRect(floor((NSWidth(self.bounds) - 480) / 2.0),
                               floor((NSHeight(self.bounds) - 500) / 2.0), 480, 500);
    [self addSubview:content];

    NSView *brand = [[NSView alloc] initWithFrame:NSMakeRect(156, 12, 168, 42)];
    [content addSubview:brand];

    [brand addSubview:OpnLabel(@"OpenNOW", NSMakeRect(0, 9, 168, 24),
                               20, OpnColor(kTextPrimary), NSFontWeightSemibold, NSTextAlignmentCenter)];

    NSView *card = [[NSView alloc] initWithFrame:NSMakeRect(40, 72, 400, 372)];
    card.wantsLayer = YES;
    card.layer.backgroundColor = OpnColor(kSurfaceRaised, 0.86).CGColor;
    card.layer.cornerRadius = 22;
    card.layer.borderWidth = 1;
    card.layer.borderColor = OpnColor(0xFFFFFF, 0.10).CGColor;
    card.layer.shadowColor = NSColor.blackColor.CGColor;
    card.layer.shadowOpacity = 0.26;
    card.layer.shadowRadius = 24;
    card.layer.shadowOffset = CGSizeMake(0, 14);
    [content addSubview:card];

    [card addSubview:OpnLabel(@"Access your cloud gaming library with your NVIDIA account.",
                               NSMakeRect(56, 48, 288, 38), 13,
                               OpnColor(kTextMuted), NSFontWeightRegular, NSTextAlignmentCenter)];

    [card addSubview:OpnLabel(@"Sign-in provider", NSMakeRect(56, 116, 288, 18), 12,
                              OpnColor(kTextMuted), NSFontWeightMedium)];

    self.providerPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(56, 138, 288, 38) pullsDown:NO];
    self.providerPopup.bordered = NO;
    self.providerPopup.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    self.providerPopup.contentTintColor = OpnColor(kTextPrimary);
    self.providerPopup.wantsLayer = YES;
    self.providerPopup.layer.backgroundColor = OpnColor(0x090F0C, 0.80).CGColor;
    self.providerPopup.layer.cornerRadius = 11.0;
    self.providerPopup.layer.borderWidth = 1.0;
    self.providerPopup.layer.borderColor = OpnColor(0xFFFFFF, 0.10).CGColor;
    [card addSubview:self.providerPopup];
    [self setLoginProviders:std::vector<OPN::GameProviderEndpoint>() selectedProviderIdpId:OPN::AuthService::kDefaultIdpId];

    self.stayLoggedInToggle = [[NSButton alloc] initWithFrame:NSMakeRect(54, 210, 180, 24)];
    self.stayLoggedInToggle.buttonType = NSButtonTypeSwitch;
    self.stayLoggedInToggle.title = @"Keep me signed in";
    self.stayLoggedInToggle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    self.stayLoggedInToggle.contentTintColor = OpnColor(kBrandGreen);
    self.stayLoggedInToggle.state = OPN::AuthService::Shared().GetStayLoggedIn()
        ? NSControlStateValueOn : NSControlStateValueOff;
    [card addSubview:self.stayLoggedInToggle];

    NSButton *browserButton = OpnButton(@"Continue with Browser",
        NSMakeRect(56, 266, 288, 48),
        OpnColor(kBrandGreen), OpnColor(kAccentOn));
    browserButton.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    browserButton.target = self;
    browserButton.action = @selector(signInWithBrowserClicked);
    [card addSubview:browserButton];

    [content addSubview:OpnLabel(@"Open-source cloud gaming client for macOS",
                                 NSMakeRect(0, 468, 480, 20), 12,
                                 OpnColor(kTextMuted), NSFontWeightRegular, NSTextAlignmentCenter)];
}

- (void)setLoginProviders:(const std::vector<OPN::GameProviderEndpoint> &)providers
      selectedProviderIdpId:(const std::string &)selectedProviderIdpId {
    _providers.clear();
    for (const OPN::GameProviderEndpoint &provider : providers) {
        if (provider.idpId.empty()) continue;
        _providers.push_back(provider);
    }
    if (_providers.empty()) {
        OPN::GameProviderEndpoint fallback;
        fallback.idpId = OPN::AuthService::kDefaultIdpId;
        fallback.loginProviderCode = "NVIDIA";
        fallback.loginProviderDisplayName = "NVIDIA";
        fallback.streamingServiceUrl = "https://prod.cloudmatchbeta.nvidiagrid.net/";
        _providers.push_back(fallback);
    }

    [self.providerPopup removeAllItems];
    NSInteger selectedIndex = 0;
    for (size_t i = 0; i < _providers.size(); i++) {
        const OPN::GameProviderEndpoint &provider = _providers[i];
        std::string label = provider.loginProviderCode == "BPC" ? "bro.game" : provider.loginProviderDisplayName;
        if (label.empty()) label = provider.loginProviderCode.empty() ? "NVIDIA" : provider.loginProviderCode;
        [self.providerPopup addItemWithTitle:[NSString stringWithUTF8String:label.c_str()]];
        if (!selectedProviderIdpId.empty() && provider.idpId == selectedProviderIdpId) selectedIndex = (NSInteger)i;
    }
    [self.providerPopup selectItemAtIndex:selectedIndex];
}

- (std::string)selectedProviderIdpId {
    NSInteger index = self.providerPopup.indexOfSelectedItem;
    if (index < 0 || (size_t)index >= _providers.size()) return OPN::AuthService::kDefaultIdpId;
    return _providers[(size_t)index].idpId.empty() ? OPN::AuthService::kDefaultIdpId : _providers[(size_t)index].idpId;
}

- (void)signInWithBrowserClicked {
    using namespace OPN;
    bool stayLoggedIn = self.stayLoggedInToggle.state == NSControlStateValueOn;
    AuthService::Shared().SetStayLoggedIn(stayLoggedIn);
    if (self.onSignInWithBrowser) {
        self.onSignInWithBrowser();
    }
}

@end
