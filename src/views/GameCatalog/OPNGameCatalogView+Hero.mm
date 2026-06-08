#import "OPNGameCatalogPrivate.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation OPNGameCatalogView (Hero)

using namespace OPN;

- (NSInteger)heroCandidateCount {
    return MIN((NSInteger)6, (NSInteger)_featuredGames.size());
}

- (const GameInfo *)currentHeroGame {
    NSInteger candidateCount = [self heroCandidateCount];
    if (candidateCount > 0) {
        NSInteger target = ((self.currentHeroIndex % candidateCount) + candidateCount) % candidateCount;
        return &_featuredGames[(size_t)target];
    }
    return [self fallbackHeroGame];
}

- (const GameInfo *)fallbackHeroGame {
    const GameInfo *firstGame = nullptr;
    auto inspectGame = [&firstGame](const GameInfo &game) -> const GameInfo * {
        if (!firstGame) firstGame = &game;
        return OpnHeroImageCandidatesForGame(game).count > 0 ? &game : nullptr;
    };

    for (const PanelResult &panel : _panels) {
        for (const PanelSection &section : panel.sections) {
            for (const GameInfo &game : section.games) {
                if (const GameInfo *candidate = inspectGame(game)) return candidate;
            }
        }
    }
    for (const GameInfo &game : _ownedLibraryGames) {
        if (const GameInfo *candidate = inspectGame(game)) return candidate;
    }
    for (const GameInfo &game : _libraryGames) {
        if (const GameInfo *candidate = inspectGame(game)) return candidate;
    }
    return firstGame;
}

- (void)configureHeroRotationTimer {
    [self.heroRotationTimer invalidate];
    self.heroRotationTimer = nil;
    if ([self heroCandidateCount] < 2) return;

    self.heroRotationTimer = [NSTimer scheduledTimerWithTimeInterval:7.0
                                                              target:self
                                                            selector:@selector(heroRotationTimerFired:)
                                                            userInfo:nil
                                                             repeats:YES];
}

- (void)heroRotationTimerFired:(NSTimer *)timer {
    (void)timer;
    NSInteger candidateCount = [self heroCandidateCount];
    if (candidateCount < 2) return;
    self.currentHeroIndex = (self.currentHeroIndex + 1) % candidateCount;
    [self updateHeroTileOnly];
}

- (void)renderStoreWhenInitialHeroReady {
    const GameInfo *heroGame = [self currentHeroGame];
    if (!heroGame || self.initialHeroReady) {
        [self renderStore];
        return;
    }
    [self preloadInitialHeroThenRender];
}

- (void)preloadInitialHeroThenRender {
    if (self.initialHeroPreloadInFlight) return;
    const GameInfo *heroGame = [self currentHeroGame];
    if (!heroGame) {
        self.initialHeroReady = YES;
        [self renderStore];
        return;
    }

    NSString *gameIdentity = OpnGameIdentityForHero(*heroGame);
    NSArray<NSString *> *candidates = OpnHeroImageCandidatesForGame(*heroGame);
    NSImage *cachedImage = OpnCachedMemoryImageFromCandidates(candidates, 1600.0, nil);
    if (OPNStoreHeroImageHasVisibleContent(cachedImage)) {
        self.initialHeroImage = cachedImage;
        self.initialHeroIdentity = gameIdentity;
        self.initialHeroReady = YES;
        [self renderStore];
        return;
    }

    if (candidates.count == 0) {
        self.initialHeroImage = OpnFallbackHeroArtworkImage();
        self.initialHeroIdentity = gameIdentity;
        self.initialHeroReady = YES;
        [self renderStore];
        return;
    }

    self.initialHeroPreloadInFlight = YES;
    NSInteger preloadGeneration = self.initialHeroPreloadGeneration;
    __weak __typeof__(self) weakSelf = self;
    __block BOOL completed = NO;
    NSArray<NSString *> *activeCandidates = [candidates subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)2, candidates.count))];
    __block NSInteger remainingLoads = (NSInteger)activeCandidates.count;
    for (NSString *candidateURL in activeCandidates) {
        OpnImageLoadToken *token = OpnLoadImageForURLCancellable(candidateURL, 1600.0, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
            (void)resolvedURL;
            (void)data;
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf || completed || preloadGeneration != strongSelf.initialHeroPreloadGeneration) return;
            if (!OPNStoreHeroImageHasVisibleContent(image)) {
                remainingLoads--;
                if (remainingLoads > 0) return;
                completed = YES;
                strongSelf.initialHeroImage = OpnFallbackHeroArtworkImage();
            } else {
                completed = YES;
                strongSelf.initialHeroImage = image;
            }
            strongSelf.initialHeroIdentity = gameIdentity;
            strongSelf.initialHeroReady = YES;
            strongSelf.initialHeroPreloadInFlight = NO;
            [strongSelf renderStore];
        });
        [self trackHeroImageLoadToken:token];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || completed || preloadGeneration != strongSelf.initialHeroPreloadGeneration) return;
        completed = YES;
        strongSelf.initialHeroImage = OpnFallbackHeroArtworkImage();
        strongSelf.initialHeroIdentity = gameIdentity;
        strongSelf.initialHeroReady = YES;
        strongSelf.initialHeroPreloadInFlight = NO;
        [strongSelf renderStore];
    });
}

