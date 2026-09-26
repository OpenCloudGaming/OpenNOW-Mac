//  The native NVST stream session: starting it, tearing it down, and everything the HUD can do to
//  it while it runs - microphone, anti-AFK, pointer lock, video enhancement, stats polling and the
//  network governor.
//
//  All of this was `@State` and `private func` inside `NativeNVSTMediaStreamSurface`, a SwiftUI
//  view: 52 stored properties, 60 methods and 18 task or timer sites owning a live stream session,
//  none of it reachable without rendering the stream.
//
//  Teardown order is load-bearing and was moved verbatim. In particular the Metal view is never
//  hidden before the native session is destroyed - doing so wedges the render loop and deadlocks
//  shutdown - and `didEnd` is a once-guard that must not be reset while a session can still end.
//
//  swiftlint:disable:next no_appkit_in_view_model
import AppKit
import AVFoundation
import Combine
import Foundation
import GameController

/// AppKit is imported deliberately, and is the one exception to the "view models do not import
/// AppKit" rule. `NativeStreamView` *is* the stream: it owns the Metal surface the decoder
/// draws into, the pointer-lock state and the input callbacks. Hiding it behind a protocol would
/// mean a thirty-member pass-through with exactly one implementation - the wrapper layer AGENTS.md
/// rules out - and would not make the session logic any more testable, because every one of those
/// members is a real side effect on a real surface.
@MainActor
final class NativeNVSTHostViewModel: ObservableObject {
    let configuration: StreamLaunchConfiguration
    let sessionProvider: any NativeNVSTSessionProvider
    let preventDisplaySleep: Bool
    let onProgress: StreamProgressHandler?
    let onEnd: StreamCompletionHandler
    let sidebarCapabilities = StreamSidebarCapabilities.nativeNVST

    init(
        configuration: StreamLaunchConfiguration,
        sessionProvider: any NativeNVSTSessionProvider,
        preventDisplaySleep: Bool,
        onProgress: StreamProgressHandler?,
        onEnd: @escaping StreamCompletionHandler
    ) {
        self.configuration = configuration
        self.sessionProvider = sessionProvider
        self.preventDisplaySleep = preventDisplaySleep
        self.onProgress = onProgress
        self.onEnd = onEnd
    }

