//  The interface-scale density correction.
//
//  `scaleEffect` alone rasterises text at display density and upscales the bitmap, so a magnified
//  subtree needs every non-Metal layer's `contentsScale` re-pinned at zoom density. The correction
//  is a settling walk, not a permanent observer: it follows a scale change and each window redraw,
//  then retires once the tree holds still, so an idle window pays for nothing.
//

import AppKit
import Darwin
import Foundation
import ObjectiveC
import QuartzCore
import SwiftUI

/// Says whether anything on screen is currently magnified by `opnInterfaceScale`. Correcting layer
/// density rasterises the whole window, so it only pays for itself while a magnified subtree exists.
@MainActor
private final class OPNMagnifiedSurfaceRegistry {
    static let shared = OPNMagnifiedSurfaceRegistry()

    private let surfaces = NSHashTable<NSView>.weakObjects()
    private var changeHandlers: [ObjectIdentifier: () -> Void] = [:]

    var isAnySurfaceMagnified: Bool {
        surfaces.allObjects.contains { $0.window != nil }
    }

    /// Also the detach path: a marker that left the window is still registered but no longer counts,
    /// so re-announcing it on every window change is what retires the correction.
    func announceSurface(_ surface: NSView) {
        surfaces.add(surface)
        notifyChange()
    }

    func removeSurface(_ surface: NSView) {
        surfaces.remove(surface)
        notifyChange()
    }

    func setChangeHandler(for owner: NSView, handler: @escaping () -> Void) {
        changeHandlers[ObjectIdentifier(owner)] = handler
    }

    func removeChangeHandler(for owner: NSView) {
        changeHandlers.removeValue(forKey: ObjectIdentifier(owner))
    }

    private func notifyChange() {
        for handler in changeHandlers.values {
            handler()
        }
    }
}

struct OPNMagnifiedSurfaceMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> OPNMagnifiedSurfaceMarkerView {
        OPNMagnifiedSurfaceMarkerView(frame: .zero)
    }

    func updateNSView(_ nsView: OPNMagnifiedSurfaceMarkerView, context: Context) {}

    static func dismantleNSView(_ nsView: OPNMagnifiedSurfaceMarkerView, coordinator: ()) {
        OPNMagnifiedSurfaceRegistry.shared.removeSurface(nsView)
    }
}

final class OPNMagnifiedSurfaceMarkerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        OPNMagnifiedSurfaceRegistry.shared.announceSurface(self)
    }

    /// Presence is all it is for; it must never take a mouse event. It mounts as a full-size
    /// background of every magnified subtree, and one of those is the stream's overlay layer,
    /// which sits above the video surface: hit-testable, it swallowed every mouse-down and scroll
    /// the stream needed. Movement survived on the surface's tracking area and keys on the
    /// responder chain, so the whole thing read as "clicks stopped working in the stream".
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Mount anywhere: it corrects `contentsScale` across the whole window, and stays idle until an
/// `opnInterfaceScale` subtree is on screen, because unmagnified content is already at the right density.
struct OPNInterfaceScaleDensityBooster: NSViewRepresentable {
    let scale: CGFloat

    func makeNSView(context: Context) -> OPNInterfaceScaleDensityView {
        OPNInterfaceScaleDensityView(scale: scale)
    }

    func updateNSView(_ nsView: OPNInterfaceScaleDensityView, context: Context) {
        nsView.scale = scale
    }

    static func dismantleNSView(_ nsView: OPNInterfaceScaleDensityView, coordinator: ()) {
        nsView.restoreNaturalDensity()
        nsView.invalidate()
    }
}

/// Decides when the density correction walks the window and when it retires. A type of its own
/// because this schedule is what used to run for the life of the window: every pass it returns a
/// delay, and `nil` is the signal that the tree has held still and the correction is done.
struct OPNDensitySettleSchedule {
    /// How often the tree is corrected while it is still changing.
    static let activeInterval: CFTimeInterval = 0.1
    /// How long the tree has to hold still before the correction retires.
    static let settledInterval: CFTimeInterval = 0.8

    private(set) var interval: CFTimeInterval = OPNDensitySettleSchedule.activeInterval
    private var lastChangeTime: CFAbsoluteTime

