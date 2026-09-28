import AppKit

/// The Dock tile's content view while a wait is in progress or a session is running: the app's own
/// icon, with a progress bar across its lower edge and a live badge in the corner.
///
/// `NSDockTile` has no progress API. Drawing one means becoming the tile's `contentView`, and a
/// content view *replaces* the icon rather than sitting over it — which is why the icon is drawn
/// back in here, and why this view owns the whole tile for as long as it is installed. The geometry
/// follows the system's own download progress: a rounded track, inset from the icon's edges and a
/// little way above the bottom, filled from the leading edge.
///
/// A `determinate` bar fills a measured fraction. An `indeterminate` one — a stream that has been
/// allocated but has not yet produced a frame — draws a segment sweeping back and forth, because
/// there is no fraction to report and an empty bar would look like a wait that had stalled.
///
/// A running stream reports no fraction at all, so the bar is absent while it streams. That state is
/// carried by the live badge instead: a glyph over the icon saying a game is underway here. The
/// artwork itself is left alone — a recoloured icon reads as a theme, not as a state, which is not
/// what a Dock tile should be saying.
final class OPNDockTileProgressView: NSView {
    /// The bar's state. Setting the same value does not repaint. `determinate` values arrive
    /// quantized to whole percent from `OPNDockTileContent.progress`, so a value that would not
    /// change the picture does not redraw it either. Nil means no bar is drawn — the tile can show
    /// the live badge without one.
    var progress: OPNDockProgress? = .determinate(0) {
        didSet {
            guard progress != oldValue else { return }
            syncAnimation()
            needsDisplay = true
        }
    }

    /// Whether a stream is active, so the tile draws the live badge over the icon.
    var isStreaming: Bool = false {
        didSet { needsDisplay = true }
    }

    /// Advances the sweep while indeterminate. Owned here and invalidated the moment the bar stops
    /// being indeterminate or the view is released. `nonisolated(unsafe)` for the same reason as
    /// `SteamControllerHIDMonitor.heartbeatTimer`: `deinit` is nonisolated, and the timer is only
    /// ever assigned on the main actor.
    private nonisolated(unsafe) var animationTimer: Timer?
    /// In cycles, one full back-and-forth per unit. Only read while indeterminate.
    private var sweepPhase: Double = 0

    private static let sweepInterval: TimeInterval = 1.0 / 30.0
    /// Back-and-forth cycles per second: fast enough to read as motion, slow enough not to strobe.
    private static let sweepCyclesPerSecond: Double = 0.75
    /// How much of the well the moving segment fills.
    private static let sweepSegmentFraction = 0.38

    /// Fractions of the tile, from the app icon's own proportions rather than from a pixel size: the
    /// Dock draws the tile at whatever size the display and the user's Dock settings ask for.
    private static let trackInsetFraction = 0.0625
    private static let trackHeightFraction = 0.078
    private static let trackBottomFraction = 0.156
    /// The hairline between the track and the well inside it.
    private static let outlineWidth: CGFloat = 0.5

    /// The live badge's geometry, as fractions of the tile for the same reason. It sits in the top
    /// trailing corner, clear of the progress bar along the bottom and of the icon's artwork in the
    /// middle.
    private static let liveBadgeSizeFraction = 0.32
    private static let liveBadgeInsetFraction = 0.06
    /// How much of the badge's circle the glyph inside it may fill, so the glyph never touches the
    /// circle's edge whatever its aspect ratio.
    private static let liveBadgeGlyphFraction = 0.58

    /// The badge's glyph. `gamecontroller.fill` rather than a plain "live" dot: the state worth
    /// naming on this tile is that a *game* is running, which a dot cannot say. Swapping the badge is
    /// this one constant — the badge is drawn at whatever aspect the symbol has.
    static let liveBadgeSymbolName = "gamecontroller.fill"

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

    /// The live badge's circle inside a tile of `bounds`, laid out in the top trailing corner. Pure,
    /// so the placement can be asserted without a dock.
    static func liveBadgeRect(in bounds: NSRect) -> NSRect {
        let side = bounds.width * liveBadgeSizeFraction
        let inset = bounds.width * liveBadgeInsetFraction
        return NSRect(
            x: bounds.maxX - inset - side,
            y: bounds.maxY - inset - side,
            width: side,
            height: side
        )
    }

    /// Where the indeterminate segment sits in the well, as a 0…1 leading offset that can be scaled
    /// by the well's travel. Pure, so the sweep can be tested without a dock or a clock. Reduce
    /// Motion parks it centered rather than animating it.
    static func indeterminatePosition(phase: Double, isReduceMotionEnabled: Bool) -> Double {
        guard !isReduceMotionEnabled else { return 0.5 }
        let cycle = phase.truncatingRemainder(dividingBy: 2)
        let mirrored = cycle <= 1 ? cycle : 2 - cycle
        return min(1, max(0, mirrored))
    }

