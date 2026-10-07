//  The interface-scale density correction: a settling walk, not a permanent observer, so an idle
//  window pays neither a run-loop pass nor a layer walk.

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

    /// Also the detach path: a marker that left the window is still registered but no longer counts.
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

    /// Presence is all it is for; a hit-testable marker swallowed every mouse-down and scroll the
    /// stream needed, which read as "clicks stopped working in the stream".
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

/// Decides how long the density correction keeps walking. One walk is a whole-window layer pass, so
/// the schedule backs off while passes change nothing and retires once the tree has held still.
struct OPNDensitySettleSchedule {
    /// How often the tree is walked while it is still changing.
    static let activeInterval: CFTimeInterval = 0.1
    /// How long the tree has to hold still before the walk retires.
    static let settledInterval: CFTimeInterval = 0.8

    private(set) var walkInterval: CFTimeInterval = OPNDensitySettleSchedule.activeInterval
    private var lastChangeTime: CFAbsoluteTime

    init(now: CFAbsoluteTime) {
        lastChangeTime = now
    }

    /// Records one walk and returns the delay before the next, or nil once the tree has held still.
    mutating func delayUntilNextWalk(now: CFAbsoluteTime, isChanged: Bool) -> CFTimeInterval? {
        guard isChanged else {
            walkInterval = min(walkInterval * 2, Self.settledInterval)
            return isTreeSettled(now: now) ? nil : walkInterval
        }
        walkInterval = Self.activeInterval
        lastChangeTime = now
        return walkInterval
    }

    /// A window redraw or a newly magnified subtree: the tree may have changed, so keep walking.
    mutating func keepWalking(now: CFAbsoluteTime) {
        lastChangeTime = now
    }

    private func isTreeSettled(now: CFAbsoluteTime) -> Bool {
        now - lastChangeTime >= Self.settledInterval
    }
}

final class OPNInterfaceScaleDensityView: NSView {
    var scale: CGFloat {
        didSet { updateCorrection() }
    }

    /// Whether a correction walk is currently scheduled. False means the tree is left alone.
    var isCorrectingDensity: Bool { settleSchedule != nil }

    nonisolated(unsafe) private var settleTimer: Timer?
    private var settleSchedule: OPNDensitySettleSchedule?
    private var windowUpdateObserver: OPNWindowUpdateObserver?

    init(scale: CGFloat) {
        self.scale = scale
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        OPNMagnifiedSurfaceRegistry.shared.setChangeHandler(for: self) { [weak self] in
            self?.updateCorrection()
        }
        observeWindowUpdates()
        updateCorrection()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateCorrection()
    }

    func restoreNaturalDensity() {
        applyDensity(targetScale: window?.backingScaleFactor ?? 1)
    }

    func invalidate() {
        OPNMagnifiedSurfaceRegistry.shared.removeChangeHandler(for: self)
        stopSettling()
        windowUpdateObserver = nil
    }

    /// A scale, window, backing or magnified-surface change rebuilds the tree at the new density, so
    /// the walk starts again; without one of those, the walk retires and the density goes natural.
    private func updateCorrection() {
        guard isDensityCorrectionNeeded else {
            stopSettling()
            restoreNaturalDensity()
            return
        }
        beginSettling()
    }

    /// AppKit posts a window update only when the window actually redrew, which is when SwiftUI may
    /// have put a fresh `CGDrawingLayer` into a magnified subtree; stream frames never post it.
    private func handleWindowUpdate() {
        guard isDensityCorrectionNeeded else { return }
        guard settleSchedule != nil else {
            beginSettling()
            return
        }
        settleSchedule?.keepWalking(now: CFAbsoluteTimeGetCurrent())
    }

    /// Only magnified content rasterises at the wrong density; walking the window for the catalog,
    /// settings or recordings would re-render correct layers at 2.1x the pixels for nothing.
    private var isDensityCorrectionNeeded: Bool {
        window != nil && scale != 1 && OPNMagnifiedSurfaceRegistry.shared.isAnySurfaceMagnified
    }

    private func observeWindowUpdates() {
        windowUpdateObserver = nil
        guard let window else { return }
        windowUpdateObserver = OPNWindowUpdateObserver(window: window) { [weak self] in
            self?.handleWindowUpdate()
        }
    }

    /// Walks now, then keeps walking until the tree has held still for the settle interval. Nothing
    /// stays registered once it retires, so an idle window costs no run-loop pass and no walk.
    private func beginSettling() {
        settleSchedule = OPNDensitySettleSchedule(now: CFAbsoluteTimeGetCurrent())
        // A live resize rebuilds the tree faster than a walk can follow it; the next pass picks it up.
        if window?.inLiveResize != true {
            applyDensity(targetScale: effectiveTargetScale())
        }
        scheduleNextWalk()
    }

    private func scheduleNextWalk() {
        guard let settleSchedule else { return }
        settleTimer?.invalidate()
        let timer = Timer(timeInterval: settleSchedule.walkInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.performScheduledWalk() }
        }
        // Leeway, so the system can coalesce the wake with whatever else the run loop is doing.
        timer.tolerance = OPNDensitySettleSchedule.activeInterval
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    private func performScheduledWalk() {
        settleTimer = nil
        guard let window else {
            stopSettling()
            return
        }
        guard !window.inLiveResize else {
            settleSchedule?.keepWalking(now: CFAbsoluteTimeGetCurrent())
            scheduleNextWalk()
            return
        }
        guard isDensityCorrectionNeeded else {
            stopSettling()
            restoreNaturalDensity()
            return
        }
        guard var schedule = settleSchedule else {
            stopSettling()
            return
        }
        let nextDelay = schedule.delayUntilNextWalk(
            now: CFAbsoluteTimeGetCurrent(),
            isChanged: applyDensity(targetScale: effectiveTargetScale())
        )
        settleSchedule = schedule
        guard nextDelay != nil else {
            stopSettling()
            return
        }
        scheduleNextWalk()
    }

    private func stopSettling() {
        settleTimer?.invalidate()
        settleTimer = nil
        settleSchedule = nil
    }

    private func effectiveTargetScale() -> CGFloat {
        scale * (window?.backingScaleFactor ?? 1)
    }

    @discardableResult
    func applyDensity(targetScale: CGFloat) -> Bool {
        guard let root = window?.contentView?.layer else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let isChanged = forceContentsScale(root, targetScale: targetScale)
        CATransaction.commit()
        return isChanged
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
        var isChanged = false
        if Self.isDrawingLayer(layer), abs(layer.contentsScale - targetScale) > 0.0001 {
            layer.contentsScale = targetScale
            layer.setNeedsDisplay()
            markOwningHostingViewDirty(layer)
            isChanged = true
        }
        guard let sublayers = layer.sublayers else { return isChanged }
        for sublayer in sublayers where forceContentsScale(sublayer, targetScale: targetScale) {
            isChanged = true
        }
        return isChanged
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
