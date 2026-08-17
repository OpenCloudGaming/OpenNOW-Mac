import AppKit

@MainActor
final class StreamWindowAspectCoordinator {
    private weak var window: NSWindow?
    private var aspectRatio: Double = 0
    private var isLocked = false
    private var usesTitlebarExclusiveContent = false
    private var appliedAspectRatio: Double?
    private var appliedLockState: Bool?
    private var appliedTitlebarExclusiveContent: Bool?
    private var originalFullSizeContentView = false
    private var fullScreenTransitionObserverTokens: [NSObjectProtocol] = []
    private var isFullScreenTransitioning = false
    private var needsDeferredAspectRatioClear = false
    private var applyGeneration: UInt = 0
    private var waitsForValidGeometry = false

    func attach(_ window: NSWindow?) {
        guard self.window !== window else { return }
        scheduleCurrentWindowRestoration()
        applyGeneration &+= 1
        removeFullScreenTransitionObservers()
        self.window = window
        originalFullSizeContentView = window?.styleMask.contains(.fullSizeContentView) == true
        appliedAspectRatio = nil
        appliedLockState = nil
        appliedTitlebarExclusiveContent = nil
        isFullScreenTransitioning = false
        needsDeferredAspectRatioClear = false
        waitsForValidGeometry = false
        addFullScreenTransitionObservers(for: window)
        scheduleApply()
    }

    func update(aspectRatio: Double, isLocked: Bool, usesTitlebarExclusiveContent: Bool) {
        self.aspectRatio = aspectRatio
        self.isLocked = isLocked
        self.usesTitlebarExclusiveContent = usesTitlebarExclusiveContent
        scheduleApply()
    }

    func detach() {
        scheduleCurrentWindowRestoration()
        applyGeneration &+= 1
        removeFullScreenTransitionObservers()
        window = nil
        appliedAspectRatio = nil
        appliedLockState = nil
        appliedTitlebarExclusiveContent = nil
        originalFullSizeContentView = false
        isFullScreenTransitioning = false
        needsDeferredAspectRatioClear = false
        waitsForValidGeometry = false
    }

    func windowGeometryDidChange() {
        guard waitsForValidGeometry else { return }
        scheduleApply()
    }