    deinit {
        animationTimer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        NSApp?.applicationIconImage?.draw(in: bounds)

        // The app icon as the palette that accent was chosen against: the bar is the app's colour on
        // the app's own icon, before the theme's light or dark page comes into it.
        let accent = OPNThemePreferences.accentColor.components
        let fill = NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)

        if isStreaming {
            drawLiveBadge()
        }

        if let progress {
            drawProgressBar(progress, fill: fill)
        }
    }

    /// The live badge: a white disc in the top trailing corner with the glyph cut out of it dark. A
    /// solid disc rather than a bare glyph, because the glyph alone would read as part of the artwork
    /// it is sitting on; the disc is what says "this is a status, not a drawing", and it carries the
    /// glyph legibly whatever the icon beneath it happens to be.
    private func drawLiveBadge() {
        let rect = Self.liveBadgeRect(in: bounds)
        guard rect.width > 0, rect.height > 0 else { return }

        NSColor.white.setFill()
        NSBezierPath(ovalIn: rect).fill()

        guard let glyph = Self.liveBadgeGlyph(for: rect) else { return }
        let origin = NSPoint(
            x: rect.midX - glyph.size.width / 2,
            y: rect.midY - glyph.size.height / 2
        )
        glyph.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// The badge's glyph, tinted to read against the white disc and scaled to fit inside it at
    /// whatever aspect the symbol has — a wide symbol is bounded by the disc's width, a tall one by
    /// its height. Nil when the symbol is unavailable, which leaves the disc alone rather than
    /// drawing nothing at all.
    private static func liveBadgeGlyph(for rect: NSRect) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .bold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .black))
        guard let glyph = NSImage(
            systemSymbolName: liveBadgeSymbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration) else { return nil }

        let limit = rect.width * liveBadgeGlyphFraction
        guard glyph.size.width > 0, glyph.size.height > 0 else { return nil }
        let scale = min(limit / glyph.size.width, limit / glyph.size.height)
        let target = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)

        let scaled = NSImage(size: target, flipped: false) { drawRect in
            glyph.draw(in: drawRect)
            return true
        }
        return scaled
    }

    /// The progress bar: a rounded track with a fill that sweeps or fills, drawn across the tile's
    /// lower edge. Extracted from `draw(_:)` so the live badge can be drawn independently of whether
    /// a bar is also showing.
    private func drawProgressBar(_ progress: OPNDockProgress, fill: NSColor) {
        let track = Self.trackRect(in: bounds)
        let radius = track.height / 2
        guard track.width > Self.outlineWidth * 2, radius > Self.outlineWidth else { return }

        NSColor.white.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let well = track.insetBy(dx: Self.outlineWidth, dy: Self.outlineWidth)
        let wellRadius = radius - Self.outlineWidth
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: well, xRadius: wellRadius, yRadius: wellRadius).fill()
        guard well.width > 0, well.height > 0 else { return }

        switch progress {
        case let .determinate(fraction):
            drawDeterminate(fraction, in: well, radius: wellRadius, color: fill)
        case .indeterminate:
            drawIndeterminate(in: well, radius: wellRadius, color: fill)
        }
    }

    /// A wait that has not moved yet draws the empty well rather than a sliver of colour: the bar is
    /// a readout, and an empty bar is a truthful one.
    private func drawDeterminate(_ fraction: Double, in well: NSRect, radius: CGFloat, color: NSColor) {
        guard fraction > 0 else { return }
        let filled = NSRect(x: well.minX, y: well.minY, width: well.width * min(1, fraction), height: well.height)
        guard filled.width > 0 else { return }
        color.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }

    private func drawIndeterminate(in well: NSRect, radius: CGFloat, color: NSColor) {
        let segmentWidth = well.width * Self.sweepSegmentFraction
        guard segmentWidth > radius * 2 else { return }
        let travel = well.width - segmentWidth
        let position = Self.indeterminatePosition(
            phase: sweepPhase,
            isReduceMotionEnabled: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        let segment = NSRect(x: well.minX + travel * position, y: well.minY, width: segmentWidth, height: well.height)
        color.setFill()
        NSBezierPath(roundedRect: segment, xRadius: radius, yRadius: radius).fill()
    }

    private func syncAnimation() {
        guard case .some(.indeterminate) = progress, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            animationTimer?.invalidate()
            animationTimer = nil
            return
        }
        guard animationTimer == nil else { return }
        sweepPhase = 0
        let timer = Timer(timeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sweepPhase += Self.sweepInterval * Self.sweepCyclesPerSecond
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }
}