- (void)cancelHeroImageLoads {
    for (OpnImageLoadToken *token in self.heroImageLoadTokens) [token cancel];
    [self.heroImageLoadTokens removeAllObjects];
}

- (void)trackHeroImageLoadToken:(OpnImageLoadToken *)token {
    if (!token) return;
    [self.heroImageLoadTokens addObject:token];
    if (self.heroImageLoadTokens.count > 12) [self.heroImageLoadTokens removeObjectsInRange:NSMakeRange(0, self.heroImageLoadTokens.count - 8)];
}

- (void)cancelPrefetchImageLoads {
    for (OpnImageLoadToken *token in self.prefetchImageLoadTokens) [token cancel];
    [self.prefetchImageLoadTokens removeAllObjects];
}

- (void)trackPrefetchImageLoadToken:(OpnImageLoadToken *)token {
    if (!token) return;
    [self.prefetchImageLoadTokens addObject:token];
    if (self.prefetchImageLoadTokens.count > 36) {
        NSUInteger removeCount = self.prefetchImageLoadTokens.count - 24;
        for (NSUInteger index = 0; index < removeCount; index++) [self.prefetchImageLoadTokens[index] cancel];
        [self.prefetchImageLoadTokens removeObjectsInRange:NSMakeRange(0, removeCount)];
    }
}

- (void)prefetchHeroArtworkCandidates {
    [self cancelPrefetchImageLoads];
    NSInteger candidateCount = [self heroCandidateCount];
    for (NSInteger index = 0; index < candidateCount; index++) {
        const GameInfo &game = _featuredGames[(size_t)index];
        NSArray<NSString *> *candidates = OpnHeroImageCandidatesForGame(game);
        if (candidates.count == 0) continue;
        [self trackPrefetchImageLoadToken:OpnPrefetchImageFromCandidates(candidates, 1600.0)];
        NSArray<NSString *> *logoCandidates = OPNStoreLogoCandidatesForGame(game);
        if (logoCandidates.count > 0) [self trackPrefetchImageLoadToken:OpnPrefetchImageFromCandidates(logoCandidates, 720.0)];
    }
}

