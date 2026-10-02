import AppKit
import Combine
import Foundation

@MainActor
final class OPNCouchCoopCatalogTiler {
    static let shared = OPNCouchCoopCatalogTiler()

    private var activeSubscription: AnyCancellable?
    private var windowObserver: NSObjectProtocol?

    func start() {
        guard activeSubscription == nil else { return }
        activeSubscription = OPNCouchCoopPresence.shared.$isActive.removeDuplicates().sink { [weak self] isActive in
            Task { @MainActor in self?.activeDidChange(isActive) }
        }
    }

    private func activeDidChange(_ isActive: Bool) {
        guard isActive else {
            stopWaitingForWindow()
            return
        }
        tileMainWindow()
    }

    private func tileMainWindow() {
        guard OPNLabs.isCouchCoopEnabled, OPNCouchCoopPresence.shared.isActive else { return }
        guard let window = OPNMainWindow.existing() else {
            waitForMainWindow()
            return
        }
        stopWaitingForWindow()
        guard !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main,
              let frame = OPNCouchCoopTileGeometry.rect(
                  in: screen.visibleFrame,
                  layout: OPNCouchCoopPreferences.layout(),
                  instance: OPNAppInstance.current.number
              ) else { return }
        window.setFrame(frame, display: true, animate: false)
    }

    private func waitForMainWindow() {
        guard windowObserver == nil else { return }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
            let windowIdentifier = (notification.object as? NSWindow)?.identifier?.rawValue
            MainActor.assumeIsolated {
                guard windowIdentifier == OPNMainWindow.identifier else { return }
                self?.tileMainWindow()
            }
        }
    }

    private func stopWaitingForWindow() {
        guard let windowObserver else { return }
        NotificationCenter.default.removeObserver(windowObserver)
        self.windowObserver = nil
    }
}
