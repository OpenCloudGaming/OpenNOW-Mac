import Combine
import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    /// The AUDIO panel's microphone status line, composed by the model so the view and its tests
    /// read one definition of it.
    var nativeMicrophoneStatusText: String { model.microphoneStatusText }
}