- (void)addDesktopHeroStageForGame:(const GameInfo &)game y:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width height:(CGFloat)height {
    self.desktopFeaturedHeroFrame = NSMakeRect(contentX, y, width, height);

    NSView *container = [[NSView alloc] initWithFrame:self.desktopFeaturedHeroFrame];
    container.autoresizingMask = NSViewWidthSizable;
    container.wantsLayer = YES;
    container.layer.backgroundColor = [NSColor clearColor].CGColor;
    container.layer.masksToBounds = YES;
    [self.documentView addSubview:container];
    self.desktopHeroContainer = container;

    OPNHeroArtworkView *artwork = [[OPNHeroArtworkView alloc] initWithFrame:container.bounds];
    artwork.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    artwork.image = OpnFallbackHeroArtworkImage();
    [container addSubview:artwork positioned:NSWindowBelow relativeTo:nil];
    self.desktopHeroArtworkView = artwork;

    [self addDesktopHeroLogoForGame:game toContainer:container];
    [self updateDesktopHeroElementsForGame:game animated:NO];
    [self.desktopFeaturedHeroViews addObject:container];
}

- (void)addDesktopHeroLogoForGame:(const GameInfo &)game toContainer:(NSView *)container {
    if (!container) return;
    (void)game;

    NSShadow *textShadow = [[NSShadow alloc] init];
    textShadow.shadowBlurRadius = 18.0;
    textShadow.shadowOffset = NSMakeSize(0.0, -2.0);
    textShadow.shadowColor = OpnColor(OPN::kBlack, 0.82);

    NSTextField *titleFallback = OpnLabel(@"", OPNStoreHeroLogoFallbackFrame(container.bounds, OpnFallbackHeroArtworkImage()), 42.0, OpnColor(OPN::kTextPrimary), NSFontWeightBlack);
    titleFallback.maximumNumberOfLines = 2;
    titleFallback.lineBreakMode = NSLineBreakByWordWrapping;
    titleFallback.shadow = textShadow;
    titleFallback.wantsLayer = YES;
    titleFallback.layer.zPosition = 1000.0;
    [container addSubview:titleFallback positioned:NSWindowAbove relativeTo:nil];
    self.desktopHeroTitleFallback = titleFallback;

    NSImageView *logoView = [[NSImageView alloc] initWithFrame:OPNStoreHeroLogoFallbackFrame(container.bounds, OpnFallbackHeroArtworkImage())];
    logoView.hidden = YES;
    OPNStoreConfigureHeroLogoImageView(logoView, 1001.0);
    [container addSubview:logoView positioned:NSWindowAbove relativeTo:nil];
    self.desktopHeroLogoView = logoView;
}

- (void)setDesktopHeroArtworkImage:(NSImage *)image animated:(BOOL)animated {
    if (!image || !self.desktopHeroContainer || !self.desktopHeroArtworkView) return;
    if (!animated || !self.desktopHeroArtworkView.image || !self.desktopHeroArtworkView.superview) {
        [self.desktopHeroArtworkTransitionView removeFromSuperview];
        self.desktopHeroArtworkTransitionView = nil;
        self.desktopHeroArtworkView.image = image;
        self.desktopHeroArtworkView.alphaValue = 1.0;
        [self updateDesktopHeroLogoFrame];
        return;
    }
    if (self.desktopHeroArtworkView.image == image && !self.desktopHeroArtworkTransitionView) {
        [self updateDesktopHeroLogoFrame];
        return;
    }
    if (self.desktopHeroArtworkTransitionView.image == image) return;

    [self.desktopHeroArtworkTransitionView removeFromSuperview];
    OPNHeroArtworkView *transitionView = [[OPNHeroArtworkView alloc] initWithFrame:self.desktopHeroArtworkView.frame];
    transitionView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    transitionView.image = image;
    transitionView.alphaValue = 0.0;
    [self.desktopHeroContainer addSubview:transitionView positioned:NSWindowAbove relativeTo:self.desktopHeroArtworkView];
    self.desktopHeroArtworkTransitionView = transitionView;
    OPNStoreHeroBringLogoToFront(self.desktopHeroContainer, self.desktopHeroTitleFallback, self.desktopHeroLogoView);
    if (self.desktopHeroLogoTransitionView.superview == self.desktopHeroContainer) {
        [self.desktopHeroContainer addSubview:self.desktopHeroLogoTransitionView positioned:NSWindowAbove relativeTo:nil];
    }

    __weak __typeof__(self) weakSelf = self;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = kStoreHeroBackgroundFadeDuration;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        transitionView.animator.alphaValue = 1.0;
    } completionHandler:^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.desktopHeroArtworkTransitionView != transitionView) return;
        strongSelf.desktopHeroArtworkView.image = image;
        strongSelf.desktopHeroArtworkView.alphaValue = 1.0;
        [transitionView removeFromSuperview];
        strongSelf.desktopHeroArtworkTransitionView = nil;
        [strongSelf updateDesktopHeroLogoFrame];
    }];
}