    private func scheduleApply() {
        applyGeneration &+= 1
        let generation = applyGeneration
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.applyGeneration == generation else { return }
                self.applyNow()
            }
        }
    }

    private func applyNow() {
        guard let window else { return }
        guard Self.hasValidGeometry(window) else {
            waitsForValidGeometry = true
            return
        }
        waitsForValidGeometry = false
        guard isLocked, aspectRatio.isFinite, aspectRatio > 0 else {
            clearAppliedAspectRatio()
            return
        }

        guard !isFullScreenTransitioning, !window.styleMask.contains(.fullScreen) else {
            needsDeferredAspectRatioClear = true
            return
        }

        if needsDeferredAspectRatioClear {
            clearAppliedAspectRatio()
        }

        let alreadyApplied = appliedLockState == true &&
            appliedAspectRatio.map { abs($0 - aspectRatio) <= 0.001 } == true &&
            appliedTitlebarExclusiveContent == usesTitlebarExclusiveContent
        guard !alreadyApplied else { return }
        let lockedAspectRatio = NSSize(width: aspectRatio, height: 1)
        configureWindowStyle(window, titlebarExclusiveContent: usesTitlebarExclusiveContent)
        if usesTitlebarExclusiveContent {
            resizeContent(window, toAspectRatio: aspectRatio)
            window.contentAspectRatio = lockedAspectRatio
        } else {
            window.aspectRatio = lockedAspectRatio
        }
        appliedAspectRatio = aspectRatio
        appliedLockState = true
        appliedTitlebarExclusiveContent = usesTitlebarExclusiveContent
        needsDeferredAspectRatioClear = false
    }

    private func clearAppliedAspectRatio() {
        guard let window else {
            appliedAspectRatio = nil
            appliedLockState = false
            appliedTitlebarExclusiveContent = nil
            needsDeferredAspectRatioClear = false
            return
        }
        guard !isFullScreenTransitioning, !window.styleMask.contains(.fullScreen) else {
            needsDeferredAspectRatioClear = true
            return
        }
        if appliedLockState == true {
            window.contentAspectRatio = .zero
            window.aspectRatio = .zero
        }
        if appliedTitlebarExclusiveContent == true {
            configureWindowStyle(window, titlebarExclusiveContent: false)
        }
        appliedAspectRatio = nil
        appliedLockState = false
        appliedTitlebarExclusiveContent = nil
        needsDeferredAspectRatioClear = false
    }

    private func configureWindowStyle(_ window: NSWindow, titlebarExclusiveContent: Bool) {
        let shouldUseFullSizeContentView = titlebarExclusiveContent ? false : originalFullSizeContentView
        Self.setFullSizeContentView(shouldUseFullSizeContentView, on: window)
    }

    private func resizeContent(_ window: NSWindow, toAspectRatio aspectRatio: Double) {
        guard let contentView = window.contentView, Self.hasValidGeometry(window) else { return }
        let currentSize = contentView.bounds.size
        guard currentSize.width > 0, currentSize.height > 0 else { return }
        let topEdge = window.frame.maxY
        let centerX = window.frame.midX
        let minimumSize = window.contentMinSize
        let minimumWidth = minimumSize.width.isFinite ? max(minimumSize.width, 0) : 0
        let minimumHeight = minimumSize.height.isFinite ? max(minimumSize.height, 0) : 0
        var width = max(currentSize.width, minimumWidth)
        var height = width / aspectRatio
        let visibleFrame = window.screen?.visibleFrame
        if height < minimumHeight {
            height = minimumHeight
            width = height * aspectRatio
        }
        if let visibleFrame, Self.isValid(frame: visibleFrame) {
            let chromeWidth = max(window.frame.width - currentSize.width, 0)
            let chromeHeight = max(window.frame.height - currentSize.height, 0)
            let maximumWidth = max(visibleFrame.width - chromeWidth, 1)
            let maximumHeight = max(visibleFrame.height - chromeHeight, 1)
            width = min(width, maximumWidth)
            height = width / aspectRatio
            if height > maximumHeight {
                height = maximumHeight
                width = height * aspectRatio
            }
        }
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height)
        let targetFrame = NSWindow.frameRect(forContentRect: contentRect, styleMask: window.styleMask)
        Self.setFrame(window, targetFrame: targetFrame, topEdge: topEdge, centerX: centerX, visibleFrame: visibleFrame)
    }

    private func scheduleCurrentWindowRestoration() {
        guard let window else { return }
        let clearsAspectRatio = appliedLockState == true
        let restoresFullSizeContentView = appliedTitlebarExclusiveContent == true
        let originalFullSizeContentView = self.originalFullSizeContentView
        guard clearsAspectRatio || restoresFullSizeContentView else { return }
        guard !window.styleMask.contains(.fullScreen), Self.hasValidGeometry(window) else { return }
        if clearsAspectRatio {
            window.contentAspectRatio = .zero
            window.aspectRatio = .zero
        }
        if restoresFullSizeContentView {
            Self.setFullSizeContentView(originalFullSizeContentView, on: window)
        }
    }

    private static func setFullSizeContentView(_ enabled: Bool, on window: NSWindow) {
        guard window.styleMask.contains(.fullSizeContentView) != enabled else { return }
        guard let contentView = window.contentView, hasValidGeometry(window) else { return }
        let currentFrame = window.frame
        var styleMask = window.styleMask
        if enabled {
            styleMask.insert(.fullSizeContentView)
        } else {
            styleMask.remove(.fullSizeContentView)
        }
        let contentRect = NSRect(origin: .zero, size: contentView.bounds.size)
        let targetFrame = NSWindow.frameRect(forContentRect: contentRect, styleMask: styleMask)
        guard isValid(frame: targetFrame) else { return }
        let visibleFrame = window.screen?.visibleFrame
        window.styleMask = styleMask
        setFrame(window, targetFrame: targetFrame, topEdge: currentFrame.maxY, centerX: currentFrame.midX, visibleFrame: visibleFrame)
    }

    private static func setFrame(_ window: NSWindow, targetFrame: NSRect, topEdge: CGFloat, centerX: CGFloat, visibleFrame: NSRect?) {
        guard isValid(frame: targetFrame), topEdge.isFinite, centerX.isFinite else { return }
        var frame = targetFrame
        frame.origin.x = centerX - frame.width / 2
        frame.origin.y = topEdge - frame.height
        if let visibleFrame, isValid(frame: visibleFrame) {
            if frame.width <= visibleFrame.width {
                frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
            } else {
                frame.origin.x = visibleFrame.minX
            }
            if frame.height <= visibleFrame.height {
                frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
            } else {
                frame.origin.y = visibleFrame.minY
            }
        }
        guard isValid(frame: frame) else { return }
        window.setFrame(frame, display: true)
    }

    private static func hasValidGeometry(_ window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        return isValid(frame: window.frame) && isValid(size: contentView.bounds.size)
    }

    private static func isValid(frame: NSRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && isValid(size: frame.size)
    }

    private static func isValid(size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private func addFullScreenTransitionObservers(for window: NSWindow?) {
        guard let window else { return }
        let notificationCenter = NotificationCenter.default
        let willEnterToken = notificationCenter.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.beginFullScreenTransition()
            }
        }
        let willExitToken = notificationCenter.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.beginFullScreenTransition()
            }
        }
        let didExitToken = notificationCenter.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishFullScreenTransition()
            }
        }
        fullScreenTransitionObserverTokens = [willEnterToken, willExitToken, didExitToken]
    }

    private func removeFullScreenTransitionObservers() {
        let notificationCenter = NotificationCenter.default
        for token in fullScreenTransitionObserverTokens {
            notificationCenter.removeObserver(token)
        }
        fullScreenTransitionObserverTokens = []
    }

    private func beginFullScreenTransition() {
        isFullScreenTransitioning = true
        applyGeneration &+= 1
    }

    private func finishFullScreenTransition() {
        DispatchQueue.main.async { [weak self] in
            Task { @MainActor in
                self?.isFullScreenTransitioning = false
                self?.scheduleApply()
            }
        }
    }
}
