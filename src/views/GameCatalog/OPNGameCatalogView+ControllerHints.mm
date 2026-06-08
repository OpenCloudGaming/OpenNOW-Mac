#import "OPNGameCatalogPrivate.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation OPNGameCatalogView (ControllerHints)

using namespace OPN;

- (void)removeButtonHintGroups {
    NSArray<NSView *> *arrangedSubviews = self.buttonHintStackView.arrangedSubviews.copy;
    for (NSView *view in arrangedSubviews) {
        [self.buttonHintStackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }
}

- (void)rebuildButtonHintPillForCurrentController {
    if (!self.buttonHintStackView) return;
    OPNStoreControllerFamily family = OPNStoreConnectedControllerFamily();
    if (family == self.buttonHintControllerFamily && self.buttonHintStackView.arrangedSubviews.count > 0) return;
    self.buttonHintControllerFamily = family;
    [self removeButtonHintGroups];

    if (family == OPNStoreControllerFamilyKeyboard) {
        [self.buttonHintStackView addArrangedSubview:OPNStoreHintGroup(@[
            OPNStoreHintKeyView(@"arrow.up", @"Up", 24.0),
            OPNStoreHintKeyView(@"arrow.down", @"Dn", 24.0),
            OPNStoreHintKeyView(@"arrow.left", @"Lt", 24.0),
            OPNStoreHintKeyView(@"arrow.right", @"Rt", 24.0)
        ], @"Move")];
        [self.buttonHintStackView addArrangedSubview:OPNStoreHintGroup(@[
            OPNStoreHintKeyView(@"return", @"Ent", 30.0),
            OPNStoreHintKeyView(@"space", @"Space", 46.0)
        ], @"Select")];
        [self.buttonHintStackView addArrangedSubview:OPNStoreHintGroup(@[
            OPNStoreHintKeyView(@"v.circle", @"V", 26.0)
        ], @"Variant")];
    } else {
        OPNStoreControllerHintStyle style = OPNStoreControllerHintStyleForFamily(family);
        [self.buttonHintStackView addArrangedSubview:OPNStoreHintGroup(@[
            OPNStoreControllerIconKeyView(@"dpad", 28.0),
            OPNStoreControllerIconKeyView(@"stick", 28.0)
        ], @"Move")];
        [self.buttonHintStackView addArrangedSubview:OPNStoreHintGroup(@[
            OPNStoreControllerIconKeyView(style.selectGlyph, 28.0)
        ], @"Select")];
        [self.buttonHintStackView addArrangedSubview:OPNStoreHintGroup(@[
            OPNStoreControllerIconKeyView(style.variantGlyph, 28.0)
        ], @"Variant")];
    }

    [self.buttonHintStackView setNeedsLayout:YES];
    [self updateButtonHintPillFrame];
}

@end

#pragma clang diagnostic pop
