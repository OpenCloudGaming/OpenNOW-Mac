import AppKit
import CoreGraphics
import Foundation

/// Drives the real macOS cursor from the right trackpad while the Guide/Steam button is
/// held, so the user can click the app window and regain OS focus during a stream (the
/// stream's own trackpad-mouse feature moves the cursor inside the remote game instead).
/// Posting synthetic events requires the Accessibility permission.
@MainActor
final class SteamControllerLocalCursorInjector {
    static let shared = SteamControllerLocalCursorInjector()

    private let sensitivity: CGFloat = 900
    private let deadzone: Float = 0.002
    private let source = CGEventSource(stateID: .hidSystemState)

    private var lastPad: (x: Float, y: Float)?
    private var leftDown = false

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        // "AXTrustedCheckOptionPrompt" is the stable string value of kAXTrustedCheckOptionPrompt;
        // spelled out to avoid touching the (non-Sendable) CFString global under strict concurrency.
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func update(pad: SteamControllerTrackpadState) {
        guard Self.hasAccessibilityPermission else { return }
        handleMotion(pad: pad)
        handleClick(pressed: pad.pressed)
    }

    /// Release any held click; leave the cursor where it is.
    func reset() {
        if leftDown {
            postButton(down: false, at: currentLocation())
            leftDown = false
        }
        lastPad = nil
    }

    private func handleMotion(pad: SteamControllerTrackpadState) {
        guard pad.touched else {
            lastPad = nil
            return
        }
        defer { lastPad = (pad.x, pad.y) }
        guard let previous = lastPad else { return } // first frame establishes origin only

        let dx = CGFloat(pad.x - previous.x) * sensitivity
        let dy = CGFloat(-(pad.y - previous.y)) * sensitivity // trackpad up is +y; screen y grows downward
        guard abs(pad.x - previous.x) > deadzone || abs(pad.y - previous.y) > deadzone else { return }

        let target = clampToScreens(CGPoint(x: currentLocation().x + dx, y: currentLocation().y + dy))
        let type: CGEventType = leftDown ? .leftMouseDragged : .mouseMoved
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        event?.post(tap: .cghidEventTap)
    }

    private func handleClick(pressed: Bool) {
        guard pressed != leftDown else { return }
        leftDown = pressed
        postButton(down: pressed, at: currentLocation())
    }

    private func postButton(down: Bool, at point: CGPoint) {
        let type: CGEventType = down ? .leftMouseDown : .leftMouseUp
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func clampToScreens(_ point: CGPoint) -> CGPoint {
        var maxX: CGFloat = 0
        var maxY: CGFloat = 0
        for screen in NSScreen.screens {
            maxX = max(maxX, screen.frame.maxX)
            maxY = max(maxY, screen.frame.maxY)
        }
        return CGPoint(x: min(max(0, point.x), maxX), y: min(max(0, point.y), maxY))
    }
}
