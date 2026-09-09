import Combine
import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    var nativeMicrophoneStatusText: String {
        guard model.microphoneAvailable else { return "Disabled" }
        if model.microphoneMode == "push-to-talk" { return model.microphoneEnabled ? "PTT Active" : "PTT Ready" }
        if model.microphoneMode == "voice-activity", model.microphoneEnabled { return "Voice Activity" }
        return model.microphoneEnabled ? "On" : "Muted"
    }

    func nativeSessionLimitText(at date: Date) -> String {
        guard let sessionLimit = model.sessionLimit else { return "Unlimited" }
        let remainingSeconds = sessionLimit.remainingSeconds(at: date)
        return String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    func nativeSessionLimitIsHealthy(at date: Date) -> Bool {
        guard let sessionLimit = model.sessionLimit else { return true }
        return sessionLimit.remainingSeconds(at: date) > 300
    }
}
