import AppKit

@MainActor
final class OpenNOWAppDelegate: NSObject, NSApplicationDelegate {
    private static let microphoneShortcutKeyCode: UInt16 = 46
    private static let recordingShortcutKeyCode: UInt16 = 15
    private static let antiAFKShortcutKeyCode: UInt16 = 40
    private static let initialUpdateCheckDelaySeconds: TimeInterval = 5

    private let githubUpdater = OpenNOWGitHubUpdater(owner: "OpenCloudGaming", repository: "openNOW-Mac")
    private var applicationUpdateCheckTimer: Timer?
    private var updateCheckTask: Task<Void, Never>?
    private var updateInstallTask: Task<Void, Never>?
    private var deferredUpdateRelease: OpenNOWGitHubRelease?
    private var streamEndUpdateObserver: NSObjectProtocol?
    private var streamShortcutMonitor: Any?
    private var isCompletingUserApprovedTermination = false

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        OpenNOWLog.info(.shortcut, "application(openFile:) received: \(filename)")
        postOpenedFile(URL(fileURLWithPath: filename))
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        OpenNOWLog.info(.app, "application(openFiles:) received \(filenames.count) file(s)")
        for filename in filenames {
            postOpenedFile(URL(fileURLWithPath: filename))
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        OpenNOWLog.info(.app, "NSApplication did finish launching")
        installStreamShortcutMonitor()
        bindUpdatePresentation()
        startApplicationUpdateChecks()
        SteamControllerHIDMonitor.shared.setEnabled(SteamControllerPreference.isEnabled)
    }

    func applicationWillTerminate(_ notification: Notification) {
        OpenNOWLog.info(.app, "NSApplication will terminate")
        removeStreamShortcutMonitor()
        stopApplicationUpdateChecks()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        OpenNOWLog.info(.app, "Application will terminate after last window closes")
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isCompletingUserApprovedTermination {
            OpenNOWLog.info(.app, "Completing user-approved application termination")
            return .terminateNow
        }
        guard WebRTCMediaStreamLifecycle.hasActiveStream else {
            OpenNOWLog.info(.app, "Application termination allowed with no active stream")
            return .terminateNow
        }
        OpenNOWLog.warning(.app, "Application termination requested while a stream is active")
        guard WebRTCMediaStreamLifecycle.requestApplicationQuitDecision(completion: { [weak self, sender] shouldTerminateApplication in
            if shouldTerminateApplication {
                self?.isCompletingUserApprovedTermination = true
                OpenNOWLog.info(.app, "User approved application termination with active stream")
            } else {
                OpenNOWLog.info(.app, "User cancelled application termination with active stream")
            }
            sender.reply(toApplicationShouldTerminate: shouldTerminateApplication)
        }) else {
            OpenNOWLog.warning(.app, "Active stream quit decision unavailable; allowing termination")
            return .terminateNow
        }
        return .terminateLater
    }

    private func postOpenedFile(_ url: URL) {
        Task { @MainActor in
            OpenNOWFileOpenCoordinator.shared.enqueue(url)
        }
    }

