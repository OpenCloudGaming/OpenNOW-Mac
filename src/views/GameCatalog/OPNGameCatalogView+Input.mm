#import "OPNGameCatalogPrivate.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation OPNGameCatalogView (Input)

using namespace OPN;

- (void)refreshLibrarySelections {
    for (NSMutableArray<OPNStoreGameTile *> *row in self.rowCards) {
        for (OPNStoreGameTile *card in row) {
            card.selectedVariantIndex = [self selectedVariantIndexForStoreGame:card.game];
        }
    }
    [self updateFocusedTiles];
}

- (void)updateFocusedTiles {
    if (self.rowCards.count == 0) return;
    self.focusedRowIndex = MAX(0, MIN((NSInteger)self.rowCards.count - 1, self.focusedRowIndex));
    NSMutableArray<OPNStoreGameTile *> *focusedRow = self.rowCards[(NSUInteger)self.focusedRowIndex];
    if (focusedRow.count == 0) return;
    self.focusedColumnIndex = MAX(0, MIN((NSInteger)focusedRow.count - 1, self.focusedColumnIndex));
    OPNStoreGameTile *nextFocusedTile = focusedRow[(NSUInteger)self.focusedColumnIndex];
    if (self.focusedTile == nextFocusedTile) {
        [nextFocusedTile setStoreFocused:YES];
        return;
    }
    [self.focusedTile setStoreFocused:NO];
    [nextFocusedTile setStoreFocused:YES];
    self.focusedTile = nextFocusedTile;
}

- (void)scrollFocusedTileIntoView {
    if (self.focusedRowIndex < 0 || self.focusedRowIndex >= (NSInteger)self.rowCards.count) return;
    NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[(NSUInteger)self.focusedRowIndex];
    if (self.focusedColumnIndex < 0 || self.focusedColumnIndex >= (NSInteger)row.count) return;
    OPNStoreGameTile *tile = row[(NSUInteger)self.focusedColumnIndex];
    NSRect tileInDocument = [tile convertRect:tile.bounds toView:self.documentView];
    [self.documentView scrollRectToVisible:NSInsetRect(tileInDocument, -28.0, -46.0)];
    [tile scrollRectToVisible:NSInsetRect(tile.bounds, -24.0, -12.0)];
}

- (void)moveGamepadFocusByRows:(NSInteger)rowDelta columns:(NSInteger)columnDelta {
    if (self.rowCards.count == 0) return;
    NSInteger nextRow = MAX(0, MIN((NSInteger)self.rowCards.count - 1, self.focusedRowIndex + rowDelta));
    NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[(NSUInteger)nextRow];
    if (row.count == 0) return;
    NSInteger nextColumn = self.focusedColumnIndex + columnDelta;
    if (nextRow != self.focusedRowIndex && columnDelta == 0) nextColumn = MIN(nextColumn, (NSInteger)row.count - 1);
    nextColumn = MAX(0, MIN((NSInteger)row.count - 1, nextColumn));
    if (nextRow == self.focusedRowIndex && nextColumn == self.focusedColumnIndex) return;
    self.focusedRowIndex = nextRow;
    self.focusedColumnIndex = nextColumn;
    [self updateFocusedTiles];
    [self scrollFocusedTileIntoView];
}

- (void)moveGamepadFocusBy:(NSInteger)delta {
    [self moveGamepadFocusByRows:0 columns:delta];
}

- (void)activateGamepadFocus {
    if (self.focusedRowIndex < 0 || self.focusedRowIndex >= (NSInteger)self.rowCards.count) return;
    NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[(NSUInteger)self.focusedRowIndex];
    if (self.focusedColumnIndex < 0 || self.focusedColumnIndex >= (NSInteger)row.count) return;
    [row[(NSUInteger)self.focusedColumnIndex] activate];
}

- (void)cycleFocusedGamepadVariant {
    if (self.focusedRowIndex < 0 || self.focusedRowIndex >= (NSInteger)self.rowCards.count) return;
    NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[(NSUInteger)self.focusedRowIndex];
    if (self.focusedColumnIndex < 0 || self.focusedColumnIndex >= (NSInteger)row.count) return;
    [row[(NSUInteger)self.focusedColumnIndex] cycleSelectedVariant];
}

- (void)keyDown:(NSEvent *)event {
    NSString *characters = event.charactersIgnoringModifiers ?: @"";
    unichar key = characters.length > 0 ? [characters characterAtIndex:0] : 0;
    switch (key) {
        case NSLeftArrowFunctionKey:
        case 'a':
        case 'A':
            [self moveGamepadFocusByRows:0 columns:-1];
            return;
        case NSRightArrowFunctionKey:
        case 'd':
        case 'D':
            [self moveGamepadFocusByRows:0 columns:1];
            return;
        case NSUpArrowFunctionKey:
        case 'w':
        case 'W':
            [self moveGamepadFocusByRows:-1 columns:0];
            return;
        case NSDownArrowFunctionKey:
            [self moveGamepadFocusByRows:1 columns:0];
            return;
        case NSTabCharacter:
            [self moveGamepadFocusByRows:0 columns:(event.modifierFlags & NSEventModifierFlagShift) ? -1 : 1];
            return;
        case NSCarriageReturnCharacter:
        case NSEnterCharacter:
        case ' ':
            [self activateGamepadFocus];
            return;
        case 'v':
        case 'V':
            [self cycleFocusedGamepadVariant];
            return;
        default:
            [super keyDown:event];
            return;
    }
}

@end

#pragma clang diagnostic pop
