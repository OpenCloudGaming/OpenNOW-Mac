//  The preconditions Game Mode is gated on, and the telemetry that records them with the
//  full-screen entry.
//
//  macOS exposes no public API that reads whether Game Mode is on - every `GameMode` symbol in the
//  SDK is either unrelated or exported-but-undeclared SPI - so nothing here ever reports a
//  `gameMode` boolean. What it reports is eligibility: the plist key, the app category, and the
//  process state the OS requires, plus whether the transition actually landed. Full screen is
//  necessary but not sufficient, and the user can disable Game Mode while full screen, so
//  `enteredFullScreen` must never be read as Game Mode being on.
//

import AppKit
import Foundation

/// The four conditions macOS checks before it will offer Game Mode, limited to the ones this
/// process can observe. Read at the moment the transition lands; `isFrontmost` is deliberately not
/// captured when the request is issued, because activation is not synchronous.
struct OPNStreamGameModePreconditions: Equatable, Sendable {
    let isGameModeKeyDeclared: Bool
    let applicationCategoryType: String
    let isFrontmost: Bool
    let isAppleSilicon: Bool

    /// Injectable so both the bundle read and the process state are assertable without a window
    /// server. `supportsGameModeKey` is the telemetry attribute name Apple's own documentation uses
    /// for the plist key, not this property's name.
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
            isAppleSilicon: hostIsAppleSilicon
        )
    }

    /// What every full-screen entry event reports. Never a `gameMode` boolean: macOS exposes no
    /// public API that reads Game Mode's state, so eligibility is all that can be claimed.
    var telemetryAttributes: [String: String] {
        [
            "supportsGameModeKey": String(isGameModeKeyDeclared),
            "applicationCategoryType": applicationCategoryType,
            "isFrontmost": String(isFrontmost),
            "isAppleSilicon": String(isAppleSilicon),
        ]
    }

    static var hostIsAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
}

enum OPNStreamFullScreenTelemetry {
    /// Fires when the transition lands, not when it is requested, so `enteredFullScreen` records
    /// the window's real state.
    static let successEventName = "nvst.ui.fullscreen.sessionReady"
    static let failureEventName = "nvst.ui.fullscreen.sessionReady.failed"

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