    @Published var path: NativeNVSTStreamingPath?
    var startTask: Task<Void, Never>?
    var endEventTask: Task<Void, Never>?
    @Published var nativeView: NativeStreamView?
    @Published var loadingStepIndex = -1
    @Published var isConnected = false
    @Published var isEnding = false
    var didEnd = false
    @Published var unifiedHUDVisible = false
    @Published var streamControlsVisible = false
    /// The in-stream shortcut list. Opened by its binding (`⌘/` by default) or the dock footer.
    @Published var isShortcutsHelpVisible = false
    @Published var nativeStatsVisible = false
    /// The overlay's stored shape, chosen in the unified HUD: how much detail it shows and which
    /// corner it occupies. The visible toggle above is per-session; these two persist.
    @Published var statsDetail: StreamStatsDetailLevel = OPNStreamStatsHUDSettings.detailLevel
    @Published var statsPosition: StreamStatsHUDPosition = OPNStreamStatsHUDSettings.position
    /// Which unified-HUD sections the user has folded away. Persisted globally, so a folded section
    /// is folded again the next time any HUD opens.
    @Published var collapsedHUDSections: Set<OPNStreamHUDSection> = OPNStreamHUDSettings.collapsedSections
    /// The order, hidden set, and clock choice the reader customized. All persisted globally.
    @Published var hudSectionOrder: [OPNStreamHUDSection] = OPNStreamHUDSettings.sectionOrder
    @Published var hiddenHUDSections: Set<OPNStreamHUDSection> = OPNStreamHUDSettings.hiddenSections
    @Published var isHUDClockVisible: Bool = OPNStreamHUDSettings.isClockVisible
    /// The dock's layout editor. Opened from the footer; separate from the shortcut list.
    @Published var isHUDCustomizeVisible = false
    @Published var latestNativeStats: NativeNVSTPerformanceSnapshot?
    /// The renderer's view of the same second: surface format, drawable format, EDR, drawn/received.
    @Published var latestRenderDiagnostics: OPNVideoRenderDiagnosticsSnapshot?
    /// True once the inbound bitrate has been low AND the stream frame rate has been falling short
    /// of the negotiated rate for a sustained period. See `NativeNVSTBitrateStarvationTracker`.
    @Published var nativeBitrateStarved = false
    var bitrateStarvation = NativeNVSTBitrateStarvationTracker()
    /// Whether this session found the title rendering 16:9 inside a wider frame, and whether the
    /// launch already requested the 16:9 resolution for it. Both drive the HUD's Resolution note.
    /// When the stream connected, so a session's decode mean is only recorded once it has run long
    /// enough to outweigh the start-up burst.
    var nativeConnectedAt: Date?
    /// The seat's GPU as the official client names it, resolved once per distinct `gpuType`.
    @Published var nativeRigName = ""
    var nativeRigRawName = ""
    var renderTraceCounter = 0
    var nativeStatsTask: Task<Void, Never>?
    var nativeStreamHealth = NativeNVSTStreamHealthMonitor()
    /// Held in a lock-guarded holder rather than directly, so Remote Co-Op guest input can reach the
    /// dispatcher without hopping to this actor. See `NativeNVSTInputDispatcherHolder`.
    let inputDispatcherHolder = NativeNVSTInputDispatcherHolder()
    var inputDispatcher: NativeNVSTInputDispatcher? {
        get { inputDispatcherHolder.dispatcher }
        set { inputDispatcherHolder.dispatcher = newValue }
    }
    @Published var microphoneAvailable = false
    @Published var microphoneEnabled = false
    var microphoneDesiredEnabled = false
    @Published var microphoneMode = "disabled"
    var microphonePendingStates: [Bool] = []
    @Published var microphoneUpdateTask: Task<Void, Never>?
    /// The picker's rows for the HUD's AUDIO panel, read from the same preference Settings writes.
    @Published var microphoneDeviceOptions: [OPNStreamMicrophoneDeviceOption] = [OPNStreamMicrophoneDeviceOption(label: "Default Device", uniqueId: "", automatic: true)]
    /// The saved device is gone and capture fell back. Drives the label and the one-off message.
    @Published var isMicrophoneDeviceFallbackActive = false
    /// The microphone picker's choice for this session, as a UID. Empty is "Default Device".
    @Published var microphoneDeviceUID = ""
    /// A device change in flight, so the open dropdown marks the intended row rather than the one
    /// capture is still on.
    var microphonePendingDeviceUID: String?
    var pendingMicrophoneDeviceUIDs: [String] = []
    /// Whether this seat carries a microphone at all. `.pending` until the bundle is up, so nothing is
    /// greyed out on the strength of a question that has not been answered yet.
    @Published var microphoneTransportAvailability: NativeNVSTMicrophoneAvailability = .pending
    @Published var antiAFKMouseMovementEnabled = false
    /// Local speaker output only - a guest over Remote Co-Op still hears everything regardless, since
    /// the audio relay taps decoded PCM independently of the player this mutes. Exists for testing a
    /// session host and guest side on the same Mac, where both otherwise play the same audio at once.
    @Published var nativeLocalAudioMuted = false
    /// True while `startRemoteCoOpInvite` is building a session. Published so the HUD button follows
    /// it; see `canStartRemoteCoOpInvite`.
    @Published var isStartingRemoteCoOpInvite = false
    var antiAFKMouseMovementTask: Task<Void, Never>?
    var lastAcceptedStreamInputAt = Date()
    @Published var transientStreamMessage = ""
    var transientStreamMessageTask: Task<Void, Never>?
    @Published var pendingApplicationQuitCompletion: StreamSessionQuitDecisionHandler?
    var streamingPerformanceActivity: (any NSObjectProtocol)?
    @Published var sessionLimit: StreamSessionSidebarLimit?
    @Published var remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()

