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
}
