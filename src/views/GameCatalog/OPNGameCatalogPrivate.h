#pragma once

#import "../OPNGameCatalogView.h"
#import "../OPNLoadingView.h"
#import "../../common/OPNColorTokens.h"
#include "../../common/OPNSentry.h"
#include "../../common/OPNGameRemediation.h"
#import "../../common/OPNUIHelpers.h"
#include "../../streaming/OPNStreamPreferences.h"
#import <GameController/GameController.h>
#include <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <limits>
#include <memory>
#include <unordered_map>

extern const CGFloat kStoreTopInset;
extern const CGFloat kStoreNavigationClearance;
extern const CGFloat kStoreHeroHeightRatio;
extern const CGFloat kStoreRowHeight;
extern const CGFloat kStoreCardSpacing;
extern const CGFloat kStoreTileWidth;
extern const CGFloat kStoreTileHeight;
extern const CGFloat kStoreHeroMinContentInset;
extern const CGFloat kStoreHeroMaxContentInset;
extern const CGFloat kStoreHeroContentInsetRatio;
extern const CGFloat kStoreFallbackHeroAspect;
extern const CGFloat kStoreHeroMaxHeight;
extern const CGFloat kStoreHeroMaxViewportRatio;
extern const CGFloat kStoreHeroLogoMaxWidth;
extern const CGFloat kStoreHeroLogoMaxHeight;
extern const CGFloat kStoreHeroFirstRowSpacing;
extern const CGFloat kStoreButtonHintPillHeight;
extern const CGFloat kStoreButtonHintPillBottomInset;
extern const CGFloat kStoreTopFoldNextRowInset;
extern const CGFloat kStoreSearchPanelMinWidth;
extern const CGFloat kStoreSearchPanelMaxWidth;
extern const CGFloat kStoreRailInertiaMinimumVelocity;
extern const CGFloat kStoreRailInertiaResistancePerSecond;
extern const NSInteger kStoreRailImagePreloadCardBuffer;
extern const NSTimeInterval kStoreSearchDebounceInterval;
extern const NSTimeInterval kStoreHeroBackgroundFadeDuration;
extern const NSTimeInterval kStoreHeroLogoFadeDuration;
extern const NSTimeInterval kStoreHeroLogoFadeDelay;

typedef NS_ENUM(NSInteger, OPNStoreControllerFamily) {
    OPNStoreControllerFamilyKeyboard = 0,
    OPNStoreControllerFamilyXbox,
    OPNStoreControllerFamilyPlayStation,
    OPNStoreControllerFamilyNintendo,
    OPNStoreControllerFamilyGeneric,
};

struct OPNStoreControllerHintStyle {
    NSString *selectGlyph;
    NSString *variantGlyph;
};

@interface OPNStoreDocumentView : NSView
@end

@interface OPNStoreRailScrollView : NSScrollView
- (void)scrollHorizontallyByDelta:(CGFloat)deltaX;
- (void)beginDragScrollingAtTime:(NSTimeInterval)timestamp;
- (void)dragScrollHorizontallyByDelta:(CGFloat)deltaX timestamp:(NSTimeInterval)timestamp;
- (void)endDragScrollingWithInertia;
@end

@interface OPNStoreHintFixedView : NSView
@property (nonatomic, assign) NSSize fixedSize;
@end

@interface OPNStoreHintPillView : NSView
@end

@interface OPNStoreGameTile : NSView
@property (nonatomic, readonly) OPN::GameInfo game;
@property (nonatomic, readonly) BOOL prominent;
@property (nonatomic, assign) int selectedVariantIndex;
@property (nonatomic, assign) NSTimeInterval imageRevealDelay;
@property (nonatomic, copy) void (^onSelect)(void);
@property (nonatomic, copy) void (^onBuy)(NSString *purchaseURL);
@property (nonatomic, copy) void (^onMarkUnowned)(void);
@property (nonatomic, copy) void (^onHover)(void);
- (instancetype)initWithFrame:(NSRect)frame game:(const OPN::GameInfo &)game prominent:(BOOL)prominent;
- (void)setStoreFocused:(BOOL)focused;
- (void)activate;
- (void)cycleSelectedVariant;
- (void)ensureImageLoaded;
- (void)cancelImageLoad;
- (void)resetMouseTrackingIfOutside;
@end