    // MARK: - Remote Co-Op
    //
    // The host half of a Remote Co-Op session. The relays are created here rather than inside the
    // transport so they survive `makeTransport` and can be handed to the peer controller: they are
    // the seam between the NVST decode/audio threads and each guest's WebRTC peer.
    let remoteCoOpHostSession = OPNRemoteCoOpHostSession()
    /// The native transport's per-session media fanout: the source video and PCM audio every native
    /// guest receives. Fed off the same decode/audio taps the recorder and replay buffer are.
    let remoteCoOpNativeBroadcaster = RemoteCoOpNativeMediaBroadcaster()
    /// Browser Co-Op's egress: a WebTransport server that serves a WebCodecs guest, transcoding each
    /// decoded frame to H.264 because the seat's HEVC is not decodable in a browser. Created with the
    /// stream so the decode and audio taps can hold it, and only started while an invite is live.
    lazy var remoteCoOpBrowserEgress: RemoteCoOpBrowserEgress = {
        let adapter = OPNRemoteCoOpBrowserHostAdapter(session: remoteCoOpHostSession) { [holder = inputDispatcherHolder] event in
            // Off the main actor, exactly as the native peer controller forwards guest input: the seat
            // no longer sees a MainActor hop per packet.
            holder.enqueue(event)
        }
        let egress = RemoteCoOpBrowserEgress(host: adapter)
        egress.onState = { message in
            OPNStreamTelemetry.capture("nvst.remote_coop.browser_egress", level: .info, message: message)
        }
        egress.onParticipantsChanged = { [weak self] in
            await self?.remoteCoOpParticipantsDidChange()
        }
        egress.onNeutralInput = { [weak self] events in
            await self?.sendRemoteCoOpNeutralInput(events)
        }
        return egress
    }()
    var remoteCoOpHostCoordinator: OPNRemoteCoOpHostCoordinator?
    var remoteCoOpSignalingSession: (any OPNRemoteCoOpSignalingSession)?
    var remoteCoOpPeerController: OPNRemoteCoOpHostPeerController?
    var remoteCoOpListenTask: Task<Void, Never>?
    /// Set only while OpenNOW is hosting the signaling itself, and stopped with the invite.
    var remoteCoOpEmbeddedServer: OPNRemoteCoOpEmbeddedServer?
    /// The listener native guests connect to. Held so the HUD can show the address a guest joining
    /// over a tunnel has to type, which Bonjour cannot deliver to them.
    var remoteCoOpNativeServer: OPNRemoteCoOpNativeGuestServer?
    @Published var remoteCoOpNativeGuestAddress: String?
    /// What each guest is really receiving, refreshed with the snapshot. A preset is a ceiling, so
    /// this is the only place the difference between "asked for 4K" and "getting 4K" is visible.
    @Published var remoteCoOpDeliveryStats: [UUID: OPNRemoteCoOpGuestDeliveryStats] = [:]
    @Published var remoteCoOpCertificateFingerprint: String?
    @Published var remoteCoOpIsLocallyHosted = false
    @Published var remoteCoOpSnapshot = OPNRemoteCoOpHostSnapshot(preferences: OPNRemoteCoOpPreferencesStore.load(), invite: nil, participants: [])
    @Published var remoteCoOpMessage = ""
    var remoteCoOpNetworkConfiguration = OPNRemoteCoOpNetworkConfiguration(
        transportMode: OPNRemoteCoOpPreferencesStore.load().transportMode,
        latencyMode: OPNRemoteCoOpPreferencesStore.load().latencyMode
    )
    /// The pads physically attached to this Mac. Guest slots are merged with these before the seat
    /// is told the topology, so a guest joining never un-announces the host's own controller.
    var localGamepadTopology = StreamGamepadTopology(playerIndices: [])
    /// What the seat was last told is connected. Diffed on every announce so a pad leaving the set
    /// gets a neutral state before it stops being announced.
    var lastAnnouncedGamepadIndices: Set<Int> = []
    var networkGovernor: NativeNVSTNetworkGovernor?
    var networkPathTask: Task<Void, Never>?
    @Published var networkPathAvailable = true
    @Published var pointerLocked = false
    /// Mirrors the stream window. The style mask only flips once AppKit finishes its transition,
    /// and the green button, ⌃⌘F and the menu bar change it without going through the HUD.
    @Published var streamWindowIsFullScreen = false
    @Published var pillarboxFillModeIndex = 0
    /// The VSync mode this session uses, as the index into `OPNStreamPreferences.vsyncModeOptions`.
    /// Saved on change; the transport applies the client-facing half live and the announce holds
    /// the seat-facing half for the session. Adaptive until the launch profile loads.
    @Published var vsyncModeIndex = NvstVsyncMode.adaptive.rawValue
    @Published var upscalingModeIndex = 0
    @Published var upscalingTargetIndex = 1
    @Published var mouseSensitivityPercent = 100
    /// The mode input is actually travelling in, mirrored off the view so the HUD can report it.
    @Published var mouseInputIsRelative = false
    @Published var cursorPolicyIndex = OPNCursorPolicy.auto.rawValue
    /// The rumble ceiling (`ControllerRumblePreference`), mirrored for the HUD's slider.
    @Published var rumbleIntensityPercent = ControllerRumblePreference.loadIntensityPercent()
    @Published var upscalingSharpness = 10
    @Published var upscalingDenoise = 0
    @Published var nativeStreamResolutionText = ""
    @Published var nativeStreamFrameRateText = ""
    @Published var nativeStreamCodecText = ""
    /// The seat's last `0x010e` HDR mode word (`hdr`, `true-hdr`), empty while the game is SDR or
    /// the seat has said nothing. Informational: the drawable follows the bitstream's own tags.
    @Published var nativeHdrModeText = ""
    /// Rumble commands received from the seat this session, for the HUD's controllers panel.
    @Published var nativeHapticEventCount = 0
    /// True while the path is reconnecting to the same seat after a stall or a network change.
    @Published var isReconnecting = false
    /// One-second stats samples with no frames before the stall watchdog reconnects. Five seconds
    /// of nothing is a dead link, not a quiet scene: a static picture still carries the seat's
    /// keyframe cadence, and the earlier ten-second verdict only ever ended the stream.
    static let stalledSamplesBeforeReconnect = 5
    @Published var controllerBatteries: [ControllerBatteryInfo] = []
    var batteryAlertTracker = ControllerBatteryAlertTracker()
    @Published var showingControllerMapping = false
    @Published var showingControllerOrder = false
    @Published var hudFocusID: String?
    /// Which pad-drivable dropdown is open, if any, and the row the pad stands on inside it. A
    /// dropdown's confirm opens a list instead of firing once, so the gamepad handler owns this.
    @Published var openHUDDropdownID: String?
    @Published var hudDropdownHighlightedItemID: String?
    /// The live capture meter, 0...1, mirrored from the device at 20 Hz for the HUD's AUDIO panel.
    @Published var microphoneLevel: Double = 0
    var hudGamepadTracker = StreamHUDGamepadTracker()
    @Published var recordingStatus = StreamRecordingStatus.idle
    /// The rolling instant-replay window's state, mirrored from the transport.
    @Published var replayBufferState = StreamReplayBufferState()
    var recordingStatusResetTask: Task<Void, Never>?
    /// In flight while a screenshot is being rendered and written, so a held key cannot start a
    /// second capture before the first has landed.
    var screenshotTask: Task<Void, Never>?
    /// The settings the session actually started with, kept because the recording configuration is
    /// built from them (bitrates, fps, resolution) long after `prepareLaunch` returns.
    var resolvedStreamSettings: ResolvedStreamSettings?
    @Published var streamControlsFocusIndex = 0
    @Published var onScreenKeyboardVisible = false
    var restorePointerLockOnKeyboardHide = false
    var restoreManualCaptureOnKeyboardHide = false
    var restoreManualCaptureOnHUDHide = false
    var fullScreenObserverTokens: [any NSObjectProtocol] = []
    /// True between `willEnter`/`willExit` and the matching `did` notification. A second toggle
    /// inside the animation cancels AppKit's transition and strands the window's aspect lock.
    var isFullScreenTransitioning = false
    var fullScreenTransitionWatchdog: Task<Void, Never>?
    /// AppKit's transition animates for well under a second. Past this the transition failed, which
    /// it only reports through delegate callbacks that post no notification.
    static let fullScreenTransitionTimeout = Duration.seconds(2)
    var sessionReadyFullScreenTask: Task<Void, Never>?
    /// One beat after the first frame, so the aspect coordinator has settled the window geometry
    /// before the style mask changes underneath it.
    static let sessionReadyFullScreenRetryDelay = Duration.milliseconds(450)
    static let sessionReadyFullScreenAttemptLimit = 6
    let onScreenKeyboard = StreamOnScreenKeyboardModel()

