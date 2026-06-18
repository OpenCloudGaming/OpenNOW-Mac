import AppKit
import Foundation
import SwiftUI

public typealias WebRTCMediaStreamProgressCallback = @MainActor @Sendable (_ progress: StreamProgress) -> Void
public typealias WebRTCMediaStreamEndCallback = @MainActor @Sendable (_ success: Bool, _ message: String, _ report: StreamReport?) -> Void

@MainActor
public struct WebRTCMediaStreamSurface: View {
    private let configuration: StreamLaunchConfiguration
    private let sessionProvider: any StreamSessionProvider
    private let signaling: (any StreamSignalingChannel)?
    private let onProgress: WebRTCMediaStreamProgressCallback?
    private let onEnd: WebRTCMediaStreamEndCallback

    @State private var path: WebRTCStreamingPath?
    @State private var transport: NativeWebRTCTransport?
    @State private var hasStarted = false
    @State private var isStreamReady = false
    @State private var statusMessage = "Starting WebRTC media path..."
    @State private var pointerLocked = false
    @State private var statsVisible = false
    @State private var sidebarVisible = true
    @State private var quitMenuVisible = false
    @State private var isEndingStream = false
    @State private var didEndStream = false
    @State private var latestStats: OPNStreamStatsSnapshot?
    @State private var statsTask: Task<Void, Never>?
    @State private var nativeView: NativeWebRTCStreamView?
    @State private var pendingApplicationQuitCompletion: WebRTCMediaStreamQuitDecisionHandler?
    @State private var runtimeSettings = StreamRuntimeSettings()

    public init(configuration: StreamLaunchConfiguration,
                sessionProvider: any StreamSessionProvider,
                signaling: (any StreamSignalingChannel)? = nil,
                onProgress: WebRTCMediaStreamProgressCallback? = nil,
                onEnd: @escaping WebRTCMediaStreamEndCallback) {
        self.configuration = configuration
        self.sessionProvider = sessionProvider
        self.signaling = signaling
        self.onProgress = onProgress
        self.onEnd = onEnd
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            NativeWebRTCStreamSurface { view in
                nativeView = view
                view.onPointerLockChanged = { locked in pointerLocked = locked }
                view.onCommand = { command in
                    handle(command)
                }
                Task { await startIfNeeded(nativeView: view) }
            }
            if !isStreamReady { launchOverlay }
            if statsVisible { statsHUD }
            if sidebarVisible { sidebar }
            if quitMenuVisible { quitMenu }
            if pointerLocked { pointerLockBadge }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear { registerStreamLifecycle() }
        .onDisappear { stopStream() }
    }