@interface OPNStoreRowLayout : NSObject
@property (nonatomic, strong) NSView *glowView;
@property (nonatomic, strong) NSTextField *indexLabel;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *hintLabel;
@property (nonatomic, strong) OPNStoreRailScrollView *scrollView;
@property (nonatomic, strong) OPNStoreDocumentView *documentView;
@property (nonatomic, strong) NSMutableArray<OPNStoreGameTile *> *cards;
@property (nonatomic, assign) CGFloat y;
@property (nonatomic, assign) BOOL mounted;
@end

CGFloat OPNStoreHeroHeightForWidth(CGFloat width, CGFloat viewportHeight);
CGFloat OPNStoreNextRowYAfterRow(CGFloat rowY, NSInteger rowIndex, BOOL hasHero, CGFloat viewportHeight);
OPNStoreControllerFamily OPNStoreConnectedControllerFamily(void);
OPNStoreControllerHintStyle OPNStoreControllerHintStyleForFamily(OPNStoreControllerFamily family);
OPNStoreHintFixedView *OPNStoreHintKeyView(NSString *symbolName, NSString *fallback, CGFloat width);
OPNStoreHintFixedView *OPNStoreControllerIconKeyView(NSString *glyph, CGFloat width);
NSStackView *OPNStoreHintGroup(NSArray<OPNStoreHintFixedView *> *keys, NSString *title);
CGFloat OPNStoreHeroContentInsetForWidth(CGFloat width);
CGFloat OPNStoreTileWidthForRailWidth(CGFloat width);
NSSize OPNStoreTileMetricsForRailWidth(CGFloat width);
NSString *OPNStoreString(const std::string &value, NSString *fallback);
NSString *OPNStoreSearchNormalizedString(NSString *value);
std::vector<OPN::GameInfo> OPNStoreSearchFilteredGames(const std::vector<OPN::GameInfo> &games, NSString *query);
std::vector<OPN::PanelResult> OPNStoreSearchFilteredPanels(const std::vector<OPN::PanelResult> &panels, NSString *query);
NSString *OPNStoreDisplayLabel(NSString *value);
NSString *OPNStoreDisplayString(const std::string &value, NSString *fallback);
NSImage *OPNCachedStoreIconImage(NSString *name);
NSImage *OPNStoreGreyscaleIconImage(NSImage *image);
NSImage *OPNStoreIconPlaceholderImage(NSString *name);
void OPNLoadStoreIconImage(NSString *name, void (^completion)(NSImage *image));
NSImage *OPNStoreFallbackArtworkImage(void);
NSString *OPNStorePrimaryStoreName(const OPN::GameInfo &game);
NSArray<NSString *> *OPNStoreVariantStoreNames(const OPN::GameInfo &game);
bool OPNStoreStringEqualsCaseInsensitive(const std::string &lhs, const std::string &rhs);
NSArray<NSString *> *OPNStoreImageCandidatesForGame(const OPN::GameInfo &game, BOOL prominent);
NSArray<NSString *> *OPNStoreLogoCandidatesForGame(const OPN::GameInfo &game);
NSImage *OPNStoreVisibleLogoImage(NSImage *image);
NSRect OPNStoreHeroVisibleArtworkRectForImage(NSImage *image, NSRect bounds);
NSRect OPNStoreHeroLogoFrameForImage(NSImage *image, NSRect bounds, NSImage *artworkImage);
NSRect OPNStoreHeroLogoFallbackFrame(NSRect bounds, NSImage *artworkImage);
void OPNStoreHeroBringLogoToFront(NSView *container, NSTextField *titleFallback, NSImageView *logoView);
void OPNStoreConfigureHeroLogoImageView(NSImageView *logoView, CGFloat zPosition);
BOOL OPNStoreHeroImageHasVisibleContent(NSImage *image);
NSString *OPNStorePrimaryGenre(const OPN::GameInfo &game);
NSString *OPNStoreFeatureSummary(const OPN::GameInfo &game);
bool OPNStoreGameMatchesLibraryGame(const OPN::GameInfo &storeGame, const OPN::GameInfo &libraryGame);
bool OPNStoreClearGameOwnershipMetadata(OPN::GameInfo &game);
bool OPNStoreMergeGameStoreMetadata(OPN::GameInfo &target, const OPN::GameInfo &source);
std::string OPNStorePanelsFingerprint(const std::vector<OPN::PanelResult> &panels);
std::vector<OPN::PanelResult> OPNCatalogPanelsForGames(const std::vector<OPN::GameInfo> &sourceGames);
OPN::PanelSection OPNCatalogSingleLibrarySectionForGames(const std::vector<OPN::GameInfo> &sourceGames);
int OPNStoreSelectedLibraryVariantIndex(const OPN::GameInfo &libraryGame);
bool OPNStoreVariantCanBeMarkedUnowned(const OPN::GameInfo &game, int variantIndex);
NSString *OPNStorePrimaryActionTitle(const OPN::GameInfo &game, int variantIndex, BOOL prominent);
std::string OPNStoreGameProfileAppId(const OPN::GameInfo &game, int variantIndex);
NSString *OPNStoreAvailabilityTitle(const OPN::GameInfo &game, int variantIndex);

