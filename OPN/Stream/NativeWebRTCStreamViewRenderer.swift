//  The native NVST renderer window this view hosts: where it sits, what colour space it
//  presents in, and how its Metal view is embedded. Split out of NativeWebRTCStreamView.swift.
//

import AppKit
import QuartzCore

extension NativeWebRTCStreamView {
    static func configureNativeNVSTPresentation(window: NSWindow, requestedHDR: Bool, codecSupportsHDR: Bool) {
        guard let rendererWindow = window as? NativeNVSTRendererWindow else { return }
        rendererWindow.hdrPresentationRequested = requestedHDR
        rendererWindow.codecSupportsHDR = codecSupportsHDR
        let screenSupportsEDR = rendererWindow.parent?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? rendererWindow.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        let usesEDR = nativeNVSTPresentationUsesEDR(requestedHDR: requestedHDR, codecSupportsHDR: codecSupportsHDR, screenSupportsEDR: screenSupportsEDR > 1)
        rendererWindow.colorSpace = usesEDR ? nil : .sRGB
        rendererWindow.contentView?.layer?.wantsExtendedDynamicRangeContent = usesEDR
    }

    static func nativeNVSTPresentationUsesEDR(requestedHDR: Bool, codecSupportsHDR: Bool, screenSupportsEDR: Bool) -> Bool {
        requestedHDR && codecSupportsHDR && screenSupportsEDR
    }

    public func setNativeNVSTVideoVisible(_ visible: Bool) {
        nativeNVSTVideoVisible = visible
        if visible { nativeNVSTRendererPreparedForShutdown = false }
        if !nativeNVSTRendererPreparedForShutdown { _ = embedNativeNVSTMetalViewIfAvailable() }
        nativeNVSTMetalView?.isHidden = !visible
        nativeNVSTRendererWindow.alphaValue = 0
    }

    public var nativeNVSTRendererSurfaceReady: Bool {
        // The Bifrost-free path draws through its own renderer, not the vendored NVST Metal view,
        // so it reports its own surface's readiness. Without this the health monitor could never
        // see a ready surface on that path and tore down a healthy stream.
        if let renderer = nvstBifrostFreeRenderer { return renderer.isSurfaceReady }
        guard nativeNVSTRendererEnabled, nativeNVSTVideoVisible, !nativeNVSTRendererPreparedForShutdown,
              let metalView = nativeNVSTMetalView, metalView.superview === videoSurface,
              let metalLayer = metalView.layer as? CAMetalLayer else { return false }
        return metalLayer.drawableSize.width >= 1 && metalLayer.drawableSize.height >= 1
    }

    public func prepareNativeNVSTRendererForShutdown() {
        nativeNVSTVideoVisible = false
        nativeNVSTRendererPreparedForShutdown = true
        nativeNVSTRendererWindow.alphaValue = 0
        guard let metalView = nativeNVSTMetalView,
              let rendererContentView = nativeNVSTRendererWindow.contentView else { return }
        metalView.isHidden = true
        metalView.removeFromSuperview()
        metalView.frame = rendererContentView.bounds
        metalView.autoresizingMask = [.width, .height]
        rendererContentView.addSubview(metalView)
        nativeNVSTMetalView = nil
    }

    public func restoreInputFocus() {
        guard remoteInputEnabled, NSApplication.shared.isActive, window?.isKeyWindow == true else { return }
        window?.makeFirstResponder(self)
        if locksPointerWhenRelativeModeSelected, mouseInputMode == .relative, directMouseInputEnabled { setPointerLocked(true) }
    }

    public override func layout() {
        super.layout()
        videoSurface.frame = videoContentFrame()
        nativeNVSTMetalView?.frame = videoSurface.bounds
        if nativeNVSTRendererEnabled {
            updateNativeNVSTRendererWindowFrame()
            updateNativeNVSTPresentation()
            if !nativeNVSTRendererPreparedForShutdown { _ = embedNativeNVSTMetalViewIfAvailable() }
        }
    }

    func updateNativeNVSTRendererWindowParent() {
        guard nativeNVSTRendererParentWindow !== window else { return }
        if let nativeNVSTRendererParentWindow {
            nativeNVSTRendererParentWindow.removeChildWindow(nativeNVSTRendererWindow)
        }
        nativeNVSTRendererParentWindow = window
        guard let window else {
            nativeNVSTRendererWindow.orderOut(nil)
            return
        }
        window.addChildWindow(nativeNVSTRendererWindow, ordered: .above)
        nativeNVSTRendererWindow.orderFront(nil)
        updateNativeNVSTRendererWindowFrame()
    }

