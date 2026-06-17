//  OpenNOW
//
//  Created by OpenCode on 6/16/26.
//

import Foundation
import OpenNOWGameServices
import SwiftUI
import WebRTCMedia

typealias WebRTCMediaStreamCompletion = WebRTCMediaStreamEndCallback
typealias WebRTCMediaStreamProgressHandler = WebRTCMediaStreamProgressCallback
typealias WebRTCMediaStreamQuitDecisionHandler = @MainActor @Sendable (_ shouldTerminateApplication: Bool) -> Void

@MainActor
enum OpenNOWStreamLifecycle {
    private static var activeStreamIDs: Set<UUID> = []

    static var hasActiveStream: Bool {
        !activeStreamIDs.isEmpty
    }

    static func requestApplicationQuitDecision(completion: @escaping WebRTCMediaStreamQuitDecisionHandler) -> Bool {
        guard hasActiveStream else { return false }
        completion(true)
        return true
    }

    static func activate(_ id: UUID) {
        activeStreamIDs.insert(id)
    }

    static func deactivate(_ id: UUID) {
        activeStreamIDs.remove(id)
    }
}

struct WebRTCMediaStreamView: View {
    let configuration: StreamLaunchConfiguration
    let onProgress: WebRTCMediaStreamProgressHandler?
    let onEnd: WebRTCMediaStreamCompletion
    private let coordinator = OpenNOWStreamSessionCoordinator()

    var body: some View {
        WebRTCMediaStreamSurface(
            configuration: configuration,
            sessionProvider: coordinator,
            signaling: coordinator,
            onProgress: { progress in
                onProgress?(progress)
            },
            onEnd: { success, message, report in
                onEnd(success, message, report)
            }
        )
        .onAppear {
            WebRTCMediaTelemetry.configure(sink: OpenNOWWebRTCMediaTelemetrySink())
            OpenNOWStreamLifecycle.activate(configuration.id)
        }
        .onDisappear {
            OpenNOWStreamLifecycle.deactivate(configuration.id)
        }
    }
}
