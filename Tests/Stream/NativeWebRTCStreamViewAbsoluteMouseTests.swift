import AppKit
import CoreMedia
import CoreVideo
import Testing
@testable import OpenNOW

private struct MouseButtonTransition: Equatable {
    let button: MouseButton
    let isPressed: Bool
}

@Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason))) @MainActor func absoluteMouseModeMapsDisplayedVideoCoordinates() throws {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
    view.mouseInputMode = .absolute
    view.setStreamContentSize(width: 1920, height: 1080)
    view.layoutSubtreeIfNeeded()
    let timestamp = MediaTimestamp(nanoseconds: 1_000)

    #expect(view.absoluteMouseEvent(at: CGPoint(x: 800, y: 500), timestamp: timestamp) == NativeNVSTAbsoluteMouseEvent(x: 800, y: 450, viewportWidth: 1600, viewportHeight: 900, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 0, y: 50), timestamp: timestamp) == NativeNVSTAbsoluteMouseEvent(x: 0, y: 899, viewportWidth: 1600, viewportHeight: 900, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 1599, y: 949), timestamp: timestamp) == NativeNVSTAbsoluteMouseEvent(x: 1599, y: 1, viewportWidth: 1600, viewportHeight: 900, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 800, y: 25), timestamp: timestamp) == NativeNVSTAbsoluteMouseEvent(x: 800, y: 899, viewportWidth: 1600, viewportHeight: 900, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 800, y: 975), timestamp: timestamp) == NativeNVSTAbsoluteMouseEvent(x: 800, y: 0, viewportWidth: 1600, viewportHeight: 900, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: -100, y: 500), timestamp: timestamp) == NativeNVSTAbsoluteMouseEvent(x: 0, y: 450, viewportWidth: 1600, viewportHeight: 900, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 1700, y: 500), timestamp: timestamp) == NativeNVSTAbsoluteMouseEvent(x: 1599, y: 450, viewportWidth: 1600, viewportHeight: 900, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: CGFloat.nan, y: 500), timestamp: timestamp) == nil)
}

@Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason))) @MainActor func absoluteMouseModeReprojectsOnlyForAFillThatWasDrawn() throws {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
    view.mouseInputMode = .absolute
    view.setStreamContentSize(width: 1920, height: 1080)
    view.layoutSubtreeIfNeeded()
    // Crop is selected, but no renderer has drawn a fill pass: the picture on screen is where the
    // plain aspect fit put it, so a click that was reprojected anyway would land wrong.
    view.setPillarboxFill(mode: OPNPillarboxFillMode.cropFill.rawValue, dim: 55)
    let timestamp = MediaTimestamp(nanoseconds: 1_000)

    #expect(view.pillarboxPointerMapping() == .identity)
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 0, y: 500), timestamp: timestamp) ==
            NativeNVSTAbsoluteMouseEvent(x: 0, y: 450, viewportWidth: 1600, viewportHeight: 900, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 1599, y: 500), timestamp: timestamp) ==
            NativeNVSTAbsoluteMouseEvent(x: 1599, y: 450, viewportWidth: 1600, viewportHeight: 900, timestamp: timestamp))
}

@Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason))) @MainActor func absoluteMouseModeReportsBackingPixelsNotPoints() throws {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
    view.mouseInputMode = .absolute
    view.setStreamContentSize(width: 1920, height: 1080)
    view.layoutSubtreeIfNeeded()
    let timestamp = MediaTimestamp(nanoseconds: 1_000)

    // Position and viewport scale together: the seat divides one by the other, so the aim point is
    // unchanged — what the extra pixels buy is that a half-point move can still be expressed.
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 800, y: 500), timestamp: timestamp, backingScale: 2) ==
            NativeNVSTAbsoluteMouseEvent(x: 1600, y: 900, viewportWidth: 3200, viewportHeight: 1800, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 800.5, y: 500), timestamp: timestamp, backingScale: 2)?.x == 1601)
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 800.5, y: 500), timestamp: timestamp, backingScale: 1)?.x == 800)
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 1600, y: 950), timestamp: timestamp, backingScale: 2) ==
            NativeNVSTAbsoluteMouseEvent(x: 3199, y: 0, viewportWidth: 3200, viewportHeight: 1800, timestamp: timestamp))

    // No window means no backing scale to ask for; a scale of 1 is the fallback, never a crash.
    #expect(view.window == nil)
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 800, y: 500), timestamp: timestamp) ==
            view.absoluteMouseEvent(at: CGPoint(x: 800, y: 500), timestamp: timestamp, backingScale: 1))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 800, y: 500), timestamp: timestamp, backingScale: 0) == nil)
}

@Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason))) @MainActor func absoluteMouseModeDropsRepeatedPositionsAndResendsAfterARelease() throws {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    view.mouseInputMode = .absolute
    var sequence: [String] = []
    view.onAbsoluteMouseMove = { event in sequence.append("position:\(event.x),\(event.y)") }
    view.onInputEvent = { event in
        if case .mouse(.button(_, _, let isPressed, _)) = event { sequence.append(isPressed ? "down" : "up") }
    }
    let location = NSPoint(x: 100, y: 100)
    let move = try #require(makeMouseEvent(type: .mouseMoved, location: location))
    let elsewhere = try #require(makeMouseEvent(type: .mouseMoved, location: NSPoint(x: 300, y: 100)))
    let mouseDown = try #require(makeMouseEvent(type: .leftMouseDown, location: location))
    let mouseUp = try #require(makeMouseEvent(type: .leftMouseUp, location: location))

    view.mouseMoved(with: move)
    view.mouseMoved(with: move)
    view.mouseDown(with: mouseDown)
    view.mouseUp(with: mouseUp)
    view.mouseMoved(with: elsewhere)
    // Focus loss puts the seat's pointer beyond what we can assume, so the record is dropped and
    // the next position goes out even though it repeats one already sent.
    view.releasePressedInputs()
    view.mouseMoved(with: elsewhere)

    #expect(sequence == ["position:100,620", "down", "up", "position:300,620", "position:300,620"])
}

@Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason))) @MainActor func absoluteMouseModeForwardsCompleteClickWithoutPointerLock() throws {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    view.mouseInputMode = .absolute
    var events: [UserInputEvent] = []
    var sequence: [String] = []
    view.onAbsoluteMouseMove = { event in sequence.append("position:\(event.x),\(event.y)") }
    view.onInputEvent = { event in
        events.append(event)
        if case .mouse(.button(_, _, let isPressed, _)) = event { sequence.append(isPressed ? "down" : "up") }
    }
    let mouseDown = try #require(makeMouseEvent(type: .leftMouseDown))
    let mouseUp = try #require(makeMouseEvent(type: .leftMouseUp))

    view.mouseDown(with: mouseDown)
    view.mouseUp(with: mouseUp)

    #expect(!view.isPointerLocked)
    #expect(mouseButtonTransitions(events) == [
        MouseButtonTransition(button: .left, isPressed: true),
        MouseButtonTransition(button: .left, isPressed: false),
    ])
    // The position ahead of the press goes out; the identical one ahead of the release does not,
    // because the seat's pointer has not moved since.
    #expect(sequence == ["position:0,719", "down", "up"])
}

@Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason))) @MainActor func absoluteMouseModeClampsLetterboxClickAheadOfThePress() throws {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
    view.mouseInputMode = .absolute
    view.setStreamContentSize(width: 1920, height: 1080)
    view.layoutSubtreeIfNeeded()
    var sequence: [String] = []
    view.onAbsoluteMouseMove = { event in sequence.append("position:\(event.x),\(event.y)") }
    view.onInputEvent = { event in
        if case .mouse(.button(_, _, let isPressed, _)) = event { sequence.append(isPressed ? "down" : "up") }
    }
    let location = NSPoint(x: 800, y: 975)
    let mouseDown = try #require(makeMouseEvent(type: .leftMouseDown, location: location))
    let mouseUp = try #require(makeMouseEvent(type: .leftMouseUp, location: location))

    view.mouseDown(with: mouseDown)
    view.mouseUp(with: mouseUp)

    #expect(sequence == ["position:800,0", "down", "up"])
}

@Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason))) @MainActor func detachedNvstRendererCannotRestampTheDecodedGeometry() async throws {
    // The decoded size is measured on the decode thread and hopped to the main actor, where it
    // becomes the view's `streamContentSize` — the rect every absolute pointer position is
    // measured against. A hop that lands after the session ended would aim the next session's
    // clicks with the previous stream's geometry.
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    let renderer = NvstBifrostFreeVideoRenderer(parentView: parent, targetFps: 60)
    var reported: [String] = []
    renderer.onDecodedSizeChanged = { width, height in reported.append("\(width)x\(height)") }
    let buffer = try #require(makeDecodedPixelBuffer(width: 1920, height: 1080))

    renderer.detach()
    renderer.frameSink.render(pixelBuffer: buffer, presentationTime: .zero, isKeyframe: true)
    await Task.yield()
    await Task.yield()

    #expect(reported.isEmpty)
}

private func makeDecodedPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                              attributes as CFDictionary, &buffer) == kCVReturnSuccess else { return nil }
    return buffer
}

@MainActor private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint = .zero) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )
}

private func mouseButtonTransitions(_ events: [UserInputEvent]) -> [MouseButtonTransition] {
    events.compactMap { event in
        guard case .mouse(.button(_, let button, let isPressed, _)) = event else { return nil }
        return MouseButtonTransition(button: button, isPressed: isPressed)
    }
}
