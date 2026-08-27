//
//  CatalogWindowPlumbing.swift
//  OpenNOW
//

import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

struct WindowTopInsetReader: NSViewRepresentable {
    let onChange: @MainActor (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> WindowTopInsetView {
        let view = WindowTopInsetView(frame: .zero)
        let coordinator = context.coordinator
        view.onWindowChanged = { window in coordinator.attach(window) }
        view.onLayoutChanged = { coordinator.update() }
        return view
    }

    func updateNSView(_ view: WindowTopInsetView, context: Context) {
        context.coordinator.update()
    }

    static func dismantleNSView(_ nsView: WindowTopInsetView, coordinator: Coordinator) {
        nsView.onWindowChanged = nil
        nsView.onLayoutChanged = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observerTokens: [NSObjectProtocol] = []
        private var lastInset: CGFloat = -1
        private let onChange: @MainActor (CGFloat) -> Void

        init(onChange: @escaping @MainActor (CGFloat) -> Void) {
            self.onChange = onChange
        }

        func attach(_ window: NSWindow?) {
            guard self.window !== window else {
                update()
                return
            }
            removeObservers()
            self.window = window
            lastInset = -1
            addObservers(for: window)
            update()
        }

        func update() {
            publish(calculatedInset())
        }

        func detach() {
            removeObservers()
            window = nil
            publish(0)
        }

        private func addObservers(for window: NSWindow?) {
            guard let window else { return }
            let notificationCenter = NotificationCenter.default
            let updateNotifications: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didMoveNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            observerTokens = updateNotifications.map { name in
                notificationCenter.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.update() }
                }
            }
            let willEnterToken = notificationCenter.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.publish(0) }
            }
            let didEnterToken = notificationCenter.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.publish(0) }
            }
            observerTokens.append(contentsOf: [willEnterToken, didEnterToken])
        }

        private func removeObservers() {
            let notificationCenter = NotificationCenter.default
            for token in observerTokens {
                notificationCenter.removeObserver(token)
            }
            observerTokens = []
        }

        private func calculatedInset() -> CGFloat {
            guard let window, let contentView = window.contentView else { return 0 }
            guard !window.styleMask.contains(.fullScreen) else { return 0 }

            let safeTopInset = contentView.safeAreaInsets.top
            let layoutTopInset = contentLayoutTopInset(window: window, contentView: contentView)
            let frameTopInset = frameTitlebarInset(window: window)
            return min(max(safeTopInset, layoutTopInset, frameTopInset), min(contentView.bounds.height, 120))
        }

        private func contentLayoutTopInset(window: NSWindow, contentView: NSView) -> CGFloat {
            let layoutRect = window.contentLayoutRect
            let bounds = contentView.bounds
            guard layoutRect.minY >= bounds.minY - 1, layoutRect.maxY <= bounds.maxY + 1 else { return 0 }
            return max(bounds.maxY - layoutRect.maxY, 0)
        }

        private func frameTitlebarInset(window: NSWindow) -> CGFloat {
            let contentRect = NSWindow.contentRect(forFrameRect: window.frame, styleMask: window.styleMask)
            return max(window.frame.height - contentRect.height, 0)
        }

        private func publish(_ inset: CGFloat) {
            guard abs(lastInset - inset) > 0.5 else { return }
            lastInset = inset
            let onChange = onChange
            Task { @MainActor in onChange(inset) }
        }
    }

    final class WindowTopInsetView: NSView {
        var onWindowChanged: (@MainActor (NSWindow?) -> Void)?
        var onLayoutChanged: (@MainActor () -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }

        override func layout() {
            super.layout()
            onLayoutChanged?()
        }
    }
}

struct StreamWindowAspectConfigurator: NSViewRepresentable {
    let aspectRatio: Double
    let isLocked: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowAspectView {
        let view = WindowAspectView(frame: .zero)
        let coordinator = context.coordinator
        view.onWindowChanged = { window in coordinator.attach(window) }
        return view
    }