@interface OPNGameCatalogView () <NSSearchFieldDelegate> {
    NSScrollView *_scrollView;
    OPNStoreDocumentView *_documentView;
    OPNLoadingView *_loadingView;
    NSTextField *_statusLabel;
    OPNStoreHintPillView *_buttonHintPillView;
    NSStackView *_buttonHintStackView;
    NSView *_searchPanelView;
    NSSearchField *_searchField;
    NSString *_searchQuery;
    NSString *_completedSearchQuery;
    NSInteger _searchGeneration;
    BOOL _searchInFlight;
    NSTimer *_searchDebounceTimer;
    dispatch_queue_t _searchQueue;
    std::shared_ptr<const std::vector<OPN::GameInfo>> _searchLibrarySnapshot;
    std::shared_ptr<const std::vector<OPN::PanelResult>> _searchPanelsSnapshot;
    std::vector<OPN::GameInfo> _filteredLibraryGames;
    std::vector<OPN::PanelResult> _filteredPanels;
    std::vector<OPN::PanelResult> _panels;
    std::vector<OPN::GameInfo> _libraryGames;
    std::vector<OPN::GameInfo> _ownedLibraryGames;
    std::vector<OPN::GameInfo> _featuredGames;
    BOOL _hasLibraryState;
    NSMutableArray<NSMutableArray<OPNStoreGameTile *> *> *_rowCards;
    NSMutableArray<OPNStoreRowLayout *> *_rowLayouts;
    NSMutableArray<OpnImageLoadToken *> *_heroImageLoadTokens;
    NSMutableArray<OpnImageLoadToken *> *_prefetchImageLoadTokens;
    NSTimer *_heroRotationTimer;
    NSMutableArray<NSView *> *_desktopFeaturedHeroViews;
    NSView *_desktopHeroContainer;
    OPNHeroArtworkView *_desktopHeroArtworkView;
    OPNHeroArtworkView *_desktopHeroArtworkTransitionView;
    NSTextField *_desktopHeroTitleFallback;
    NSImageView *_desktopHeroLogoView;
    NSImageView *_desktopHeroLogoTransitionView;
    NSString *_desktopHeroIdentity;
    NSInteger _desktopHeroGeneration;
    NSImage *_initialHeroImage;
    NSString *_initialHeroIdentity;
    NSRect _desktopFeaturedHeroFrame;
    NSInteger _currentHeroIndex;
    NSInteger _focusedRowIndex;
    NSInteger _focusedColumnIndex;
    __weak OPNStoreGameTile *_focusedTile;
    __weak OPNStoreGameTile *_hoveredTile;
    CGFloat _lastLayoutWidth;
    CGFloat _lastLayoutHeight;
    BOOL _renderStoreScheduled;
    NSTimer *_resizeRenderTimer;
    BOOL _initialHeroPreloadInFlight;
    BOOL _initialHeroReady;
    NSInteger _initialHeroPreloadGeneration;
    std::string _panelsFingerprint;
    OPNStoreControllerFamily _buttonHintControllerFamily;
}
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) OPNStoreDocumentView *documentView;
@property (nonatomic, strong) OPNLoadingView *loadingView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) OPNStoreHintPillView *buttonHintPillView;
@property (nonatomic, strong) NSStackView *buttonHintStackView;
@property (nonatomic, strong) NSView *searchPanelView;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, copy) NSString *searchQuery;
@property (nonatomic, copy) NSString *completedSearchQuery;
@property (nonatomic, assign) NSInteger searchGeneration;
@property (nonatomic, assign) BOOL searchInFlight;
@property (nonatomic, strong) NSTimer *searchDebounceTimer;
@property (nonatomic, strong) dispatch_queue_t searchQueue;
@property (nonatomic, assign) std::shared_ptr<const std::vector<OPN::GameInfo>> searchLibrarySnapshot;
@property (nonatomic, assign) std::shared_ptr<const std::vector<OPN::PanelResult>> searchPanelsSnapshot;
@property (nonatomic, assign) std::vector<OPN::GameInfo> filteredLibraryGames;
@property (nonatomic, assign) std::vector<OPN::PanelResult> filteredPanels;
@property (nonatomic, assign) std::vector<OPN::PanelResult> panels;
@property (nonatomic, assign) std::vector<OPN::GameInfo> libraryGames;
@property (nonatomic, assign) std::vector<OPN::GameInfo> ownedLibraryGames;
@property (nonatomic, assign) std::vector<OPN::GameInfo> featuredGames;
@property (nonatomic, assign) BOOL hasLibraryState;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<OPNStoreGameTile *> *> *rowCards;
@property (nonatomic, strong) NSMutableArray<OPNStoreRowLayout *> *rowLayouts;
@property (nonatomic, strong) NSMutableArray<OpnImageLoadToken *> *heroImageLoadTokens;
@property (nonatomic, strong) NSMutableArray<OpnImageLoadToken *> *prefetchImageLoadTokens;
@property (nonatomic, strong) NSTimer *heroRotationTimer;
@property (nonatomic, strong) NSMutableArray<NSView *> *desktopFeaturedHeroViews;
@property (nonatomic, strong) NSView *desktopHeroContainer;
@property (nonatomic, strong) OPNHeroArtworkView *desktopHeroArtworkView;
@property (nonatomic, strong) OPNHeroArtworkView *desktopHeroArtworkTransitionView;
@property (nonatomic, strong) NSTextField *desktopHeroTitleFallback;
@property (nonatomic, strong) NSImageView *desktopHeroLogoView;
@property (nonatomic, strong) NSImageView *desktopHeroLogoTransitionView;
@property (nonatomic, copy) NSString *desktopHeroIdentity;
@property (nonatomic, assign) NSInteger desktopHeroGeneration;
@property (nonatomic, strong) NSImage *initialHeroImage;
@property (nonatomic, copy) NSString *initialHeroIdentity;
@property (nonatomic, assign) NSRect desktopFeaturedHeroFrame;
@property (nonatomic, assign) NSInteger currentHeroIndex;
@property (nonatomic, assign) NSInteger focusedRowIndex;
@property (nonatomic, assign) NSInteger focusedColumnIndex;
@property (nonatomic, weak) OPNStoreGameTile *focusedTile;
@property (nonatomic, weak) OPNStoreGameTile *hoveredTile;
@property (nonatomic, assign) CGFloat lastLayoutWidth;
@property (nonatomic, assign) CGFloat lastLayoutHeight;
@property (nonatomic, assign) BOOL renderStoreScheduled;
@property (nonatomic, strong) NSTimer *resizeRenderTimer;
@property (nonatomic, assign) BOOL initialHeroPreloadInFlight;
@property (nonatomic, assign) BOOL initialHeroReady;
@property (nonatomic, assign) NSInteger initialHeroPreloadGeneration;
@property (nonatomic, assign) std::string panelsFingerprint;
@property (nonatomic, assign) OPNStoreControllerFamily buttonHintControllerFamily;
- (void)loadFeaturedHeroImageForView:(OPNHeroArtworkView *)view gameIdentity:(NSString *)gameIdentity candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index animated:(BOOL)animated completion:(void (^)(BOOL loaded))completion;
- (void)renderStoreWhenInitialHeroReady;
- (void)scheduleRenderStoreAfterResize;
- (void)resizeRenderTimerFired:(NSTimer *)timer;
- (void)preloadInitialHeroThenRender;
- (const OPN::GameInfo *)fallbackHeroGame;
- (void)addDesktopHeroStageForGame:(const OPN::GameInfo &)game y:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width height:(CGFloat)height;
- (void)addDesktopHeroLogoForGame:(const OPN::GameInfo &)game toContainer:(NSView *)container;
- (void)updateDesktopHeroElementsForGame:(const OPN::GameInfo &)game animated:(BOOL)animated;
- (void)updateDesktopHeroFrameForCurrentBounds;
- (void)updateRowFramesForCurrentBounds;
- (void)updateRowVirtualizationForVisibleBounds;
- (void)updateImagePreloadingForRowLayout:(OPNStoreRowLayout *)rowLayout;
- (void)updateImagePreloadingForMountedRows;
- (void)updateButtonHintPillFrame;
- (void)updateSearchPanelFrame;
- (void)rebuildButtonHintPillForCurrentController;
- (void)updateDesktopHeroLogoFrame;
- (void)setDesktopHeroArtworkImage:(NSImage *)image animated:(BOOL)animated;
- (void)setDesktopHeroLogoImage:(NSImage *)image animated:(BOOL)animated;
- (NSImageView *)newDesktopHeroLogoTransitionViewWithImage:(NSImage *)image frame:(NSRect)frame;
- (void)loadDesktopHeroLogoForGame:(const OPN::GameInfo &)game generation:(NSInteger)generation animated:(BOOL)animated;
- (void)cancelHeroImageLoads;
- (void)trackHeroImageLoadToken:(OpnImageLoadToken *)token;
- (void)cancelPrefetchImageLoads;
- (void)trackPrefetchImageLoadToken:(OpnImageLoadToken *)token;
- (void)prefetchHeroArtworkCandidates;
- (void)updateDesktopFeaturedHeroOnly;
- (void)addEmptyStoreStateWithY:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width;
- (void)scheduleRenderStore;
- (BOOL)mergeKnownStoreMetadataIntoPanels;
- (void)refreshLibrarySelections;
- (void)updateFocusedTiles;
- (void)updateHeroTileOnly;
- (void)scheduleAsyncSearchForCurrentQuery;
- (void)performAsyncSearchTimerFired:(NSTimer *)timer;
- (void)renderStore;
- (void)removeButtonHintGroups;
- (void)configureHeroRotationTimer;
- (void)heroRotationTimerFired:(NSTimer *)timer;
- (int)selectedVariantIndexForStoreGame:(const OPN::GameInfo &)storeGame;
- (NSInteger)heroCandidateCount;
- (const OPN::GameInfo *)currentHeroGame;
- (void)scrollFocusedTileIntoView;
- (void)storeScrollViewBoundsDidChange:(NSNotification *)notification;
- (void)rowScrollViewBoundsDidChange:(NSNotification *)notification;
@end