- (NSImageView *)newDesktopHeroLogoTransitionViewWithImage:(NSImage *)image frame:(NSRect)frame {
    NSImageView *transitionView = [[NSImageView alloc] initWithFrame:frame];
    transitionView.image = image;
    transitionView.alphaValue = 0.0;
    transitionView.hidden = NO;
    OPNStoreConfigureHeroLogoImageView(transitionView, 1002.0);
    return transitionView;
}

- (void)setDesktopHeroLogoImage:(NSImage *)image animated:(BOOL)animated {
    if (!self.desktopHeroContainer || !self.desktopHeroLogoView || !self.desktopHeroTitleFallback) return;
    [self.desktopHeroLogoTransitionView removeFromSuperview];
    self.desktopHeroLogoTransitionView = nil;

    if (!animated) {
        self.desktopHeroLogoView.image = image;
        self.desktopHeroLogoView.frame = image ? OPNStoreHeroLogoFrameForImage(image, self.desktopHeroContainer.bounds, self.desktopHeroArtworkView.image) : OPNStoreHeroLogoFallbackFrame(self.desktopHeroContainer.bounds, self.desktopHeroArtworkView.image);
        self.desktopHeroLogoView.alphaValue = 1.0;
        self.desktopHeroLogoView.hidden = image == nil;
        self.desktopHeroTitleFallback.hidden = image != nil;
        self.desktopHeroTitleFallback.alphaValue = 1.0;
        OPNStoreHeroBringLogoToFront(self.desktopHeroContainer, self.desktopHeroTitleFallback, self.desktopHeroLogoView);
        return;
    }

    if (!image) {
        NSInteger generation = self.desktopHeroGeneration;
        self.desktopHeroTitleFallback.alphaValue = 0.0;
        self.desktopHeroTitleFallback.hidden = NO;
        __weak __typeof__(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStoreHeroLogoFadeDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.desktopHeroContainer || strongSelf.desktopHeroGeneration != generation) return;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = kStoreHeroLogoFadeDuration;
                context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
                strongSelf.desktopHeroLogoView.animator.alphaValue = 0.0;
                strongSelf.desktopHeroTitleFallback.animator.alphaValue = 1.0;
            } completionHandler:^{
                if (!strongSelf || strongSelf.desktopHeroGeneration != generation) return;
                strongSelf.desktopHeroLogoView.image = nil;
                strongSelf.desktopHeroLogoView.hidden = YES;
                strongSelf.desktopHeroLogoView.alphaValue = 1.0;
            }];
        });
        return;
    }

    NSRect logoFrame = OPNStoreHeroLogoFrameForImage(image, self.desktopHeroContainer.bounds, self.desktopHeroArtworkView.image);
    NSImageView *transitionView = [self newDesktopHeroLogoTransitionViewWithImage:image frame:logoFrame];
    [self.desktopHeroContainer addSubview:transitionView positioned:NSWindowAbove relativeTo:nil];
    self.desktopHeroLogoTransitionView = transitionView;
    OPNStoreHeroBringLogoToFront(self.desktopHeroContainer, self.desktopHeroTitleFallback, self.desktopHeroLogoView);
    [self.desktopHeroContainer addSubview:transitionView positioned:NSWindowAbove relativeTo:nil];

    __weak __typeof__(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStoreHeroLogoFadeDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.desktopHeroLogoTransitionView != transitionView) return;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = kStoreHeroLogoFadeDuration;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            transitionView.animator.alphaValue = 1.0;
            strongSelf.desktopHeroLogoView.animator.alphaValue = 0.0;
            strongSelf.desktopHeroTitleFallback.animator.alphaValue = 0.0;
        } completionHandler:^{
            if (!strongSelf || strongSelf.desktopHeroLogoTransitionView != transitionView) return;
            strongSelf.desktopHeroLogoView.frame = logoFrame;
            strongSelf.desktopHeroLogoView.image = image;
            strongSelf.desktopHeroLogoView.hidden = NO;
            strongSelf.desktopHeroLogoView.alphaValue = 1.0;
            strongSelf.desktopHeroTitleFallback.hidden = YES;
            strongSelf.desktopHeroTitleFallback.alphaValue = 1.0;
            [transitionView removeFromSuperview];
            strongSelf.desktopHeroLogoTransitionView = nil;
            OPNStoreHeroBringLogoToFront(strongSelf.desktopHeroContainer, strongSelf.desktopHeroTitleFallback, strongSelf.desktopHeroLogoView);
        }];
    });
}

