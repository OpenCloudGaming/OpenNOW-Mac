#import "OPNCoreAnimationCoordinator.h"

#import <CoreImage/CoreImage.h>
#import <MetalKit/MetalKit.h>

static CASpringAnimation *OPNSpringAnimation(NSString *keyPath,
                                             id fromValue,
                                             id toValue,
                                             CGFloat mass,
                                             CGFloat stiffness,
                                             CGFloat damping,
                                             CGFloat velocity) {
    CASpringAnimation *animation = [CASpringAnimation animationWithKeyPath:keyPath];
    animation.fromValue = fromValue;
    animation.toValue = toValue;
    animation.mass = mass;
    animation.stiffness = stiffness;
    animation.damping = damping;
    animation.initialVelocity = velocity;
    animation.duration = MIN(0.82, animation.settlingDuration);
    animation.removedOnCompletion = YES;
    return animation;
}

static NSValue *OPNCurrentTransformValue(CALayer *layer) {
    CALayer *presentationLayer = layer.presentationLayer;
    return [NSValue valueWithCATransform3D:(presentationLayer ? presentationLayer.transform : layer.transform)];
}

@implementation OPNCoreAnimationCoordinator

+ (instancetype)sharedCoordinator {
    static OPNCoreAnimationCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [[OPNCoreAnimationCoordinator alloc] init];
    });
    return coordinator;
}

+ (CAMediaTimingFunction *)appleQuinticTimingFunction {
    return [CAMediaTimingFunction functionWithControlPoints:0.22 :1.0 :0.36 :1.0];
}

- (void)animateFocusForCardLayer:(CALayer *)cardLayer
                       glowLayer:(CALayer *)glowLayer
                         focused:(BOOL)focused
                      prominence:(CGFloat)prominence
                      accentColor:(NSColor *)accentColor {
    if (!cardLayer) return;

    NSColor *resolvedAccent = accentColor ?: NSColor.whiteColor;
    CGFloat focusAmount = focused ? 1.0 : MAX(0.0, MIN(1.0, prominence));
    CGFloat scale = 1.0 + 0.075 * focusAmount;

    CATransform3D targetTransform = CATransform3DIdentity;
    targetTransform.m34 = -1.0 / 760.0;
    targetTransform = CATransform3DTranslate(targetTransform, 0.0, -10.0 * focusAmount, 42.0 * focusAmount);
    targetTransform = CATransform3DScale(targetTransform, scale, scale, 1.0);
    targetTransform = CATransform3DRotate(targetTransform, -0.030 * focusAmount, 1.0, 0.0, 0.0);
    NSValue *currentTransform = OPNCurrentTransformValue(cardLayer);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    cardLayer.transform = targetTransform;
    cardLayer.zPosition = 100.0 * focusAmount;
    cardLayer.shadowColor = resolvedAccent.CGColor;
    cardLayer.shadowOpacity = 0.24 + 0.34 * focusAmount;
    cardLayer.shadowRadius = 18.0 + 34.0 * focusAmount;
    cardLayer.shadowOffset = CGSizeMake(0.0, 12.0 + 16.0 * focusAmount);

    CASpringAnimation *transformSpring = OPNSpringAnimation(@"transform",
                                                            currentTransform,
                                                            [NSValue valueWithCATransform3D:targetTransform],
                                                            0.78,
                                                            560.0,
                                                            40.0,
                                                            0.0);
    [cardLayer addAnimation:transformSpring forKey:@"opn.focus.transform"];

    if (glowLayer) {
        CALayer *presentationGlow = glowLayer.presentationLayer;
        CGFloat targetOpacity = focused ? 0.74 : 0.0;
        NSNumber *fromOpacity = @((presentationGlow ? presentationGlow.opacity : glowLayer.opacity));
        glowLayer.backgroundColor = resolvedAccent.CGColor;
        glowLayer.opacity = targetOpacity;
        glowLayer.shadowColor = resolvedAccent.CGColor;
        glowLayer.shadowOpacity = targetOpacity;
        glowLayer.shadowRadius = 24.0 + 18.0 * focusAmount;

        CASpringAnimation *opacitySpring = OPNSpringAnimation(@"opacity",
                                                              fromOpacity,
                                                              @(targetOpacity),
                                                              0.70,
                                                              500.0,
                                                              38.0,
                                                              0.0);
        [glowLayer addAnimation:opacitySpring forKey:@"opn.focus.glow"];
    }

    [CATransaction commit];
}