    func updateNativeNVSTRendererWindowFrame() {
        guard let window else { return }
        let rendererFrameInWindow = videoSurface.convert(videoSurface.bounds, to: nil)
        nativeNVSTRendererWindow.setFrame(window.convertToScreen(rendererFrameInWindow), display: true)
    }

    func installNativeNVSTDisplayNotifications() {
        removeNativeNVSTDisplayNotifications()
        guard let window else { return }
        let center = NotificationCenter.default
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNativeNVSTDisplayState() }
        }
        for observedWindow in [window, nativeNVSTRendererWindow] {
            nativeNVSTDisplayNotificationTokens.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: observedWindow, queue: .main, using: refresh))
            nativeNVSTDisplayNotificationTokens.append(center.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification, object: observedWindow, queue: .main, using: refresh))
            nativeNVSTDisplayNotificationTokens.append(center.addObserver(forName: NSWindow.didChangeScreenProfileNotification, object: observedWindow, queue: .main, using: refresh))
        }
        nativeNVSTDisplayNotificationTokens.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: NSApplication.shared, queue: .main, using: refresh))
    }

    func removeNativeNVSTDisplayNotifications() {
        let center = NotificationCenter.default
        nativeNVSTDisplayNotificationTokens.forEach { center.removeObserver($0) }
        nativeNVSTDisplayNotificationTokens.removeAll()
    }

    func refreshNativeNVSTDisplayState() {
        guard nativeNVSTRendererEnabled else { return }
        updateNativeNVSTRendererWindowFrame()
        if let nativeNVSTMetalView { updateNativeNVSTMetalDrawableSize(nativeNVSTMetalView) }
        updateNativeNVSTPresentation()
    }

    func updateNativeNVSTPresentation() {
        let screenSupportsEDR = window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        let usesEDR = Self.nativeNVSTPresentationUsesEDR(
            requestedHDR: nativeNVSTRendererWindow.hdrPresentationRequested,
            codecSupportsHDR: nativeNVSTRendererWindow.codecSupportsHDR,
            screenSupportsEDR: screenSupportsEDR > 1
        )
        nativeNVSTRendererWindow.colorSpace = usesEDR ? nil : .sRGB
        nativeNVSTRendererWindow.contentView?.layer?.wantsExtendedDynamicRangeContent = usesEDR
        videoSurface.layer?.wantsExtendedDynamicRangeContent = usesEDR
        nativeNVSTMetalView?.layer?.wantsExtendedDynamicRangeContent = usesEDR
    }

    @discardableResult
    func embedNativeNVSTMetalViewIfAvailable() -> Bool {
        if let nativeNVSTMetalView {
            nativeNVSTMetalView.frame = videoSurface.bounds
            nativeNVSTMetalView.isHidden = !nativeNVSTVideoVisible
            updateNativeNVSTMetalDrawableSize(nativeNVSTMetalView)
            updateNativeNVSTPresentation()
            return true
        }
        guard nativeNVSTVideoVisible,
              let metalView = nativeNVSTRendererWindow.contentView?.subviews.first(where: { $0.layer is CAMetalLayer }) else { return false }
        metalView.removeFromSuperview()
        metalView.frame = videoSurface.bounds
        // Position explicitly (not autoresized) so crop/stretch can centre-scale it.
        metalView.autoresizingMask = []
        metalView.isHidden = !nativeNVSTVideoVisible
        videoSurface.addSubview(metalView)
        nativeNVSTMetalView = metalView
        updateNativeNVSTMetalDrawableSize(metalView)
        updateNativeNVSTPresentation()
        return true
    }

    func updateNativeNVSTMetalDrawableSize(_ metalView: NSView) {
        guard let metalLayer = metalView.layer as? CAMetalLayer else { return }
        let scale = max(1, metalView.window?.backingScaleFactor ?? window?.backingScaleFactor ?? 1)
        guard let drawableSize = Self.nativeNVSTDrawableSize(boundsSize: metalView.bounds.size, backingScaleFactor: scale) else { return }
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = drawableSize
    }

    static func nativeNVSTDrawableSize(boundsSize: CGSize, backingScaleFactor: CGFloat) -> CGSize? {
        guard boundsSize.width.isFinite, boundsSize.height.isFinite, backingScaleFactor.isFinite,
              boundsSize.width >= 1, boundsSize.height >= 1, backingScaleFactor > 0 else { return nil }
        return CGSize(width: floor(boundsSize.width * backingScaleFactor), height: floor(boundsSize.height * backingScaleFactor))
    }

    public func setPointerLocked(_ locked: Bool) {
        if locked {
            guard !isPointerLocked else { return }
            enablePointerLock()
        } else {
            releasePressedMouseButtons()
            disablePointerLock()
            disableAbsoluteCursorConfinement()
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        trackingArea = area
        addTrackingArea(area)
    }

    public override func mouseDown(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        window?.makeFirstResponder(self)
        if capturePointerForMouseDown() { return }
        captureAbsoluteCursorIfNeeded()
        emitAbsoluteMousePosition(event)
        emitMouseButton(.left, isPressed: true)
    }

    public override func mouseUp(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitAbsoluteMousePosition(event)
        emitMouseButton(.left, isPressed: false)
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        window?.makeFirstResponder(self)
        if capturePointerForMouseDown() { return }
        captureAbsoluteCursorIfNeeded()
        emitAbsoluteMousePosition(event)
        emitMouseButton(.right, isPressed: true)
    }

    public override func rightMouseUp(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitAbsoluteMousePosition(event)
        emitMouseButton(.right, isPressed: false)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        guard let button = mouseButton(event.buttonNumber) else { return }
        window?.makeFirstResponder(self)
        if capturePointerForMouseDown() { return }
        captureAbsoluteCursorIfNeeded()
        emitAbsoluteMousePosition(event)
        emitMouseButton(button, isPressed: true)
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        guard let button = mouseButton(event.buttonNumber) else { return }
        emitAbsoluteMousePosition(event)
        emitMouseButton(button, isPressed: false)
    }

    public override func mouseMoved(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        if constrainAssociatedAbsoluteCursor() { return }
        emitMouseMove(event)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        if constrainAssociatedAbsoluteCursor() { return }
        emitMouseMove(event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        if constrainAssociatedAbsoluteCursor() { return }
        emitMouseMove(event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        if constrainAssociatedAbsoluteCursor() { return }
        emitMouseMove(event)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitScrollWheel(event)
    }

    public override func keyDown(with event: NSEvent) {
        guard remoteInputEnabled else {
            if handleCommand(event) { return }
            super.keyDown(with: event)
            return
        }
        if handlePushToTalk(event, isPressed: true) { return }
        if handlePasteShortcut(event) { return }
        if handleCommand(event) { return }
        if handleTextInput(event) { return }
        emitKey(event, isPressed: true)
    }

    public override func keyUp(with event: NSEvent) {
        guard remoteInputEnabled else {
            if handleCommand(event) { return }
            super.keyUp(with: event)
            return
        }
        if handlePushToTalk(event, isPressed: false) { return }
        if handlePasteShortcut(event) { return }
        if handleCommand(event) { return }
        if textInputKeyCodes.remove(UInt16(event.keyCode)) != nil { return }
        emitKey(event, isPressed: false)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard remoteInputEnabled else {
            super.flagsChanged(with: event)
            return
        }
        let pressed: Bool
        switch event.keyCode {
        case 54, 55:
            pressed = event.modifierFlags.contains(.command)
        case 56, 60:
            pressed = event.modifierFlags.contains(.shift)
        case 57:
            pressed = event.modifierFlags.contains(.capsLock)
        case 58, 61:
            pressed = event.modifierFlags.contains(.option)
        case 59, 62:
            pressed = event.modifierFlags.contains(.control)
        default:
            return
        }
        emitKey(event, isPressed: pressed)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard remoteInputEnabled else { return handleCommand(event) || super.performKeyEquivalent(with: event) }
        // Order matters. App stream commands (quit, HUD) and paste are handled locally first; only
        // then does a Command-shortcut get forwarded to the remote. Without the forward, macOS
        // routes Cmd+C / Cmd+A to the Edit menu (or discards them) and they never reach `keyDown`,
        // so the remote never sees the copy/select-all the user pressed.
        return handlePasteShortcut(event) || handleCommand(event)
            || forwardCommandShortcut(event) || super.performKeyEquivalent(with: event)
    }
}
