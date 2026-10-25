// swiftlint:disable:next no_appkit_in_view_model
import AppKit
import Foundation

@MainActor
extension NativeNVSTHostViewModel {
    func togglePictureInPicture() {
        guard let window = nativeView?.window as? OPNStreamWindow, !isEnding, !didEnd else { return }
        if window.isPictureInPicturePending {
            OPNStreamPictureInPicture.exit(window)
            return
        }
        guard !StreamWindowGeometryGate.shouldDeferGeometryMutation(for: window) else { return }
        switch OPNStreamPictureInPicture.request(
            isPictureInPicture: isPictureInPicture,
            isFullScreen: window.styleMask.contains(.fullScreen),
            isFullScreenTransitioning: isFullScreenTransitioning
        ) {
        case .leave: leavePictureInPicture(window)
        case .leaveFullScreenThenEnter:
            let requestID = UUID()
            window.pictureInPictureRequestID = requestID
            window.layoutMembershipDidChange?()
            leaveFullScreenThenEnterPictureInPicture(window, requestID: requestID, attempt: 0)
        case .enter: enterPictureInPicture(window)
        }
    }

    private func enterPictureInPicture(_ window: OPNStreamWindow) {
        let aspectRatio = CGFloat(OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities()).aspectRatio)
        OPNStreamPictureInPicture.enter(window, aspectRatio: aspectRatio, prepareForEntry: { [weak self, weak window] in
            guard let self, let window, !self.isEnding, !self.didEnd, self.nativeView?.window === window else { return false }
            self.preparePictureInPictureEntry()
            return true
        }, completion: { [weak self] in self?.completePictureInPictureEntry() })
    }

    private func preparePictureInPictureEntry() {
        unifiedHUDVisible = false
        isShortcutsHelpVisible = false
        isHUDCustomizeVisible = false
        nativeStatsVisible = false
        closeHUDDropdown()
        hudFocusID = nil
        isHUDGamepadFocusVisible = false
        if onScreenKeyboardVisible { setOnScreenKeyboardVisible(false) }
        nativeView?.isPictureInPictureMode = true
        nativeView?.remoteInputEnabled = networkPathAvailable
        nativeView?.restoreInputFocus()
    }

    private func completePictureInPictureEntry() {
        isPictureInPicture = true
        showNativeTransientStreamMessage("Picture in Picture")
        OPNStreamTelemetry.capture("nvst.ui.pip.enter", level: .info, message: "Native NVST stream entered Picture in Picture.", attributes: ["applicationID": configuration.applicationID])
    }

    private func leavePictureInPicture(_ window: OPNStreamWindow) {
        OPNStreamPictureInPicture.exit(window)
        isPictureInPicture = false
        nativeView?.isPictureInPictureMode = false
        nativeView?.remoteInputEnabled = networkPathAvailable
        nativeView?.restoreInputFocus()
        OPNStreamTelemetry.capture("nvst.ui.pip.exit", level: .info, message: "Native NVST stream left Picture in Picture.", attributes: ["applicationID": configuration.applicationID])
    }

    private func leaveFullScreenThenEnterPictureInPicture(_ window: OPNStreamWindow, requestID: UUID, attempt: Int) {
        guard attempt < Self.sessionReadyFullScreenAttemptLimit else {
            if window.pictureInPictureRequestID == requestID {
                window.pictureInPictureRequestID = nil
                window.layoutMembershipDidChange?()
            }
            return
        }
        Task { @MainActor [weak self, weak window] in
            try? await Task.sleep(for: NativeNVSTHostViewModel.sessionReadyFullScreenRetryDelay)
            guard let window, window.pictureInPictureRequestID == requestID else { return }
            guard let self, !self.isEnding, !self.didEnd, !window.isPresentationEnding,
                  self.nativeView?.window === window else {
                window.pictureInPictureRequestID = nil
                window.layoutMembershipDidChange?()
                return
            }
            if self.isFullScreenTransitioning || StreamWindowGeometryGate.shouldDeferGeometryMutation(for: window) {
                self.leaveFullScreenThenEnterPictureInPicture(window, requestID: requestID, attempt: attempt + 1)
                return
            }
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                self.leaveFullScreenThenEnterPictureInPicture(window, requestID: requestID, attempt: attempt + 1)
                return
            }
            self.enterPictureInPicture(window)
        }
    }
}
