//  The preconditions Game Mode is gated on, reported alongside the full-screen entry.
//
//  macOS exposes no public API that reads whether Game Mode is on - every `GameMode` symbol in the
//  SDK is unrelated or exported-but-undeclared SPI - so nothing here reports a state. Eligibility,
//  never `enteredFullScreen`, is the only claim the app can honestly make.
//

import AppKit
import Foundation

/// The four conditions macOS checks before it will offer Game Mode, limited to the ones this process
/// can observe. Read at the moment the transition lands, because activation is not synchronous.
struct OPNStreamGameModePreconditions: Sendable {
    let isGameModeKeyDeclared: Bool
    let applicationCategoryType: String
    let isFrontmost: Bool
    let isAppleSilicon: Bool

    /// Injectable, so both the bundle read and the process state are assertable without a window
    /// server. `supportsGameModeKey` is Apple's own attribute name for the plist key.
    static func read(
        infoDictionary: [String: Any]?,
        isFrontmost: Bool,
        isAppleSilicon: Bool
    ) -> OPNStreamGameModePreconditions {
        OPNStreamGameModePreconditions(
            isGameModeKeyDeclared: infoDictionary?["LSSupportsGameMode"] as? Bool ?? false,
            applicationCategoryType: infoDictionary?["LSApplicationCategoryType"] as? String ?? "",
            isFrontmost: isFrontmost,
            isAppleSilicon: isAppleSilicon
        )
    }

    @MainActor
    static func current() -> OPNStreamGameModePreconditions {
        read(
            infoDictionary: Bundle.main.infoDictionary,
            isFrontmost: NSApplication.shared.isActive,
            isAppleSilicon: isHostAppleSilicon
        )
    }

    static var isHostAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// What every full-screen entry event reports, never a `gameMode` boolean.
    var telemetryAttributes: [String: String] {
        [
            "supportsGameModeKey": String(isGameModeKeyDeclared),
            "applicationCategoryType": applicationCategoryType,
            "isFrontmost": String(isFrontmost),
            "isAppleSilicon": String(isAppleSilicon),
        ]
    }
}

enum OPNStreamFullScreenTelemetry {
    /// Fires when the transition lands, so `enteredFullScreen` records the window's real state.
    static let successEventName = "nvst.ui.fullscreen.sessionReady"
    static let failureEventName = "nvst.ui.fullscreen.sessionReady.failed"
    static let toggleEventName = "nvst.ui.fullscreen.toggle"

    static func successAttributes(
        applicationID: String,
        launchMode: String,
        enteredFullScreen: Bool,
        preconditions: OPNStreamGameModePreconditions
    ) -> [String: String] {
        var attributes = preconditions.telemetryAttributes
        attributes["applicationID"] = applicationID
        attributes["launchMode"] = launchMode
        attributes["enteredFullScreen"] = String(enteredFullScreen)
        return attributes
    }

    static func failureAttributes(
        applicationID: String,
        reason: OPNStreamFullScreenEntry.FailureReason,
        attemptCount: Int,
        elapsedMs: Int
    ) -> [String: String] {
        [
            "applicationID": applicationID,
            "reason": reason.rawValue,
            "attemptCount": String(attemptCount),
            "elapsedMs": String(elapsedMs),
        ]
    }

    /// The manual toggle is the path Game Mode engages on for every mode but Full Screen, so
    /// eligibility is recorded there too - but only when entering.
    static func toggleAttributes(
        applicationID: String,
        isEnteringFullScreen: Bool,
        preconditions: OPNStreamGameModePreconditions
    ) -> [String: String] {
        var attributes = ["applicationID": applicationID, "fullScreen": String(isEnteringFullScreen)]
        guard isEnteringFullScreen else { return attributes }
        attributes.merge(preconditions.telemetryAttributes) { current, _ in current }
        return attributes
    }

    static func captureSuccess(
        applicationID: String,
        launchMode: String,
        enteredFullScreen: Bool,
        preconditions: OPNStreamGameModePreconditions
    ) {
        OPNStreamTelemetry.capture(
            successEventName,
            level: .info,
            message: "Native NVST stream entered full screen after the session connected.",
            attributes: successAttributes(
                applicationID: applicationID,
                launchMode: launchMode,
                enteredFullScreen: enteredFullScreen,
                preconditions: preconditions
            )
        )
    }

    static func captureFailure(
        applicationID: String,
        reason: OPNStreamFullScreenEntry.FailureReason,
        attemptCount: Int,
        elapsedMs: Int
    ) {
        OPNStreamTelemetry.capture(
            failureEventName,
            level: .warning,
            message: "Native NVST stream could not enter full screen after the session connected.",
            attributes: failureAttributes(
                applicationID: applicationID,
                reason: reason,
                attemptCount: attemptCount,
                elapsedMs: elapsedMs
            )
        )
    }
}
