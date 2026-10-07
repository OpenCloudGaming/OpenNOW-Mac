import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

@MainActor
@Suite struct InterfaceScaleDensityBoosterTests {
    @Test func drawingLayerDetectionIdentifiesSwiftUIDrawingLayer() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: Text("Density Test").font(.system(size: 10)))
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let rootLayer = hostingView.layer else {
            Issue.record("Expected hosting view to have a root layer")
            return
        }

        #expect(!OPNInterfaceScaleDensityView.isDrawingLayer(rootLayer))

        var foundDrawingLayer = false
        func scan(_ layer: CALayer) {
            if OPNInterfaceScaleDensityView.isDrawingLayer(layer) {
                foundDrawingLayer = true
            }
            layer.sublayers?.forEach(scan)
        }
        scan(rootLayer)

        #expect(foundDrawingLayer)
    }

    @Test func applyDensityUpdatesContentsScaleOnSwiftUIDrawingLayers() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: Text("Density Scale Test").font(.system(size: 11)))
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let densityView = OPNInterfaceScaleDensityView(scale: 1.5)
        window.contentView?.addSubview(densityView)

        let targetScale: CGFloat = 2.5
        let isChanged = densityView.applyDensity(targetScale: targetScale)
        #expect(isChanged)

        guard let rootLayer = hostingView.layer else {
            Issue.record("Expected hosting view to have a root layer")
            return
        }

        var drawingLayerScales: [CGFloat] = []
        func collectScales(_ layer: CALayer) {
            if OPNInterfaceScaleDensityView.isDrawingLayer(layer) {
                drawingLayerScales.append(layer.contentsScale)
            }
            layer.sublayers?.forEach(collectScales)
        }
        collectScales(rootLayer)

        #expect(!drawingLayerScales.isEmpty)
        for scale in drawingLayerScales {
            #expect(abs(scale - targetScale) < 0.001)
        }
    }

    @Test func boosterDoesNotCorrectAtTheDefaultScale() {
        let window = makeMagnifiedWindow()
        let booster = OPNInterfaceScaleDensityView(scale: 1)
        window.contentView?.addSubview(booster)

        #expect(booster.isCorrectingDensity == false)
    }

    @Test func boosterCorrectsWhileAMagnifiedSurfaceIsOnScreen() {
        let window = makeMagnifiedWindow()
        let booster = OPNInterfaceScaleDensityView(scale: 1.5)
        window.contentView?.addSubview(booster)

        #expect(booster.isCorrectingDensity)
    }

    /// The walk retires once the tree holds still, and a redraw - when SwiftUI can put a fresh
    /// `CGDrawingLayer` into the magnified subtree - brings it back.
    @Test func boosterRetiresWhileIdleAndRestartsOnARedraw() {
        let window = makeMagnifiedWindow()
        let booster = OPNInterfaceScaleDensityView(scale: 1.5)
        window.contentView?.addSubview(booster)
        #expect(booster.isCorrectingDensity)

        let deadline = Date().addingTimeInterval(5)
        while booster.isCorrectingDensity, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(booster.isCorrectingDensity == false)

        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(booster.isCorrectingDensity)
    }
}

@Suite struct DensitySettleScheduleTests {
    @Test func keepsTheActiveCadenceWhileTheTreeChanges() {
        var schedule = OPNDensitySettleSchedule(now: 0)

        #expect(schedule.delayUntilNextWalk(now: 0.1, isChanged: true) == OPNDensitySettleSchedule.activeInterval)
        #expect(schedule.delayUntilNextWalk(now: 0.2, isChanged: true) == OPNDensitySettleSchedule.activeInterval)
    }

    @Test func backsOffAndRetiresOnceTheTreeHoldsStill() {
        var schedule = OPNDensitySettleSchedule(now: 0)

        #expect(schedule.delayUntilNextWalk(now: 0.1, isChanged: false) == 0.2)
        #expect(schedule.delayUntilNextWalk(now: 0.3, isChanged: false) == 0.4)
        #expect(schedule.delayUntilNextWalk(now: 0.7, isChanged: false) == 0.8)
        #expect(schedule.delayUntilNextWalk(now: 1.5, isChanged: false) == nil)
    }

    @Test func anExternalChangeKeepsTheCorrectionAlive() {
        var changed = OPNDensitySettleSchedule(now: 0)
        var quiet = OPNDensitySettleSchedule(now: 0)
        changed.keepWalking(now: 1.0)

        for time in [0.1, 0.3, 0.7] {
            _ = quiet.delayUntilNextWalk(now: time, isChanged: false)
            _ = changed.delayUntilNextWalk(now: time, isChanged: false)
        }

        #expect(quiet.delayUntilNextWalk(now: 1.5, isChanged: false) == nil)
        #expect(changed.delayUntilNextWalk(now: 1.5, isChanged: false) != nil)
    }
}

@MainActor
private func makeMagnifiedWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    window.contentView = content
    content.addSubview(OPNMagnifiedSurfaceMarkerView(frame: content.bounds))
    return window
}
