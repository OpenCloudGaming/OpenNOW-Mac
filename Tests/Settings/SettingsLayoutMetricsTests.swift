import Foundation
import Testing
@testable import OpenNOW

/// The row-width formula and the stack gate it feeds. The formula is a pure function of
/// `(cardWidth, uiScale)`, so the bands, the bounds and the monotonicity can all be asserted
/// directly, without a window.
@Suite("SettingsLayoutMetrics")
struct SettingsLayoutMetricsTests {
    private static let scales: [CGFloat] = [0.75, 1.0, 2.0]
    private static let widths: [CGFloat] = [80, 150, 200, 320, 480, 508, 600, 718, 900, 1200, 3840]

    /// The gate is not a second constant that can drift away from the widths: it is the label floor
    /// plus the control reserve, and the two-column minimum is two of those plus the gutter.
    @Test func theGateIsDerivedFromTheSameConstantsAsTheWidths() {
        #expect(
            SettingsLayoutMetrics.narrowRowWidth
                == SettingsLayoutMetrics.labelFloor + SettingsLayoutMetrics.rowGap + SettingsLayoutMetrics.chipReserve
        )
        #expect(
            SettingsLayoutMetrics.twoColumnMinimumWidth
                == SettingsLayoutMetrics.narrowRowWidth * 2 + SettingsLayoutMetrics.columnGutter
        )
    }

    /// Stacked exactly when the card is narrower than the derived gate, and only then - so a row
    /// and the masonry split can never disagree about which band they are in.
    @Test func stackedExactlyBelowTheDerivedGate() {
        for scale in Self.scales {
            for card in Self.widths {
                let stacked = SettingsLayoutMetrics.usesNarrowRows(cardWidth: card, uiScale: scale)
                #expect(
                    stacked == (card < SettingsLayoutMetrics.narrowRowWidth * scale),
                    "card \(card) at uiScale \(scale) read as stacked=\(stacked)"
                )
            }
        }
    }

    /// Side by side, the label is never below its floor nor above its readable cap, and the control
    /// always keeps its whole reserve. Scaled, because the constants are logical points.
    @Test func sideBySideWidthsStayInsideTheirBounds() {
        for scale in Self.scales {
            for card in Self.widths where !SettingsLayoutMetrics.usesNarrowRows(cardWidth: card, uiScale: scale) {
                let label = SettingsLayoutMetrics.labelColumnWidth(cardWidth: card, uiScale: scale)
                let control = SettingsLayoutMetrics.controlColumnWidth(cardWidth: card, uiScale: scale)
                #expect(label >= SettingsLayoutMetrics.labelFloor * scale, "card \(card) scale \(scale)")
                #expect(label <= SettingsLayoutMetrics.labelMeasure * scale, "card \(card) scale \(scale)")
                #expect(control >= SettingsLayoutMetrics.chipReserve * scale, "card \(card) scale \(scale)")
            }
        }
    }

    /// Neither column ever loses ground as the card grows: each added point goes to the text until
    /// the cap, then to the control.
    @Test func bothWidthsAreNonDecreasingInCardWidth() {
        for scale in Self.scales {
            var previousLabel: CGFloat = 0
            var previousControl: CGFloat = 0
            for card in Self.widths {
                let label = SettingsLayoutMetrics.labelColumnWidth(cardWidth: card, uiScale: scale)
                let control = SettingsLayoutMetrics.controlColumnWidth(cardWidth: card, uiScale: scale)
                #expect(label >= previousLabel, "label shrank at card \(card) scale \(scale)")
                #expect(control >= previousControl, "control shrank at card \(card) scale \(scale)")
                previousLabel = label
                previousControl = control
            }
        }
    }

    /// The formula is scale-free by construction: the same physical card at a different interface
    /// scale is the same layout, just larger.
    @Test func theFormulaIsScaleFree() {
        for scale in Self.scales {
            for card in Self.widths {
                let scaled = SettingsLayoutMetrics.labelColumnWidth(cardWidth: card * scale, uiScale: scale)
                let unscaled = SettingsLayoutMetrics.labelColumnWidth(cardWidth: card, uiScale: 1.0) * scale
                #expect(abs(scaled - unscaled) < 0.0001, "card \(card) scale \(scale)")
            }
        }
    }

    /// No per-row input, no state: equal inputs give equal outputs on every call.
    @Test func theFormulaIsPure() {
        for scale in Self.scales {
            for card in Self.widths {
                #expect(
                    SettingsLayoutMetrics.labelColumnWidth(cardWidth: card, uiScale: scale)
                        == SettingsLayoutMetrics.labelColumnWidth(cardWidth: card, uiScale: scale)
                )
            }
        }
    }
}