    func startIfNeeded() {
        guard startTask == nil, path == nil, !didEnd else { return }
        guard let nativeView, Self.nativeVideoSurfaceHandle(for: nativeView) != nil else {
            loadingStepIndex = StreamLaunchStep.checkNetworkRoute.rawValue
            return
        }
        let launch = prepareLaunch(nativeView: nativeView)
        let resolvedStreamSettings = launch.settings
        self.resolvedStreamSettings = resolvedStreamSettings
        let transport = makeTransport(nativeView: nativeView, settings: resolvedStreamSettings)
        let path = NativeNVSTStreamingPath(sessionProvider: sessionProvider, transport: transport, automaticRecovery: .singleAttempt)
        let inputDispatcher = NativeNVSTInputDispatcher { input in
            switch input {
            case .event(let event):
                try? await path.send(event)
            case .absoluteMove(let event):
                try? await path.sendAbsoluteMouseMove(event)
            }
        }
        self.path = path
        self.inputDispatcher = inputDispatcher
        endEventTask = Task {
            let events = await path.endEvents()
            for await report in events {
                guard !Task.isCancelled else { return }
                await MainActor.run { finishOnce(report: report) }
                return
            }
        }
        configureInput(for: nativeView)
        StreamSessionLifecycle.activate(
            configuration.id,
            // All three handlers land in `StreamSessionLifecycle`'s static dictionaries, so all
            // three capture weakly: as a struct these closures held a value copy and retained nothing, but
            // this class owns the Metal surface, the transport and five unbounded tasks.
            //
            // Returning `false` when `self` is gone is load-bearing, not a formality. `true` makes
            // `applicationShouldTerminate` answer `.terminateLater` and wait for a `completion` that
            // a deallocated model can never call - the app would refuse to quit, permanently, with
            // no way out but force-quit.
            quitRequestHandler: { [weak self] completion in
                guard let self else { return false }
                self.showStreamControls(completion: completion)
                return true
            },
            commandHandler: { [weak self] command in self?.handleNativeCommand(command) },
            // `self.inputDispatcher` is the property, not the local the dispatcher was built into:
            // teardown nils the property, so reading it here is what makes a torn-down session
            // refuse an injected event instead of enqueueing into a dead buffer.
            inputInjector: { [weak self] event in
                guard let self, isConnected, !isEnding, !didEnd, let dispatcher = self.inputDispatcher else { return false }
                dispatcher.enqueue(event)
                return true
            }
        )
        runStartTask(path: path,
                     nativeView: nativeView,
                     microphoneConfiguration: launch.microphoneConfiguration,
                     initialMicrophoneEnabled: launch.microphoneConfiguration.initiallyEnabled)
    }

