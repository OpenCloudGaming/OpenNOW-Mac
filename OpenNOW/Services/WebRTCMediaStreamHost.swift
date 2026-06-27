//  OpenNOW
//
//  Created by OpenCode on 6/16/26.
//

import Foundation
import OpenNOWGameServices
import OpenNOWTwitch
import SwiftUI
import WebRTCMedia

typealias WebRTCMediaStreamCompletion = WebRTCMediaStreamEndCallback
typealias WebRTCMediaStreamProgressHandler = WebRTCMediaStreamProgressCallback

struct WebRTCMediaStreamView: View {
    let configuration: StreamLaunchConfiguration
    let onProgress: WebRTCMediaStreamProgressHandler?
    let onEnd: WebRTCMediaStreamCompletion
    @EnvironmentObject private var twitchRealtime: TwitchRealtimeController
    private let coordinator = OpenNOWStreamSessionCoordinator()

    var body: some View {
        WebRTCMediaStreamSurface(
            configuration: configuration,
            sessionProvider: coordinator,
            signaling: coordinator,
            broadcastConfigurationProvider: { title, applicationID, width, height, fps in
                Self.broadcastConfiguration(title: title, applicationID: applicationID, width: width, height: height, fps: fps)
            },
            onBroadcastStart: { title, applicationID in
                await Self.prepareTwitchBroadcast(title: title, applicationID: applicationID)
            },
            onBroadcastLiveVerification: { title, applicationID in
                await Self.verifyTwitchBroadcast(title: title, applicationID: applicationID)
            },
            onStreamMarker: { title, applicationID, description in
                await Self.createTwitchMarker(title: title, applicationID: applicationID, description: description)
            },
            twitchOverlayState: twitchOverlayState,
            onTwitchChatSend: { message in twitchRealtime.sendChatMessage(message) },
            onTwitchHealthRefresh: { await twitchRealtime.refreshHealth() },
            onProgress: { progress in
                onProgress?(progress)
            },
            onEnd: { success, message, report in
                onEnd(success, message, report)
            }
        )
        .onAppear {
            WebRTCMediaTelemetry.configure(sink: OpenNOWWebRTCMediaTelemetrySink())
        }
    }

    private var twitchOverlayState: WebRTCMediaTwitchOverlayState {
        WebRTCMediaTwitchOverlayState(
            accountSummary: twitchRealtime.health.accountSummary,
            streamKeyAvailable: twitchRealtime.health.streamKeyAvailable,
            chatState: twitchRealtime.chatState.label,
            eventSubState: twitchRealtime.eventSubState.label,
            supportedAlertTypes: twitchRealtime.supportedAlertTypes,
            chatMessages: twitchRealtime.chatMessages.map { message in
                WebRTCMediaTwitchChatMessage(id: message.id, author: message.displayName, text: message.text, timestamp: message.timestamp)
            },
            eventAlerts: twitchRealtime.eventAlerts.map { alert in
                WebRTCMediaTwitchEventAlert(id: alert.id, title: alert.title, message: alert.message, timestamp: alert.timestamp)
            }
        )
    }

    private static func broadcastConfiguration(title: String, applicationID: String, width: Int, height: Int, fps: Int) -> WebRTCLiveBroadcastConfiguration? {
        let preferences = TwitchPreferencesStore.load()
        guard !preferences.ingestURL.isEmpty,
              let streamKey = try? TwitchStreamKeyStore.load(),
              !streamKey.isEmpty else { return nil }
        let size = broadcastSize(width: width, height: height, targetHeight: preferences.resolution.targetHeight)
        return WebRTCLiveBroadcastConfiguration(
            title: title,
            applicationID: applicationID,
            rtmpURL: preferences.ingestURL,
            streamKey: streamKey,
            width: size.width,
            height: size.height,
            fps: min(fps, preferences.fps),
            videoBitrateKbps: preferences.videoBitrateKbps,
            audioBitrateKbps: preferences.audioBitrateKbps,
            enhancedVideoEnabled: preferences.useEnhancedVideo
        )
    }

    private static func broadcastSize(width: Int, height: Int, targetHeight: Int) -> (width: Int, height: Int) {
        guard targetHeight > 0, width > 0, height > 0, height > targetHeight else { return (max(1, width), max(1, height)) }
        let scaledWidth = Int((Double(width) * Double(targetHeight) / Double(height)).rounded())
        return (max(1, scaledWidth - scaledWidth % 2), max(1, targetHeight - targetHeight % 2))
    }

    private static func prepareTwitchBroadcast(title: String, applicationID: String) async -> String? {
        guard (try? TwitchTokenStore.load()) != nil else { return nil }
        do {
            return try await TwitchOAuthService.prepareBroadcast(clientID: TwitchOAuthService.clientID, title: title, applicationID: applicationID)
        } catch {
            return message(for: error)
        }
    }

    private static func verifyTwitchBroadcast(title: String, applicationID: String) async -> WebRTCMediaBroadcastLiveVerificationResult {
        guard (try? TwitchTokenStore.load()) != nil else { return .unavailable("Connect Twitch OAuth to verify live status with Twitch API.") }
        do {
            return .verified(try await TwitchOAuthService.verifyLiveBroadcast(clientID: TwitchOAuthService.clientID))
        } catch TwitchServiceError.streamNotLive(let message) {
            return .notLive(message)
        } catch {
            return .unavailable("Twitch API verification failed: \(message(for: error))")
        }
    }

    private static func createTwitchMarker(title: String, applicationID: String, description: String) async -> String {
        guard (try? TwitchTokenStore.load()) != nil else { return "Connect Twitch OAuth to create markers." }
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (title.isEmpty ? "OpenNOW stream marker" : title) : description
        do {
            return try await TwitchOAuthService.createStreamMarker(clientID: TwitchOAuthService.clientID, description: description)
        } catch {
            return message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription.isEmpty ? "Twitch API request failed." : error.localizedDescription
    }
}
