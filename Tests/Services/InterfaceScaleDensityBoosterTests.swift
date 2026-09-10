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

        #expect(!OpenNOWInterfaceScaleDensityView.isDrawingLayer(rootLayer))

        var foundDrawingLayer = false
        func scan(_ layer: CALayer) {
            if OpenNOWInterfaceScaleDensityView.isDrawingLayer(layer) {
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

        let densityView = OpenNOWInterfaceScaleDensityView(scale: 1.5)
        window.contentView?.addSubview(densityView)

        let targetScale: CGFloat = 2.5
        let didChange = densityView.applyDensity(targetScale: targetScale)
        #expect(didChange)

        guard let rootLayer = hostingView.layer else {
            Issue.record("Expected hosting view to have a root layer")
            return
        }

        var drawingLayerScales: [CGFloat] = []
        func collectScales(_ layer: CALayer) {
            if OpenNOWInterfaceScaleDensityView.isDrawingLayer(layer) {
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
}