    init(now: CFAbsoluteTime) {
        lastChangeTime = now
    }

    /// Records a pass and returns the delay before the next one, or `nil` when the tree has held
    /// still for `settledInterval`.
    mutating func nextDelay(now: CFAbsoluteTime, didChange: Bool) -> CFTimeInterval? {
        if didChange {
            interval = Self.activeInterval
            lastChangeTime = now
        } else {
            interval = min(interval * 2, Self.settledInterval)
        }
        guard now - lastChangeTime >= Self.settledInterval, interval >= Self.settledInterval else {
            return interval
        }
        return nil
    }

    /// A window redraw or a newly magnified subtree: the tree may have changed, so the correction
    /// stays alive for another `settledInterval`.
    mutating func signal(now: CFAbsoluteTime) {
        lastChangeTime = now
    }
}

final class OPNInterfaceScaleDensityView: NSView {
    var scale: CGFloat {
        didSet { reconfigure() }
    }

    /// Whether a correction pass is currently scheduled. False means the tree is left alone.
    var isCorrecting: Bool { settle != nil }

    nonisolated(unsafe) private var settleTimer: Timer?
    private var windowUpdateObserver: OPNWindowUpdateObserver?
    private var settle: OPNDensitySettleSchedule?

    init(scale: CGFloat) {
        self.scale = scale
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        OPNMagnifiedSurfaceRegistry.shared.setChangeHandler(for: self) { [weak self] in
            self?.magnifiedSurfacesDidChange()
        }
        observeWindowUpdates()
        reconfigure()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reconfigure()
    }

    func restoreNaturalDensity() {
        applyDensity(targetScale: window?.backingScaleFactor ?? 1)
    }

    func invalidate() {
        OPNMagnifiedSurfaceRegistry.shared.removeChangeHandler(for: self)
        stopSettling()
        windowUpdateObserver = nil
    }

    /// A scale, window or backing change rebuilds the magnified subtree at the new density, so the
    /// correction has to run again until the tree holds still.
    private func reconfigure() {
        stopSettling()
        guard window != nil else { return }
        // Only magnified content is rasterised at the wrong density. Walking the window for the
        // catalog, settings or recordings re-renders correct layers at 2.1x the pixels for nothing.
        guard scale != 1, OPNMagnifiedSurfaceRegistry.shared.isAnySurfaceMagnified else {
            restoreNaturalDensity()
            return
        }
        beginSettling()
    }

    /// A magnified subtree mounted or unmounted. The correction also retires itself the first time
    /// a pass finds nothing magnified left, because a subtree can be torn down whole without its
    /// marker being dismantled.
    private func magnifiedSurfacesDidChange() {
        guard window != nil else { return }
        guard scale != 1, OPNMagnifiedSurfaceRegistry.shared.isAnySurfaceMagnified else {
            stopSettling()
            restoreNaturalDensity()
            return
        }
        beginSettling()
    }

    /// AppKit posts this only when the window actually redrew, which is when SwiftUI may have put a
    /// fresh `CGDrawingLayer` into a magnified subtree. The stream video never posts it: frames
    /// reach the display through `CAMetalLayer`, not through the AppKit update cycle.
    private func windowDidUpdate() {
        guard window != nil, scale != 1,
              OPNMagnifiedSurfaceRegistry.shared.isAnySurfaceMagnified else { return }
        guard settle != nil else {
            beginSettling()
            return
        }
        // A pass is already in flight and will pick the redraw up, so it only pushes out the point
        // at which the correction retires.
        settle?.signal(now: CFAbsoluteTimeGetCurrent())
    }

    private func observeWindowUpdates() {
        windowUpdateObserver = nil
        guard let window else { return }
        windowUpdateObserver = OPNWindowUpdateObserver(window: window) { [weak self] in
            self?.windowDidUpdate()
        }
    }

    /// Corrects the tree now, then keeps correcting it until it has gone unchanged for
    /// `settledInterval`, and stops there. Nothing is left registered while the tree is settled, so
    /// an idle window costs neither a run-loop pass nor a layer walk.
    private func beginSettling() {
        settle = OPNDensitySettleSchedule(now: CFAbsoluteTimeGetCurrent())
        // A live resize rebuilds the tree faster than a walk can follow it, and walking it there is
        // the cost this correction exists to avoid. The tick picks the correction up when it ends.
        if window?.inLiveResize != true {
            applyDensity(targetScale: effectiveTargetScale())
        }
        scheduleNextWalk()
    }