- (void)updateDesktopHeroElementsForGame:(const GameInfo &)game animated:(BOOL)animated {
    if (!self.desktopHeroContainer || !self.desktopHeroArtworkView || !self.desktopHeroTitleFallback || !self.desktopHeroLogoView) return;
    self.desktopHeroGeneration++;
    NSInteger generation = self.desktopHeroGeneration;
    NSString *gameIdentity = OpnGameIdentityForHero(game);
    self.desktopHeroIdentity = gameIdentity;
    OPNStoreHeroBringLogoToFront(self.desktopHeroContainer, self.desktopHeroTitleFallback, self.desktopHeroLogoView);

    self.desktopHeroTitleFallback.stringValue = OPNStoreString(game.title, @"");
    self.desktopHeroTitleFallback.frame = OPNStoreHeroLogoFallbackFrame(self.desktopHeroContainer.bounds, self.desktopHeroArtworkView.image);
    if (!animated) {
        self.desktopHeroTitleFallback.hidden = NO;
        self.desktopHeroTitleFallback.alphaValue = 1.0;
        [self setDesktopHeroLogoImage:nil animated:NO];
    }

    NSArray<NSString *> *heroCandidates = OpnHeroImageCandidatesForGame(game);
    NSImage *cachedImage = ([self.initialHeroIdentity isEqualToString:gameIdentity] && OPNStoreHeroImageHasVisibleContent(self.initialHeroImage))
        ? self.initialHeroImage
        : OpnCachedMemoryImageFromCandidates(heroCandidates, 1600.0, nil);
    if (OPNStoreHeroImageHasVisibleContent(cachedImage)) {
        [self setDesktopHeroArtworkImage:cachedImage animated:animated];
        [self updateDesktopHeroLogoFrame];
    } else if (!animated) {
        [self setDesktopHeroArtworkImage:OpnFallbackHeroArtworkImage() animated:NO];
        [self updateDesktopHeroLogoFrame];
    }

    __weak __typeof__(self) weakSelf = self;
    [self loadFeaturedHeroImageForView:self.desktopHeroArtworkView gameIdentity:gameIdentity candidates:heroCandidates index:0 animated:animated completion:^(BOOL loaded) {
        (void)loaded;
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.desktopHeroGeneration) return;
    }];
    [self loadDesktopHeroLogoForGame:game generation:generation animated:animated];
}