    /// Applies the saved launch profile to this model and returns what starting the stream needs.
    func prepareLaunch(nativeView: NativeStreamView) -> (settings: ResolvedStreamSettings, microphoneConfiguration: NativeNVSTMicrophoneConfiguration) {
        nativeView.remoteInputEnabled = false
        nativeView.setNativeNVSTVideoVisible(false)
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: capabilities)
        let resolvedStreamSettings = StreamSettingsResolver.resolve(
            profile: streamProfile(from: profile),
            capabilities: streamDeviceCapabilities(from: capabilities),
            cloudVariables: streamCloudVariables(from: OPNStreamPreferences.loadCachedCloudVariables())
        )
        microphoneMode = profile.microphoneMode.lowercased()
        let microphoneConfiguration = NativeNVSTMicrophoneConfiguration.settings(volume: profile.microphoneVolume,
                                                                                  mode: microphoneMode,
                                                                                  deviceUniqueID: profile.microphoneDeviceId)
        // The HUD's dropdown reads the same saved choice the Settings picker does, so the two agree
        // on the device even before the stream has reported which one capture settled on.
        microphoneDeviceOptions = OPNStreamPreferences.loadMicrophoneDeviceOptions()
        isMicrophoneDeviceFallbackActive = false
        microphoneDeviceUID = profile.microphoneDeviceId
        microphonePendingDeviceUID = nil
        pendingMicrophoneDeviceUIDs.removeAll()
        microphoneTransportAvailability = .pending
        microphoneLevel = 0
        microphoneAvailable = microphoneConfiguration.captureRequested
        microphoneEnabled = microphoneConfiguration.initiallyEnabled
        microphoneDesiredEnabled = microphoneEnabled
        microphonePendingStates.removeAll()
        antiAFKMouseMovementEnabled = profile.antiAFKMouseMovementEnabled
        vsyncModeIndex = profile.vsyncModeIndex
        networkGovernor = NativeNVSTNetworkGovernor(maximumBitrateKbps: UInt32(resolvedStreamSettings.maxBitrateMbps * 1_000), l4sEnabled: resolvedStreamSettings.enableL4S)
        nativeStreamHealth = NativeNVSTStreamHealthMonitor(stalledSampleLimit: Self.stalledSamplesBeforeReconnect)
        lastAcceptedStreamInputAt = Date()
        beginStreamingPerformanceMode()
        startNetworkPathMonitoring()
        return (resolvedStreamSettings, microphoneConfiguration)
    }

    /// The only transport. The vendored NVIDIA path has been removed; there is no fallback, so a
    /// failure surfaces as a failed stream instead of silently using the old libraries.
    ///
    /// Bifrost-free (no NVIDIA libraries): our own RTSP control plane + raw-SRTP Mjolnir receiver +
    /// VideoToolbox decode, drawn on the shared Metal surface.
    func makeTransport(nativeView: NativeStreamView, settings resolvedStreamSettings: ResolvedStreamSettings) -> any NativeNVSTTransport {
        // Experimental: OpenNOW's own session core (Phase 2) replaces the Geronimo
        // transport when enabled. Geronimo/SDL2 are not loaded; video frames are counted but
        // not decoded until Phase 2C, so the surface stays blank while HUD and input work.
        // Bifrost-free (no NVIDIA libraries): our own RTSP control plane + raw-SRTP Mjolnir
        // receiver + VideoToolbox decode, drawn on the shared Metal surface. Input/audio still
        // need the ICE/DTLS bundle, so this stays opt-in until that lands.
        let bifrostFreeSink = nativeView.attachNvstBifrostFreeRenderer(targetFps: Int32(max(30, resolvedStreamSettings.fps))).frameSink
        // The only transport. The vendored NVIDIA path has been removed; there is no fallback, so
        // a failure surfaces as a failed stream instead of silently using the old libraries.
        // The unified log purges info-level lines within minutes, which has already cost one
        // session's counter timeline mid-investigation; the diagnostic file is the durable copy.
        let diagnosticLog = NvstDiagnosticLog()
        if let logURL = diagnosticLog.url {
            OPNStreamTelemetry.capture("nvst.bifrost_free", level: .info,
                                         message: "NVST diagnostic log at \(logURL.path)")
        }
        let transport: any NativeNVSTTransport = NvstBifrostFreeTransport(
            pixelBufferSink: { pixelBuffer, presentationTime, isKeyframe in
                bifrostFreeSink.render(pixelBuffer: pixelBuffer, presentationTime: presentationTime, isKeyframe: isKeyframe)
            },
            configuredFps: resolvedStreamSettings.fps,
            configuredMaxBitrateKbps: resolvedStreamSettings.maxBitrateMbps * 1_000,
            configuredPrefilterMode: resolvedStreamSettings.prefilterMode,
            configuredPrefilterSharpness: resolvedStreamSettings.prefilterSharpness,
            configuredPrefilterDenoise: resolvedStreamSettings.prefilterDenoise,
            configuredPrefilterModel: resolvedStreamSettings.prefilterModel,
            configuredColorQuality: resolvedStreamSettings.colorQuality,
            configuredVsyncMode: NvstVsyncMode(rawValue: resolvedStreamSettings.vsyncMode) ?? .adaptive,
            configuredAudioChannelCount: resolvedStreamSettings.audioChannelCount,
            // Auto resolves against the negotiated count, so it can never read as short-changed;
            // an explicit 5.1 or 7.1 ignores that argument and reports what was actually picked.
            preferredAudioChannelCount: StreamSettingsResolver.preferredAudioChannelCount(
                surroundMode: resolvedStreamSettings.surroundMode,
                deviceOutputChannels: resolvedStreamSettings.audioChannelCount
            ),
            logger: { message in
                // Scrubbed here so both destinations share one pass, and so the durable session
                // file gets the redacted text: it used to receive the raw message while only the
                // telemetry path was scrubbed, which put anything secret-shaped in a log the user
                // is invited to share.
                let sanitized = OPNSentry.sanitizedLogMessage(message)
                OPNStreamTelemetry.capture("nvst.bifrost_free", level: .info, message: sanitized, isRedacted: true)
                diagnosticLog.append(sanitized)
            },
            remoteCoOpNativeBroadcaster: remoteCoOpNativeBroadcaster,
            remoteCoOpBrowserEgress: remoteCoOpBrowserEgress
        )
        if let bifrostFree = transport as? NvstBifrostFreeTransport {
            attachSeatNotificationHandlers(bifrostFree, nativeView: nativeView)
        }
        Task { [weak self] in
            await transport.setRecordingStatusHandler { status in
                self?.handleRecordingStatusChanged(status)
            }
            await transport.setReplayBufferStateHandler { state in
                self?.handleReplayBufferStateChanged(state)
            }
            // The HUD's live mic meter and its "the device went away" notice. Both are published from
            // the capture device, which is why they arrive as handlers rather than being polled.
            await transport.setMicrophoneLevelHandler { level in
                guard let self, !self.didEnd else { return }
                // Published at 20 Hz, and every published change re-evaluates the HUD, so a step too
                // small to show on the bar is dropped.
                guard abs(level - self.microphoneLevel) >= 0.01 else { return }
                self.microphoneLevel = level
            }
            await transport.setMicrophoneFallbackHandler { message in
                guard let self, !self.didEnd else { return }
                self.handleMicrophoneDeviceFallback(message)
            }
            // A microphone plugged in mid-stream becomes a row straight away. Relabelling is also how
            // a re-plugged device stops being called a fallback.
            await transport.setMicrophoneDeviceListHandler { [weak self] in
                guard let self, !self.didEnd else { return }
                self.refreshMicrophoneDeviceOptions()
            }
        }
        return transport
    }

    /// Drives the streaming path to a connected session, or reports why it did not get there.
    func runStartTask(path: NativeNVSTStreamingPath,
                              nativeView: NativeStreamView,
                              microphoneConfiguration: NativeNVSTMicrophoneConfiguration,
                              initialMicrophoneEnabled: Bool) {
        startTask = Task {
            do {
                try await path.setMicrophoneConfiguration(microphoneConfiguration)
                let session = try await path.start(configuration: configuration) { progress in
                    await MainActor.run {
                        self.loadingStepIndex = progress.currentStepIndex
                        self.onProgress?(progress)
                    }
                }
                do {
                    try await path.setMicrophoneEnabled(initialMicrophoneEnabled)
                } catch {
                    await MainActor.run {
                        microphoneEnabled = false
                        microphoneDesiredEnabled = false
                        OPNStreamTelemetry.capture("nvst.microphone.initialization.failed", level: .error, message: Self.message(for: error), attributes: ["applicationID": configuration.applicationID])
                    }
                }
                let shouldPresentStream = await MainActor.run {
                    presentStream(session: session, path: path, nativeView: nativeView)
                }
                if !shouldPresentStream {
                    _ = try? await path.stop(reason: .userRequested, message: "Native NVST stream view closed during startup.")
                }
            } catch {
                let diagnostics = await path.diagnosticMetadata()
                await MainActor.run { handleStartFailure(error, diagnostics: diagnostics) }
            }
        }
    }

    /// Publishes an established session to the UI. False means the view went away while the stream
    /// was still coming up, and the caller stops the session instead.
    func presentStream(session: StreamSessionDescriptor, path: NativeNVSTStreamingPath, nativeView: NativeStreamView) -> Bool {
        guard !Task.isCancelled, !didEnd, !isEnding else { return false }
        isConnected = true
        sessionLimit = StreamSessionSidebarLimit(session: session)
        nativeView.remoteInputEnabled = !unifiedHUDVisible && !streamControlsVisible
        nativeView.setNativeNVSTVideoVisible(true)
        nativeView.restoreInputFocus()
        localGamepadTopology = nativeView.gamepadTopology
        // Through the same entry point as every other announce, so `lastAnnouncedGamepadIndices`
        // reflects what the seat was actually told. Announcing directly here left it empty, and the
        // first unplug then had nothing to diff against and skipped the pad's release.
        Task { @MainActor in await syncRemoteCoOpGamepadTopology() }
        // Loads the launch-time Remote Co-Op preferences and sizes the guest relay. Nothing is
        // advertised or connected here - the invite is still an explicit action in the HUD.
        refreshRemoteCoOpState()
        loadingStepIndex = StreamLaunchStep.connected.rawValue
        enterNativeFullScreenWhenSessionReady()
        startNativeStatsPolling(path: path)
        refreshAntiAFKMouseMovementTask()
        startReplayBufferIfEnabled()
        let launchProfile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities())
        pillarboxFillModeIndex = launchProfile.pillarboxFillModeIndex
        nativeView.setPillarboxFill(mode: launchProfile.pillarboxFillModeIndex, dim: launchProfile.pillarboxFillDim)
        upscalingModeIndex = launchProfile.upscalingModeIndex
        upscalingTargetIndex = launchProfile.upscalingTargetIndex
        upscalingSharpness = launchProfile.upscalingSharpness
        upscalingDenoise = launchProfile.upscalingDenoise
        nativeStreamResolutionText = "\(launchProfile.resolution.width) x \(launchProfile.resolution.height)"
        nativeStreamFrameRateText = "\(launchProfile.fps) FPS"
        nativeStreamCodecText = launchProfile.codec.value.uppercased()
        nativeView.setVideoEnhancement(mode: launchProfile.upscalingMode,
                                       sharpness: launchProfile.upscalingSharpness,
                                       denoise: launchProfile.upscalingDenoise,
                                       targetHeight: launchProfile.upscalingTargetHeight)
        nativeView.setPresentationMode(launchProfile.presentationMode)
        onProgress?(StreamProgress(configuration: configuration, step: .connected, message: "Connected over native NVST.", isReady: true))
        OPNStreamTelemetry.capture("nvst.ui.connected", level: .info, message: "Native NVST stream connected.", attributes: ["sessionId": session.id])
        nativeConnectedAt = Date()
        scheduleAutopilotEndIfRequested()
        scheduleAutopilotScriptIfRequested()
        startAutopilotCommandFileIfRequested()
        activateForAutopilotIfRequested()
        return true
    }






    func handleStartFailure(_ error: Error, diagnostics: [String: String]) {
        guard !(error is CancellationError), !Task.isCancelled else {
            loadingStepIndex = -1
            endStreamingPerformanceMode()
            return
        }
        let message = Self.message(for: error)
        isConnected = false
        nativeView?.remoteInputEnabled = false
        nativeView?.stopHaptics()
        nativeView?.setPointerLocked(false)
        inputDispatcher?.cancel()
        inputDispatcher = nil
        endStreamingPerformanceMode()
        var metadata = ["applicationID": configuration.applicationID, "transport": "nvst"]
        metadata.merge(diagnostics) { current, _ in current }
        if let sessionError = error as? OPNStreamSessionError, case .activeSessionConflict(let conflict) = sessionError {
            metadata.merge(conflict.reportMetadata) { current, _ in current }
        }
        finishOnce(report: StreamReport(title: configuration.title, success: false, reason: .failed, message: message, durationSeconds: 0, metadata: metadata))
    }

}