    private func scheduleNextWalk() {
        guard let settle else { return }
        settleTimer?.invalidate()
        let timer = Timer(timeInterval: settle.interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleTick() }
        }
        // Leeway, so the system can coalesce the wake with whatever else the run loop is doing.
        timer.tolerance = OPNDensitySettleSchedule.activeInterval
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    private func settleTick() {
        settleTimer = nil
        guard let window else {
            stopSettling()
            return
        }
        guard !window.inLiveResize else {
            settle?.signal(now: CFAbsoluteTimeGetCurrent())
            scheduleNextWalk()
            return
        }
        guard scale != 1, OPNMagnifiedSurfaceRegistry.shared.isAnySurfaceMagnified else {
            stopSettling()
            restoreNaturalDensity()
            return
        }
        guard var schedule = settle else { return }
        let nextDelay = schedule.nextDelay(
            now: CFAbsoluteTimeGetCurrent(),
            didChange: applyDensity(targetScale: effectiveTargetScale())
        )
        settle = schedule
        guard nextDelay != nil else {
            stopSettling()
            return
        }
        scheduleNextWalk()
    }

    private func stopSettling() {
        settleTimer?.invalidate()
        settleTimer = nil
        settle = nil
    }

    private func effectiveTargetScale() -> CGFloat {
        scale * (window?.backingScaleFactor ?? 1)
    }

    @discardableResult
    func applyDensity(targetScale: CGFloat) -> Bool {
        guard let root = window?.contentView?.layer else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let didChange = forceContentsScale(root, targetScale: targetScale)
        CATransaction.commit()
        return didChange
    }

    /// Resolved on the first walk, not at launch: a `static let` is initialised on first access,
    /// and the only access is `isDrawingLayer`, which only the walk calls.
    private static let drawingLayerClasses: [AnyClass] = resolveDrawingLayerClasses()

    private static func resolveDrawingLayerClasses() -> [AnyClass] {
        var classes: [AnyClass] = []
        let imageCount = _dyld_image_count()
        for index in 0..<imageCount {
            guard let imageName = _dyld_get_image_name(index) else { continue }
            if strstr(imageName, "SwiftUI") == nil { continue }
            var count: UInt32 = 0
            guard let classNames = objc_copyClassNamesForImage(imageName, &count) else { continue }
            defer { free(UnsafeMutableRawPointer(mutating: classNames)) }
            for classIndex in 0..<Int(count) {
                let className = classNames[classIndex]
                if strstr(className, "CGDrawingLayer") != nil, let resolvedClass = objc_getClass(className) as? AnyClass {
                    classes.append(resolvedClass)
                }
            }
        }
        return classes
    }

    static func isDrawingLayer(_ layer: CALayer) -> Bool {
        guard let layerClass = object_getClass(layer) else { return false }
        if drawingLayerClasses.contains(where: { $0 === layerClass }) {
            return true
        }
        return strstr(object_getClassName(layer), "CGDrawingLayer") != nil
    }

    @discardableResult
    private func forceContentsScale(_ layer: CALayer, targetScale: CGFloat) -> Bool {
        if layer is CAMetalLayer { return false }
        var didChange = false
        if Self.isDrawingLayer(layer), abs(layer.contentsScale - targetScale) > 0.0001 {
            layer.contentsScale = targetScale
            layer.setNeedsDisplay()
            markOwningHostingViewDirty(layer)
            didChange = true
        }
        guard let sublayers = layer.sublayers else { return didChange }
        for sublayer in sublayers where forceContentsScale(sublayer, targetScale: targetScale) {
            didChange = true
        }
        return didChange
    }

    private func markOwningHostingViewDirty(_ layer: CALayer) {
        var current: CALayer? = layer
        while let candidate = current {
            if let view = candidate.delegate as? NSView {
                if strstr(object_getClassName(view), "NSHostingView") != nil {
                    view.needsDisplay = true
                }
                return
            }
            current = candidate.superlayer
        }
    }

    deinit {
        settleTimer?.invalidate()
    }
}
