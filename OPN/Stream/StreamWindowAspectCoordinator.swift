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

    func attach(_ window: NSWindow?) {
        guard self.window !== window else { return }
        clearAppliedAspectRatio()
        removeFullScreenTransitionObservers()
        self.window = window
        originalFullSizeContentView = window?.styleMask.contains(.fullSizeContentView) == true
        appliedAspectRatio = nil
        appliedLockState = nil
        appliedTitlebarExclusiveContent = nil
        isFullScreenTransitioning = false
        needsDeferredAspectRatioClear = false
        addFullScreenTransitionObservers(for: window)
        apply()
    }

    func update(aspectRatio: Double, isLocked: Bool, usesTitlebarExclusiveContent: Bool) {
        self.aspectRatio = aspectRatio
        self.isLocked = isLocked
        self.usesTitlebarExclusiveContent = usesTitlebarExclusiveContent
        apply()
    }

    func detach() {
        clearAppliedAspectRatio()
        removeFullScreenTransitionObservers()
        window = nil
        appliedAspectRatio = nil
        appliedLockState = nil
        appliedTitlebarExclusiveContent = nil
        originalFullSizeContentView = false
        isFullScreenTransitioning = false
        needsDeferredAspectRatioClear = false
    }

    private func apply() {
        guard let window else { return }
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
        window.contentAspectRatio = .zero
        window.aspectRatio = .zero
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
        guard window.styleMask.contains(.fullSizeContentView) != shouldUseFullSizeContentView else { return }
        let topEdge = window.frame.maxY
        let centerX = window.frame.midX
        if shouldUseFullSizeContentView {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
        positionWindow(window, topEdge: topEdge, centerX: centerX)
    }

    private func resizeContent(_ window: NSWindow, toAspectRatio aspectRatio: Double) {
        guard let contentView = window.contentView else { return }
        let currentSize = contentView.bounds.size
        guard currentSize.width > 0, currentSize.height > 0 else { return }
        let topEdge = window.frame.maxY
        let centerX = window.frame.midX
        let minimumSize = window.contentMinSize
        var width = max(currentSize.width, minimumSize.width)
        var height = width / aspectRatio
        if height < minimumSize.height {
            height = minimumSize.height
            width = height * aspectRatio
        }
        if let visibleFrame = window.screen?.visibleFrame {
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
        window.setContentSize(NSSize(width: width, height: height))
        positionWindow(window, topEdge: topEdge, centerX: centerX)
    }

    private func positionWindow(_ window: NSWindow, topEdge: CGFloat, centerX: CGFloat) {
        var frame = window.frame
        frame.origin.x = centerX - frame.width / 2
        frame.origin.y = topEdge - frame.height
        if let screen = window.screen {
            frame = window.constrainFrameRect(frame, to: screen)
        }
        window.setFrame(frame, display: true)
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
    }

    private func finishFullScreenTransition() {
        DispatchQueue.main.async { [weak self] in
            Task { @MainActor in
                self?.isFullScreenTransitioning = false
                self?.apply()
            }
        }
    }
}