    private func installStreamShortcutMonitor() {
        guard streamShortcutMonitor == nil else { return }
        streamShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApplication.shared.isActive, WebRTCMediaStreamLifecycle.hasActiveStream else { return event }
            guard let command = Self.streamCommand(for: event) else { return event }
            guard WebRTCMediaStreamLifecycle.sendCommand(command) else { return event }
            return nil
        }
    }

    private func removeStreamShortcutMonitor() {
        guard let streamShortcutMonitor else { return }
        NSEvent.removeMonitor(streamShortcutMonitor)
        self.streamShortcutMonitor = nil
    }

    private static func streamCommand(for event: NSEvent) -> WebRTCMediaStreamCommand? {
        guard let command = WebRTCMediaStreamCommand.shortcutCommand(keyCode: UInt16(event.keyCode), modifierFlags: event.modifierFlags) else { return nil }
        switch command {
        case .toggleMicrophone, .toggleRecording, .toggleAntiAFK:
            return command
        default: return nil
        }
    }

    static func requestApplicationUpdateCheck() {
        (NSApp.delegate as? OpenNOWAppDelegate)?.checkForApplicationUpdates()
    }

    static func setAutomaticApplicationUpdateChecksEnabled(_ enabled: Bool) {
        OpenNOWUpdatePreferences.automaticUpdateChecksEnabled = enabled
        (NSApp.delegate as? OpenNOWAppDelegate)?.refreshApplicationUpdateCheckSchedule()
    }

    private func startApplicationUpdateChecks() {
        guard OpenNOWUpdatePreferences.automaticUpdateChecksCanBeScheduled else { return }
        guard applicationUpdateCheckTimer == nil else { return }
        applicationUpdateCheckTimer = Timer.scheduledTimer(timeInterval: 60 * 60, target: self, selector: #selector(applicationUpdateCheckTimerFired(_:)), userInfo: nil, repeats: true)
        // Delay the first check so it doesn't contend with the launch-time
        // catalog and login fetches; subsequent checks stay on the hourly timer.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.initialUpdateCheckDelaySeconds))
            self?.checkForApplicationUpdates(showingCurrentStatus: false, automatic: true)
        }
    }

    @objc private func applicationUpdateCheckTimerFired(_ timer: Timer) {
        checkForApplicationUpdates(showingCurrentStatus: false, automatic: true)
    }

    /// The modal and the What's New card drive the same updater instance the delegate owns, so the
    /// install action behaves identically wherever it is triggered from.
    private func bindUpdatePresentation() {
        OpenNOWReleaseHistoryStore.shared.attach(githubUpdater)
        let presentation = OpenNOWUpdatePresentation.shared
        presentation.installHandler = { [weak self] release in
            self?.installUpdate(release)
        }
        presentation.remindHandler = {
            OpenNOWUpdatePreferences.remindTomorrow()
        }
    }

    private func stopApplicationUpdateChecks() {
        stopAutomaticApplicationUpdateChecks(cancelActiveCheck: true)
        updateInstallTask?.cancel()
        updateInstallTask = nil
        deferredUpdateRelease = nil
        removeStreamEndUpdateObserver()
    }

    private func stopAutomaticApplicationUpdateChecks(cancelActiveCheck: Bool) {
        applicationUpdateCheckTimer?.invalidate()
        applicationUpdateCheckTimer = nil
        if cancelActiveCheck {
            updateCheckTask?.cancel()
            updateCheckTask = nil
        }
    }

    private func refreshApplicationUpdateCheckSchedule() {
        guard OpenNOWUpdatePreferences.automaticUpdateChecksCanBeScheduled else {
            stopAutomaticApplicationUpdateChecks(cancelActiveCheck: true)
            return
        }
        startApplicationUpdateChecks()
    }

    private func checkForApplicationUpdates() {
        checkForApplicationUpdates(showingCurrentStatus: true, automatic: false)
    }

    private func checkForApplicationUpdates(showingCurrentStatus: Bool, automatic: Bool) {
        if automatic, !OpenNOWUpdatePreferences.shouldRunAutomaticUpdateCheck() { return }
        guard updateCheckTask == nil, updateInstallTask == nil else { return }
        updateCheckTask = Task { @MainActor in
            defer { updateCheckTask = nil }
            do {
                let release = try await githubUpdater.checkForUpdate()
                guard let release else {
                    if showingCurrentStatus {
                        OpenNOWUpdatePresentation.shared.present(.upToDate(version: githubUpdater.currentVersion))
                    }
                    return
                }
                presentUpdate(for: release, automatic: automatic)
            } catch is CancellationError {
            } catch {
                guard showingCurrentStatus else { return }
                OpenNOWUpdatePresentation.shared.present(.checkFailed(message: error.localizedDescription))
            }
        }
    }

    /// An automatic check that lands mid-session would drop a modal over the game, so it waits for
    /// the stream to end. A check the user asked for is shown immediately either way.
    private func presentUpdate(for release: OpenNOWGitHubRelease, automatic: Bool) {
        guard !(automatic && WebRTCMediaStreamLifecycle.hasActiveStream) else {
            OpenNOWLog.info(.app, "Deferring update prompt for \(release.version) until the active stream ends")
            deferredUpdateRelease = release
            observeStreamEndForDeferredUpdate()
            return
        }
        updateInstallTask?.cancel()
        OpenNOWUpdatePresentation.shared.present(.available(release))
    }

    private func observeStreamEndForDeferredUpdate() {
        guard streamEndUpdateObserver == nil else { return }
        streamEndUpdateObserver = NotificationCenter.default.addObserver(
            forName: WebRTCMediaStreamLifecycle.activeStreamDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                (NSApp.delegate as? OpenNOWAppDelegate)?.presentDeferredUpdateIfStreamEnded()
            }
        }
    }

    private func presentDeferredUpdateIfStreamEnded() {
        guard !WebRTCMediaStreamLifecycle.hasActiveStream, let release = deferredUpdateRelease else { return }
        deferredUpdateRelease = nil
        removeStreamEndUpdateObserver()
        OpenNOWUpdatePresentation.shared.present(.available(release))
    }

    private func removeStreamEndUpdateObserver() {
        guard let streamEndUpdateObserver else { return }
        NotificationCenter.default.removeObserver(streamEndUpdateObserver)
        self.streamEndUpdateObserver = nil
    }

    private func installUpdate(_ release: OpenNOWGitHubRelease) {
        guard updateInstallTask == nil else { return }
        updateInstallTask = Task { @MainActor in
            defer { updateInstallTask = nil }
            do {
                let launchedInstaller = try await githubUpdater.installRelease(release) { progress in
                    Task { @MainActor in
                        OpenNOWUpdatePresentation.shared.reportDownloadProgress(progress)
                    }
                }
                guard launchedInstaller else {
                    OpenNOWUpdatePresentation.shared.reportInstallFailure("OpenNOW could not launch the update installer.")
                    return
                }
                NSApp.terminate(self)
            } catch is CancellationError {
            } catch {
                OpenNOWUpdatePresentation.shared.reportInstallFailure(error.localizedDescription.isEmpty ? "OpenNOW could not install the downloaded update." : error.localizedDescription)
            }
        }
    }
}
