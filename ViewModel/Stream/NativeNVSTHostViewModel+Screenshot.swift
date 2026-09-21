//  Saving the current stream frame on the native NVST path: the render, the file, and the transient
//  message the HUD shows for each outcome.
//

import Foundation

@MainActor
extension NativeNVSTHostViewModel {

    /// Renders the next decoded frame and files it. Guarded so a held shortcut or a double press
    /// cannot start a second capture while the first is still rendering or writing.
    func takeNativeScreenshot() {
        guard sidebarCapabilities.supports(.screenshot) else { return }
        guard isConnected, !isEnding, !didEnd, let path else { return }
        guard screenshotTask == nil else { return }
        screenshotTask = Task { @MainActor [weak self] in
            defer { self?.screenshotTask = nil }
            guard let self else { return }
            guard let image = await path.takeScreenshot() else {
                self.showNativeTransientStreamMessage("Screenshot Unavailable")
                OPNStreamTelemetry.capture("nvst.ui.screenshot.unavailable", level: .warning, message: "Native NVST screenshot requested before a frame was available.", attributes: ["applicationID": self.configuration.applicationID])
                return
            }
            do {
                let screenshot = try StreamScreenshotLibrary.save(
                    image,
                    title: self.configuration.title,
                    applicationID: self.configuration.applicationID
                )
                self.showNativeTransientStreamMessage("Screenshot Saved")
                OPNStreamTelemetry.capture("nvst.ui.screenshot.saved", level: .info, message: "Native NVST screenshot saved.", attributes: [
                    "applicationID": self.configuration.applicationID,
                    "resolution": "\(screenshot.width)x\(screenshot.height)",
                ])
            } catch {
                self.showNativeTransientStreamMessage("Screenshot Failed")
                OPNStreamTelemetry.capture("nvst.ui.screenshot.failed", level: .error, message: error.localizedDescription, attributes: ["applicationID": self.configuration.applicationID])
            }
        }
    }
}