    func updateNSView(_ view: WindowAspectView, context: Context) {
        context.coordinator.update(aspectRatio: aspectRatio, isLocked: isLocked)
    }

    static func dismantleNSView(_ nsView: WindowAspectView, coordinator: Coordinator) {
        nsView.onWindowChanged = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var aspectRatio: Double = 0
        private var isLocked = false
        private var appliedAspectRatio: Double?
        private var appliedLockState: Bool?
        private var fullScreenTransitionObserverTokens: [NSObjectProtocol] = []
        private var isFullScreenTransitioning = false
        private var needsDeferredAspectRatioClear = false
        private var waitsForLiveResizeEnd = false

        func attach(_ window: NSWindow?) {
            guard self.window !== window else { return }
            clearAppliedAspectRatio()
            removeFullScreenTransitionObservers()
            self.window = window
            appliedAspectRatio = nil
            appliedLockState = nil
            isFullScreenTransitioning = false
            needsDeferredAspectRatioClear = false
            waitsForLiveResizeEnd = false
            addFullScreenTransitionObservers(for: window)
            apply()
        }

        func update(aspectRatio: Double, isLocked: Bool) {
            self.aspectRatio = aspectRatio
            self.isLocked = isLocked
            apply()
        }

        func detach() {
            clearAppliedAspectRatio()
            removeFullScreenTransitionObservers()
            window = nil
            appliedAspectRatio = nil
            appliedLockState = nil
            isFullScreenTransitioning = false
            needsDeferredAspectRatioClear = false
            waitsForLiveResizeEnd = false
        }

        private func apply() {
            guard let window else { return }
            // Changing the aspect ratio re-runs the window's frame math; mid-drag that swaps the
            // theme frame out from under AppKit's resize loop and traps in
            // `_adjustNeedsDisplayRegionForNewFrame:`.
            guard !Self.isLiveResizing(window) else {
                waitsForLiveResizeEnd = true
                return
            }
            waitsForLiveResizeEnd = false
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

            let alreadyApplied = appliedLockState == true && appliedAspectRatio.map { abs($0 - aspectRatio) <= 0.001 } == true
            guard !alreadyApplied else { return }
            let lockedAspectRatio = NSSize(width: aspectRatio, height: 1)
            window.contentAspectRatio = lockedAspectRatio
            window.aspectRatio = lockedAspectRatio
            appliedAspectRatio = aspectRatio
            appliedLockState = true
            needsDeferredAspectRatioClear = false
        }

        private func clearAppliedAspectRatio() {
            guard let window else {
                appliedAspectRatio = nil
                appliedLockState = false
                needsDeferredAspectRatioClear = false
                return
            }
            guard !isFullScreenTransitioning, !window.styleMask.contains(.fullScreen) else {
                needsDeferredAspectRatioClear = true
                return
            }
            guard !Self.isLiveResizing(window) else {
                needsDeferredAspectRatioClear = true
                waitsForLiveResizeEnd = true
                return
            }
            if appliedLockState == true {
                window.contentAspectRatio = .zero
                window.aspectRatio = .zero
            }
            appliedAspectRatio = nil
            appliedLockState = false
            needsDeferredAspectRatioClear = false
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
            let didEndLiveResizeToken = notificationCenter.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { [weak self] in
                    self?.finishLiveResize()
                }
            }
            fullScreenTransitionObserverTokens = [willEnterToken, willExitToken, didExitToken, didEndLiveResizeToken]
        }

        private func finishLiveResize() {
            guard waitsForLiveResizeEnd else { return }
            waitsForLiveResizeEnd = false
            apply()
        }

        private static func isLiveResizing(_ window: NSWindow) -> Bool {
            window.inLiveResize || window.contentView?.inLiveResize == true
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
            Task { @MainActor [weak self] in
                Task { @MainActor in
                    self?.isFullScreenTransitioning = false
                    self?.apply()
                }
            }
        }
    }

    final class WindowAspectView: NSView {
        var onWindowChanged: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }
}