- (void)animateCardLayer:(CALayer *)cardLayer
       metadataContainer:(NSView *)metadataContainer
         backgroundLayer:(CALayer *)backgroundLayer
                expanded:(BOOL)expanded
             accentColor:(NSColor *)accentColor {
    if (!cardLayer || !metadataContainer.layer || !backgroundLayer) return;

    NSColor *resolvedAccent = accentColor ?: NSColor.whiteColor;
    CGFloat scale = expanded ? 1.18 : 1.0;
    CGFloat blurRadius = expanded ? 22.0 : 0.0;
    CGFloat metadataOpacity = expanded ? 0.28 : 1.0;

    CATransform3D targetTransform = CATransform3DIdentity;
    targetTransform.m34 = -1.0 / 900.0;
    targetTransform = CATransform3DTranslate(targetTransform, 0.0, expanded ? -18.0 : 0.0, expanded ? 80.0 : 0.0);
    targetTransform = CATransform3DScale(targetTransform, scale, scale, 1.0);
    NSValue *currentTransform = OPNCurrentTransformValue(cardLayer);

    CIFilter *blurFilter = [CIFilter filterWithName:@"CIGaussianBlur"];
    if (!blurFilter) return;
    blurFilter.name = @"opnMetadataBlur";
    [blurFilter setDefaults];
    [blurFilter setValue:@(blurRadius) forKey:kCIInputRadiusKey];

    [CATransaction begin];
    [CATransaction setAnimationDuration:0.42];
    [CATransaction setAnimationTimingFunction:[OPNCoreAnimationCoordinator appleQuinticTimingFunction]];

    cardLayer.transform = targetTransform;
    cardLayer.shadowColor = resolvedAccent.CGColor;
    cardLayer.shadowOpacity = expanded ? 0.62 : 0.34;
    cardLayer.shadowRadius = expanded ? 64.0 : 22.0;
    cardLayer.shadowOffset = CGSizeMake(0.0, expanded ? 34.0 : 14.0);
    metadataContainer.layer.opacity = metadataOpacity;
    backgroundLayer.filters = @[blurFilter];

    CABasicAnimation *blurAnimation = [CABasicAnimation animationWithKeyPath:@"filters.opnMetadataBlur.inputRadius"];
    blurAnimation.fromValue = @(!expanded ? 22.0 : 0.0);
    blurAnimation.toValue = @(blurRadius);
    blurAnimation.duration = 0.42;
    blurAnimation.timingFunction = [OPNCoreAnimationCoordinator appleQuinticTimingFunction];
    [backgroundLayer addAnimation:blurAnimation forKey:@"opn.metadata.blur"];

    CASpringAnimation *transformSpring = OPNSpringAnimation(@"transform",
                                                            currentTransform,
                                                            [NSValue valueWithCATransform3D:targetTransform],
                                                            0.85,
                                                            360.0,
                                                            34.0,
                                                            0.0);
    [cardLayer addAnimation:transformSpring forKey:@"opn.expand.transform"];

    [CATransaction commit];
}

- (void)springScrollClipView:(NSClipView *)clipView
                         toX:(CGFloat)targetX
                    velocity:(CGFloat)velocity {
    if (!clipView) return;

    clipView.wantsLayer = YES;
    NSRect currentBounds = clipView.bounds;
    CGFloat currentX = currentBounds.origin.x;
    CGFloat distance = targetX - currentX;
    CGFloat normalizedVelocity = fabs(distance) > 1.0 ? velocity / distance : 0.0;
    NSRect targetBounds = currentBounds;
    targetBounds.origin.x = targetX;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    clipView.bounds = targetBounds;

    CASpringAnimation *spring = OPNSpringAnimation(@"bounds.origin.x",
                                                   @(currentX),
                                                   @(targetX),
                                                   1.0,
                                                   220.0,
                                                   29.0,
                                                   normalizedVelocity);
    [clipView.layer addAnimation:spring forKey:@"opn.carousel.snap"];
    [CATransaction commit];

    [clipView scrollToPoint:NSMakePoint(targetX, currentBounds.origin.y)];
    [clipView.enclosingScrollView reflectScrolledClipView:clipView];
}

- (void)configureMetalViewForProMotion:(MTKView *)metalView {
    if (!metalView) return;

    NSInteger maximumFramesPerSecond = metalView.window.screen.maximumFramesPerSecond;
    if (maximumFramesPerSecond <= 0) maximumFramesPerSecond = 60;
    metalView.preferredFramesPerSecond = MIN(120, maximumFramesPerSecond);
    metalView.enableSetNeedsDisplay = NO;
    metalView.paused = NO;
    metalView.framebufferOnly = YES;
}

@end