- (void)updateDesktopHeroLogoFrame {
    if (!self.desktopHeroContainer || !self.desktopHeroArtworkView || !self.desktopHeroTitleFallback || !self.desktopHeroLogoView) return;
    NSImage *artworkImage = self.desktopHeroArtworkView.image;
    self.desktopHeroTitleFallback.frame = OPNStoreHeroLogoFallbackFrame(self.desktopHeroContainer.bounds, artworkImage);
    if (self.desktopHeroLogoView.image) {
        self.desktopHeroLogoView.frame = OPNStoreHeroLogoFrameForImage(self.desktopHeroLogoView.image, self.desktopHeroContainer.bounds, artworkImage);
    } else {
        self.desktopHeroLogoView.frame = OPNStoreHeroLogoFallbackFrame(self.desktopHeroContainer.bounds, artworkImage);
    }
    if (self.desktopHeroLogoTransitionView.image) {
        self.desktopHeroLogoTransitionView.frame = OPNStoreHeroLogoFrameForImage(self.desktopHeroLogoTransitionView.image, self.desktopHeroContainer.bounds, artworkImage);
    }
    OPNStoreHeroBringLogoToFront(self.desktopHeroContainer, self.desktopHeroTitleFallback, self.desktopHeroLogoView);
    if (self.desktopHeroLogoTransitionView.superview == self.desktopHeroContainer) {
        [self.desktopHeroContainer addSubview:self.desktopHeroLogoTransitionView positioned:NSWindowAbove relativeTo:nil];
    }
}

- (void)loadDesktopHeroLogoForGame:(const GameInfo &)game generation:(NSInteger)generation animated:(BOOL)animated {
    NSArray<NSString *> *candidates = OPNStoreLogoCandidatesForGame(game);
    __weak __typeof__(self) weakSelf = self;
    void (^applyLogoImage)(NSImage *) = ^(NSImage *image) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSImage *visibleLogo = OPNStoreVisibleLogoImage(image);
            dispatch_async(dispatch_get_main_queue(), ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf || generation != strongSelf.desktopHeroGeneration || !strongSelf.desktopHeroContainer.superview) return;
                [strongSelf setDesktopHeroLogoImage:visibleLogo animated:animated];
            });
        });
    };
    NSImage *cachedLogo = OpnCachedMemoryImageFromCandidates(candidates, 720.0, nil);
    if (cachedLogo) {
        applyLogoImage(cachedLogo);
        return;
    }

    OpnImageLoadToken *token = OpnLoadImageFromCandidatesCancellable(candidates, 720.0, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (generation != strongSelf.desktopHeroGeneration || !strongSelf.desktopHeroContainer.superview) {
            return;
        }
        if (!image) {
            [strongSelf setDesktopHeroLogoImage:nil animated:animated];
            return;
        }
        applyLogoImage(image);
    });
    [self trackHeroImageLoadToken:token];
}