    private var launchOverlay: some View {
        LinearGradient(
            colors: [Color(red: 0.015, green: 0.02, blue: 0.018), Color(red: 0.05, green: 0.08, blue: 0.055)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            VStack(spacing: 18) {
                Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(statusMessage)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.67, green: 1.0, blue: 0.36).opacity(0.84))
                ProgressView()
                    .controlSize(.large)
                    .tint(Color(red: 0.56, green: 1.0, blue: 0.25))
            }
            .padding(36)
            .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        }
    }

    private var statsHUD: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STREAM STATS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.61, green: 1.0, blue: 0.22))
            statsRow("Latency", formatted(latestStats?.latencyMs, suffix: " ms"))
            statsRow("Jitter", formatted(latestStats?.jitterMs, suffix: " ms"))
            statsRow("Bitrate", formatted(latestStats?.inboundBitrateMbps, suffix: " Mbps"))
            statsRow("Loss", formatted(latestStats?.packetLossPercent, suffix: "%"))
            statsRow("FPS", formatted(latestStats?.renderFps, suffix: ""))
            statsRow("Codec", latestStats?.codec.isEmpty == false ? latestStats?.codec ?? "-" : "-")
            statsRow("Resolution", latestStats?.resolution.isEmpty == false ? latestStats?.resolution ?? "-" : "-")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(14)
        .frame(width: 228, alignment: .leading)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(red: 0.61, green: 1.0, blue: 0.22).opacity(0.28), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
        .padding(.top, 22)
        .padding(.trailing, sidebarVisible ? 102 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            Text("GFN")
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.61, green: 1.0, blue: 0.22))
                .padding(.bottom, 6)
            sidebarButton(systemName: pointerLocked ? "cursorarrow.rays" : "cursorarrow", title: pointerLocked ? "Unlock" : "Lock") {
                nativeView?.setPointerLocked(!pointerLocked)
            }
            sidebarButton(systemName: "waveform.path.ecg", title: "Stats") {
                statsVisible.toggle()
            }
            sidebarButton(systemName: "gamecontroller.fill", title: "Pad") {
                WebRTCMediaTelemetry.capture("webrtc.ui.gamepad.status", level: .info, message: "Gamepad status requested.", attributes: ["connected": String(NativeWebRTCGamepadMonitor.connectedGamepadCount())])
            }
            sidebarButton(systemName: "power", title: "Quit") {
                showQuitMenu()
            }
            sidebarButton(systemName: "xmark", title: "Close") {
                sidebarVisible = false
            }
        }
        .padding(10)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .padding(.top, 22)
        .padding(.trailing, 18)
    }

    private var quitMenu: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.54))
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Text("STREAM PAUSED")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color(red: 0.61, green: 1.0, blue: 0.22))
                Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Resume the stream or quit the current session. Remote input is paused while this menu is open.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                HStack(spacing: 12) {
                    Button(action: resumeFromQuitMenu) {
                        Text("Resume")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .frame(width: 150, height: 44)
                            .background(Color(red: 0.61, green: 1.0, blue: 0.22), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button(action: quitStreamFromMenu) {
                        Text(isEndingStream ? "Quitting..." : "Quit Stream")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 150, height: 44)
                            .background(.white.opacity(0.11), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isEndingStream)
                }
            }
            .padding(32)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color(red: 0.61, green: 1.0, blue: 0.22).opacity(0.26), lineWidth: 1))
            .shadow(color: .black.opacity(0.62), radius: 42, x: 0, y: 20)
        }
    }

    private var pointerLockBadge: some View {
        Text("POINTER LOCKED  ESC TO RELEASE")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(red: 0.61, green: 1.0, blue: 0.22), in: Capsule())
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func sidebarButton(systemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: 58, height: 54)
            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func statsRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.58))
            Spacer()
            Text(value).foregroundStyle(.white.opacity(0.94))
        }
    }

    private func formatted(_ value: Double?, suffix: String) -> String {
        guard let value, value >= 0 else { return "-" }
        return String(format: "%.1f%@", value, suffix)
    }

    private func startIfNeeded(nativeView: NativeWebRTCStreamView) async {
        guard !hasStarted else { return }
        hasStarted = true
        let transport = NativeWebRTCTransport(nativeView: nativeView)
        let path = WebRTCStreamingPath(sessionProvider: sessionProvider, transport: transport, signaling: signaling)
        transport.onEnded = { message in
            handleTransportEnded(message: message)
        }
        nativeView.onInputEvent = { event in
            Task {
                let action = await MainActor.run { inputAction(for: event) }
                switch action {
                case .send:
                    break
                case .drop:
                    return
                case .setMicrophone(let enabled):
                    transport.setMicrophoneEnabled(enabled)
                    return
                }
                try? await path.send(event)
            }
        }
        self.transport = transport
        self.path = path
        startStatsPolling(transport: transport)
        do {
            let session = try await path.start(configuration: configuration) { progress in
                await MainActor.run {
                    statusMessage = progress.message
                    isStreamReady = progress.isReady
                    onProgress?(progress)
                }
            }
            await MainActor.run {
                runtimeSettings = StreamRuntimeSettings(json: session.metadata["settings"])
                nativeView.setStreamContentSize(width: runtimeSettings.resolutionWidth, height: runtimeSettings.resolutionHeight)
            }
        } catch {
            let message = Self.message(for: error)
            statusMessage = message
            onEnd(false, message, StreamReport(title: configuration.title, success: false, reason: .failed, message: message, durationSeconds: 0, metadata: ["applicationID": configuration.applicationID]))
        }
    }

    private func startStatsPolling(transport: NativeWebRTCTransport) {
        statsTask?.cancel()
        statsTask = Task {
            for await snapshot in transport.statsSnapshots(intervalSeconds: 1) {
                latestStats = snapshot
            }
        }
    }

    private func inputAction(for event: UserInputEvent) -> StreamInputAction {
        guard !quitMenuVisible, !isEndingStream else { return .drop }
        guard shouldAcceptInputWhenInactive() else { return runtimeSettings.microphoneMode == "push-to-talk" ? .setMicrophone(false) : .drop }
        if let keyboard = keyboardEvent(from: event), let microphoneAction = microphoneAction(for: keyboard) { return microphoneAction }
        if isMouseEvent(event), !runtimeSettings.directMouseInput { return .drop }
        return .send
    }

    private func shouldAcceptInputWhenInactive() -> Bool {
        guard runtimeSettings.suppressInputWhenInactive else { return true }
        guard let nativeView else { return false }
        return nativeView.window?.isKeyWindow == true && NSApplication.shared.isActive
    }

    private func microphoneAction(for keyboard: KeyboardEvent) -> StreamInputAction? {
        guard runtimeSettings.microphoneMode == "push-to-talk" else { return nil }
        guard Int(keyboard.keyCode) == runtimeSettings.microphonePushToTalkKeyCode else { return nil }
        let configuredModifiers = UInt16(truncatingIfNeeded: runtimeSettings.microphonePushToTalkModifierMask) & Self.pushToTalkModifierMask
        guard keyboard.modifiers.rawValue & Self.pushToTalkModifierMask == configuredModifiers else { return nil }
        return .setMicrophone(keyboard.isPressed)
    }

    private func keyboardEvent(from event: UserInputEvent) -> KeyboardEvent? {
        if case .keyboard(let keyboard) = event { return keyboard }
        return nil
    }

    private func isMouseEvent(_ event: UserInputEvent) -> Bool {
        if case .mouse = event { return true }
        return false
    }

    private func handle(_ command: WebRTCMediaStreamCommand) {
        switch command {
        case .toggleStatsHUD:
            statsVisible.toggle()
            WebRTCMediaTelemetry.capture("webrtc.ui.stats.toggle", level: .info, message: statsVisible ? "Stats HUD shown." : "Stats HUD hidden.", attributes: ["visible": String(statsVisible)])
        case .toggleSidebar:
            sidebarVisible.toggle()
            WebRTCMediaTelemetry.capture("webrtc.ui.sidebar.toggle", level: .info, message: sidebarVisible ? "Sidebar shown." : "Sidebar hidden.", attributes: ["visible": String(sidebarVisible)])
        case .showQuitMenu:
            showQuitMenu()
        }
    }

    private func registerStreamLifecycle() {
        WebRTCMediaStreamLifecycle.activate(configuration.id) { completion in
            showQuitMenu(completion: completion)
            return true
        }
    }

    private func showQuitMenu(completion: WebRTCMediaStreamQuitDecisionHandler? = nil) {
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = completion
        nativeView?.setPointerLocked(false)
        transport?.setMicrophoneEnabled(false)
        quitMenuVisible = true
        WebRTCMediaTelemetry.capture("webrtc.ui.quit_menu.show", level: .info, message: "Stream quit menu shown.", attributes: ["applicationID": configuration.applicationID])
    }

    private func resumeFromQuitMenu() {
        quitMenuVisible = false
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = nil
        WebRTCMediaTelemetry.capture("webrtc.ui.quit_menu.resume", level: .info, message: "Stream resumed from quit menu.", attributes: ["applicationID": configuration.applicationID])
    }

    private func quitStreamFromMenu() {
        guard !isEndingStream else { return }
        isEndingStream = true
        quitMenuVisible = false
        let completion = pendingApplicationQuitCompletion
        pendingApplicationQuitCompletion = nil
        nativeView?.setPointerLocked(false)
        WebRTCMediaTelemetry.capture("webrtc.ui.quit_menu.quit_stream", level: .info, message: "Stream quit requested from quit menu.", attributes: ["applicationID": configuration.applicationID])
        Task {
            let report = await finishStream(reason: .userRequested, message: "Stream ended by user.")
            await MainActor.run {
                completion?(false)
                onEnd(report.success, report.message, report)
            }
        }
    }

    private func handleTransportEnded(message: String) {
        guard !didEndStream else { return }
        isEndingStream = true
        quitMenuVisible = false
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = nil
        nativeView?.setPointerLocked(false)
        transport?.setMicrophoneEnabled(false)
        Task {
            let report = await finishStream(reason: .remoteEnded, message: message.isEmpty ? "Stream ended." : message)
            await MainActor.run { onEnd(report.success, report.message, report) }
        }
    }

    private func finishStream(reason: StreamEndReason, message: String) async -> StreamReport {
        let fallbackReport = StreamReport(title: configuration.title, success: reason != .failed, reason: reason, message: message, durationSeconds: 0, metadata: ["applicationID": configuration.applicationID])
        let shouldFinish = await MainActor.run {
            guard !didEndStream else { return false }
            didEndStream = true
            return true
        }
        guard shouldFinish else { return fallbackReport }
        guard let path else { return fallbackReport }
        do {
            return try await path.stop(reason: reason, message: message)
        } catch {
            return StreamReport(title: configuration.title, success: false, reason: .failed, message: Self.message(for: error), durationSeconds: 0, metadata: ["applicationID": configuration.applicationID])
        }
    }

    private func stopStream() {
        WebRTCMediaStreamLifecycle.deactivate(configuration.id)
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = nil
        statsTask?.cancel()
        statsTask = nil
        nativeView?.setPointerLocked(false)
        transport?.setMicrophoneEnabled(false)
        guard !didEndStream else { return }
        didEndStream = true
        if let path { Task { try? await path.stop(reason: .userRequested, message: "Stream view closed.") } }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription
    }

    private static let pushToTalkModifierMask = KeyboardModifiers.shift.rawValue | KeyboardModifiers.control.rawValue | KeyboardModifiers.option.rawValue | KeyboardModifiers.command.rawValue | KeyboardModifiers.capsLock.rawValue
}

