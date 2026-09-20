import AppKit

/// The Dock tile's content view while a wait is in progress: the app's own icon, with a progress bar
/// laid across its lower edge.
///
/// `NSDockTile` has no progress API. Drawing one means becoming the tile's `contentView`, and a
/// content view *replaces* the icon rather than sitting over it — which is why the icon is drawn
/// back in here, and why this view owns the whole tile for as long as it is installed. The geometry
/// follows the system's own download progress: a rounded track, inset from the icon's edges and a
/// little way above the bottom, filled from the leading edge.
final class OPNDockTileProgressView: NSView {
    /// 0…1. Values arrive quantized to whole percent from `OPNDockTileContent.progressFraction`, so
    /// this view draws what it is given, and a value that would not change the picture does not
    /// redraw it.
    var fraction: Double = 0 {
        didSet {
            guard fraction != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Fractions of the tile, from the app icon's own proportions rather than from a pixel size: the
    /// Dock draws the tile at whatever size the display and the user's Dock settings ask for.
    private static let trackInsetFraction = 0.0625
    private static let trackHeightFraction = 0.078
    private static let trackBottomFraction = 0.156
    /// The hairline between the track and the well inside it.
    private static let outlineWidth: CGFloat = 0.5

    /// The bar's frame inside a tile of `bounds`. Pure geometry, kept out of `draw` so the track and
    /// the fill cannot disagree about where the bar is.
    static func trackRect(in bounds: NSRect) -> NSRect {
        let inset = bounds.width * trackInsetFraction
        return NSRect(
            x: bounds.minX + inset,
            y: bounds.minY + bounds.height * trackBottomFraction,
            width: max(0, bounds.width - inset * 2),
            height: bounds.height * trackHeightFraction
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        NSApp?.applicationIconImage?.draw(in: bounds)

        // The app icon as the palette that accent was chosen against: the bar is the app's colour on
        // the app's own icon, before the theme's light or dark page comes into it.
        let accent = OPNThemePreferences.accentColor.components
        let fill = NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)

        let track = Self.trackRect(in: bounds)
        let radius = track.height / 2
        guard track.width > Self.outlineWidth * 2, radius > Self.outlineWidth else { return }

        NSColor.white.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let well = track.insetBy(dx: Self.outlineWidth, dy: Self.outlineWidth)
        let wellRadius = radius - Self.outlineWidth
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: well, xRadius: wellRadius, yRadius: wellRadius).fill()

        // A wait that has not moved yet draws the empty well rather than a sliver of colour: the bar
        // is a readout, and an empty bar is a truthful one.
        guard fraction > 0 else { return }
        let filled = NSRect(x: well.minX, y: well.minY, width: well.width * min(1, fraction), height: well.height)
        guard filled.width > 0 else { return }
        fill.setFill()
        NSBezierPath(roundedRect: filled, xRadius: wellRadius, yRadius: wellRadius).fill()
    }
}