- (void)loadFeaturedHeroImageForView:(OPNHeroArtworkView *)view gameIdentity:(NSString *)gameIdentity candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index animated:(BOOL)animated completion:(void (^)(BOOL loaded))completion {
    if (!view) return;
    if (index >= candidates.count) {
        if (view == self.desktopHeroArtworkView) {
            if (animated) {
                if (completion) completion(NO);
                return;
            }
            [self setDesktopHeroArtworkImage:OpnFallbackHeroArtworkImage() animated:animated];
        } else {
            view.image = OpnFallbackHeroArtworkImage();
        }
        view.alphaValue = 1.0;
        if (view == self.desktopHeroArtworkView) [self updateDesktopHeroLogoFrame];
        if (completion) completion(view.image != nil);
        return;
    }
    NSString *urlString = candidates[index];
    if (urlString.length == 0) {
        [self loadFeaturedHeroImageForView:view gameIdentity:gameIdentity candidates:candidates index:index + 1 animated:animated completion:completion];
        return;
    }

    NSArray<NSString *> *remainingCandidates = [candidates subarrayWithRange:NSMakeRange(index, candidates.count - index)];
    NSImage *cachedImage = OpnCachedMemoryImageFromCandidates(remainingCandidates, 1600.0, nil);
    if (OPNStoreHeroImageHasVisibleContent(cachedImage)) {
        if (view == self.desktopHeroArtworkView) {
            [self setDesktopHeroArtworkImage:cachedImage animated:animated];
        } else {
            view.image = cachedImage;
        }
        view.alphaValue = 1.0;
        if (view == self.desktopHeroArtworkView) {
            CGFloat expectedHeroHeight = OPNStoreHeroHeightForWidth(NSWidth(self.bounds), NSHeight(self.bounds));
            if (std::fabs(expectedHeroHeight - NSHeight(self.desktopFeaturedHeroFrame)) > 1.0) {
                [self scheduleRenderStore];
                if (completion) completion(YES);
                return;
            }
            [self updateDesktopHeroLogoFrame];
        }
        if (completion) completion(YES);
        return;
    }

    __weak OPNHeroArtworkView *weakView = view;
    __weak __typeof__(self) weakSelf = self;
    __block BOOL completed = NO;
    NSArray<NSString *> *activeCandidates = [remainingCandidates subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)2, remainingCandidates.count))];
    __block NSInteger remainingLoads = (NSInteger)activeCandidates.count;
    for (NSString *candidateURL in activeCandidates) {
        OpnImageLoadToken *token = OpnLoadImageForURLCancellable(candidateURL, 1600.0, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
            (void)resolvedURL;
            (void)data;
            __typeof__(self) strongSelf = weakSelf;
            OPNHeroArtworkView *strongView = weakView;
            if (!strongSelf || !strongView.superview || completed) return;
            if (strongView == strongSelf.desktopHeroArtworkView && ![strongSelf.desktopHeroIdentity isEqualToString:gameIdentity]) return;
            if (!OPNStoreHeroImageHasVisibleContent(image)) {
                remainingLoads--;
                if (remainingLoads <= 0) {
                    completed = YES;
                    if (strongView == strongSelf.desktopHeroArtworkView) {
                        if (animated) {
                            if (completion) completion(NO);
                            return;
                        }
                        [strongSelf setDesktopHeroArtworkImage:OpnFallbackHeroArtworkImage() animated:animated];
                    } else {
                        strongView.image = OpnFallbackHeroArtworkImage();
                    }
                    strongView.alphaValue = 1.0;
                    if (strongView == strongSelf.desktopHeroArtworkView) [strongSelf updateDesktopHeroLogoFrame];
                    if (completion) completion(strongView.image != nil);
                }
                return;
            }
            completed = YES;
            if (strongView == strongSelf.desktopHeroArtworkView) {
                [strongSelf setDesktopHeroArtworkImage:image animated:animated];
            } else {
                strongView.image = image;
            }
            strongView.alphaValue = 1.0;
            if (strongView == strongSelf.desktopHeroArtworkView) {
                CGFloat expectedHeroHeight = OPNStoreHeroHeightForWidth(NSWidth(strongSelf.bounds), NSHeight(strongSelf.bounds));
                if (std::fabs(expectedHeroHeight - NSHeight(strongSelf.desktopFeaturedHeroFrame)) > 1.0) {
                    [strongSelf scheduleRenderStore];
                    if (completion) completion(YES);
                    return;
                }
                [strongSelf updateDesktopHeroLogoFrame];
            }
            if (completion) completion(YES);
        });
        [self trackHeroImageLoadToken:token];
    }
}

- (void)updateHeroTileOnly {
    [self updateDesktopFeaturedHeroOnly];
}

- (void)updateDesktopFeaturedHeroOnly {
    const GameInfo *heroGame = [self currentHeroGame];
    if (!heroGame || !self.desktopHeroContainer || !self.desktopHeroArtworkView || NSIsEmptyRect(self.desktopFeaturedHeroFrame)) {
        [self renderStore];
        return;
    }
    CGFloat expectedHeroHeight = OPNStoreHeroHeightForWidth(NSWidth(self.bounds), NSHeight(self.bounds));
    if (std::fabs(expectedHeroHeight - NSHeight(self.desktopFeaturedHeroFrame)) > 1.0) {
        [self renderStore];
        return;
    }
    [self updateDesktopHeroElementsForGame:*heroGame animated:YES];
}

@end

#pragma clang diagnostic pop