private enum StreamInputAction {
    case send
    case drop
    case setMicrophone(Bool)
}

private struct StreamRuntimeSettings: Equatable {
    var resolutionWidth = 1920
    var resolutionHeight = 1080
    var microphoneMode = "disabled"
    var microphonePushToTalkKeyCode = 9
    var microphonePushToTalkModifierMask = 0
    var suppressInputWhenInactive = true
    var directMouseInput = true

    init() {}

    init(json: String?) {
        guard let json,
              let data = json.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let resolution = Self.resolution(Self.string(dictionary["resolution"], fallback: "1920x1080"))
        resolutionWidth = resolution.width
        resolutionHeight = resolution.height
        microphoneMode = Self.string(dictionary["microphoneMode"], fallback: "disabled")
        microphonePushToTalkKeyCode = Self.int(dictionary["microphonePushToTalkKeyCode"], fallback: 9)
        microphonePushToTalkModifierMask = Self.int(dictionary["microphonePushToTalkModifierMask"])
        suppressInputWhenInactive = Self.bool(dictionary["suppressInputWhenInactive"], fallback: true)
        directMouseInput = Self.bool(dictionary["directMouseInput"], fallback: true)
    }

    private static func string(_ value: Any?, fallback: String = "") -> String {
        if let value = value as? String { return value.isEmpty ? fallback : value }
        if let value = value as? NSString { let string = value as String; return string.isEmpty ? fallback : string }
        if let value = value as? NSNumber { return value.stringValue }
        return fallback
    }

    private static func int(_ value: Any?, fallback: Int = 0) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? fallback }
        return fallback
    }

    private static func bool(_ value: Any?, fallback: Bool = false) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame }
        return fallback
    }

    private static func resolution(_ value: String) -> (width: Int, height: Int) {
        let parts = value.split(separator: "x").compactMap { Int($0) }
        return (max(1, parts.first ?? 1920), max(1, parts.count > 1 ? parts[1] : 1080))
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
