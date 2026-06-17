//  OpenNOW
//
//  Created by OpenCode on 6/16/26.
//

import Foundation
import OpenNOWGameServices
import SwiftUI
import WebRTCMedia

typealias WebRTCMediaStreamCompletion = @MainActor @Sendable (_ success: Bool, _ message: String, _ report: StreamReport?) -> Void
typealias WebRTCMediaStreamProgressHandler = @MainActor @Sendable (_ progress: StreamProgress) -> Void
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

    @State private var path: WebRTCStreamingPath?
    @State private var hasStarted = false
    @State private var statusMessage = "Starting WebRTC media path..."
    @State private var isStreamReady = false

    var body: some View {
        ZStack {
            NativeWebRTCStreamSurface { nativeView in
                Task { await startIfNeeded(nativeView: nativeView) }
            }
            if !isStreamReady {
                LinearGradient(
                    colors: [Color(red: 0.02, green: 0.025, blue: 0.03), Color(red: 0.08, green: 0.10, blue: 0.09)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(spacing: 18) {
                    Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(statusMessage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                    ProgressView()
                        .controlSize(.large)
                }
                .padding(32)
            }
        }
        .ignoresSafeArea()
        .onDisappear {
            OpenNOWStreamLifecycle.deactivate(configuration.id)
            if let path {
                Task { try? await path.stop(reason: .userRequested, message: "Stream view closed.") }
            }
        }
    }

    @MainActor
    private func startIfNeeded(nativeView: NativeWebRTCStreamView) async {
        guard !hasStarted else { return }
        hasStarted = true
        OpenNOWStreamLifecycle.activate(configuration.id)

        let coordinator = OpenNOWStreamSessionCoordinator()
        let path = WebRTCStreamingPath(
            sessionProvider: coordinator,
            transport: NativeWebRTCTransport(nativeView: nativeView),
            signaling: coordinator
        )
        nativeView.onInputEvent = { event in
            Task { try? await path.send(event) }
        }
        self.path = path

        do {
            _ = try await path.start(configuration: configuration) { progress in
                await MainActor.run {
                    statusMessage = progress.message
                    isStreamReady = progress.isReady
                    onProgress?(progress)
                }
            }
        } catch {
            let message = Self.message(for: error)
            statusMessage = message
            let report = StreamReport(
                title: configuration.title,
                success: false,
                reason: .failed,
                message: message,
                durationSeconds: 0,
                metadata: ["applicationID": configuration.applicationID]
            )
            onEnd(false, message, report)
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}

private struct NativeWebRTCStreamSurface: NSViewRepresentable {
    let onResolve: @MainActor (NativeWebRTCStreamView) -> Void

    func makeNSView(context: Context) -> NativeWebRTCStreamView {
        let view = NativeWebRTCStreamView(frame: .zero)
        onResolve(view)
        return view
    }

    func updateNSView(_ nsView: NativeWebRTCStreamView, context: Context) {}
}
