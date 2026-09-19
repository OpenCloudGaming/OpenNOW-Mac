import AppKit

@MainActor
final class OPNAppDelegate: NSObject, NSApplicationDelegate {
    private static let microphoneShortcutKeyCode: UInt16 = 46
    private static let recordingShortcutKeyCode: UInt16 = 15
    private static let antiAFKShortcutKeyCode: UInt16 = 40
    private static let initialUpdateCheckDelaySeconds: TimeInterval = 5

    private let githubUpdater = OPNGitHubUpdater(owner: "OpenCloudGaming", repository: "openNOW-Mac")
    private var applicationUpdateCheckTimer: Timer?
    private var updateCheckTask: Task<Void, Never>?
    private var updateInstallTask: Task<Void, Never>?
    private var deferredUpdateRelease: OPNGitHubRelease?
    private var streamEndUpdateObserver: NSObjectProtocol?
    private var streamShortcutMonitor: Any?
    private var isCompletingUserApprovedTermination = false

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        OPNLog.info(.shortcut, "application(openFile:) received: \(filename)")
        postOpenedFile(URL(fileURLWithPath: filename))
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        OPNLog.info(.app, "application(openFiles:) received \(filenames.count) file(s)")
        for filename in filenames {
            postOpenedFile(URL(fileURLWithPath: filename))
        }
        sender.reply(toOpenOrPrint: .success)
    }

    /// The only hook that runs before SwiftUI's window exists. `applicationDidFinishLaunching` is far
    /// too late for this: the window is already on screen by then.
    func applicationWillFinishLaunching(_ notification: Notification) {
        WindowFitting.installEarlyFitting()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything can log: installed from the stream view's `onAppear`, every line captured
        // ahead of the first stream took the sinkless path and went to `NSLog` only — out of the
        // unified log's category, out of Sentry, and out of the diagnostics file the user uploads.
        OPNStreamTelemetry.configure(sink: OPNStreamTelemetrySink())
        OPNLog.info(.app, "NSApplication did finish launching")
        installStreamShortcutMonitor()
        bindUpdatePresentation()
        startApplicationUpdateChecks()
        OPNMainWindowCloseGuard.install()
        SteamControllerHIDMonitor.shared.setEnabled(SteamControllerPreference.isEnabled)
    }

    func applicationWillTerminate(_ notification: Notification) {
        OPNLog.info(.app, "NSApplication will terminate")
        removeStreamShortcutMonitor()
        stopApplicationUpdateChecks()
        OPNMainWindowCloseGuard.uninstall()
    }

    /// The backstop behind `OPNMainWindowCloseGuard`: whichever way a window was closed — the close
    /// button the guard intercepts, the Window menu, `performClose:` — this is what decides whether
    /// the app goes with it. It is also what makes "keep running" true for a window the guard never
    /// saw, such as the guest window being the last one open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let terminates = !OPNWindowClosePreferences.keepsApplicationRunning
        OPNLog.info(.app, terminates
            ? "Application will terminate after last window closes"
            : "Application will keep running after last window closes for the menu bar")
        return terminates
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isCompletingUserApprovedTermination {
            OPNLog.info(.app, "Completing user-approved application termination")
            return .terminateNow
        }
        guard StreamSessionLifecycle.hasActiveStream else {
            OPNLog.info(.app, "Application termination allowed with no active stream")
            return .terminateNow
        }
        OPNLog.warning(.app, "Application termination requested while a stream is active")
        guard StreamSessionLifecycle.requestApplicationQuitDecision(completion: { [weak self, sender] shouldTerminateApplication in
            if shouldTerminateApplication {
                self?.isCompletingUserApprovedTermination = true
                OPNLog.info(.app, "User approved application termination with active stream")
            } else {
                OPNLog.info(.app, "User cancelled application termination with active stream")
            }
            sender.reply(toApplicationShouldTerminate: shouldTerminateApplication)
        }) else {
            OPNLog.warning(.app, "Active stream quit decision unavailable; allowing termination")
            return .terminateNow
        }
        return .terminateLater
    }

    private func postOpenedFile(_ url: URL) {
        Task { @MainActor in
            OPNFileOpenCoordinator.shared.enqueue(url)
        }
    }

    private func installStreamShortcutMonitor() {
        guard streamShortcutMonitor == nil else { return }
        streamShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApplication.shared.isActive, StreamSessionLifecycle.hasActiveStream else { return event }
            guard let command = Self.streamCommand(for: event) else { return event }
            guard StreamSessionLifecycle.sendCommand(command) else { return event }
            return nil
        }
    }

    private func removeStreamShortcutMonitor() {
        guard let streamShortcutMonitor else { return }
        NSEvent.removeMonitor(streamShortcutMonitor)
        self.streamShortcutMonitor = nil
    }

    private static func streamCommand(for event: NSEvent) -> StreamCommand? {
        guard let command = StreamCommand.shortcutCommand(keyCode: UInt16(event.keyCode), modifierFlags: event.modifierFlags) else { return nil }
        switch command {
        case .toggleMicrophone, .toggleRecording, .toggleAntiAFK:
            return command
        default: return nil
        }
    }

    static func requestApplicationUpdateCheck() {
        (NSApp.delegate as? OPNAppDelegate)?.checkForApplicationUpdates()
    }

    static func setAutomaticApplicationUpdateChecksEnabled(_ enabled: Bool) {
        OPNUpdatePreferences.automaticUpdateChecksEnabled = enabled
        (NSApp.delegate as? OPNAppDelegate)?.refreshApplicationUpdateCheckSchedule()
    }

    private func startApplicationUpdateChecks() {
        guard OPNUpdatePreferences.automaticUpdateChecksCanBeScheduled else { return }
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
        OPNReleaseHistoryStore.shared.attach(githubUpdater)
        let presentation = OPNUpdatePresentation.shared
        presentation.installHandler = { [weak self] release in
            self?.installUpdate(release)
        }
        presentation.remindHandler = {
            OPNUpdatePreferences.remindTomorrow()
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
        guard OPNUpdatePreferences.automaticUpdateChecksCanBeScheduled else {
            stopAutomaticApplicationUpdateChecks(cancelActiveCheck: true)
            return
        }
        startApplicationUpdateChecks()
    }

    private func checkForApplicationUpdates() {
        checkForApplicationUpdates(showingCurrentStatus: true, automatic: false)
    }

    private func checkForApplicationUpdates(showingCurrentStatus: Bool, automatic: Bool) {
        if !automatic {
            OPNUpdatePreferences.clearReminder()
        }
        if automatic, !OPNUpdatePreferences.shouldRunAutomaticUpdateCheck() { return }
        if OPNUpdatePreferences.updateChecksAreSuspendedForDebugging { return }
        guard updateCheckTask == nil, updateInstallTask == nil else { return }
        updateCheckTask = Task { @MainActor in
            let presentation = OPNUpdatePresentation.shared
            presentation.beginUpdateCheck()
            let startedAt = ContinuousClock.now
            do {
                let release = try await githubUpdater.checkForUpdate(channel: OPNUpdatePreferences.updateChannel)
                if let release {
                    presentUpdate(for: release, automatic: automatic)
                } else if showingCurrentStatus {
                    presentation.present(.upToDate(version: githubUpdater.currentVersion))
                }
            } catch is CancellationError where !showingCurrentStatus {
                // Automatic check interrupted; nothing to surface.
            } catch is CancellationError {
                presentation.present(.checkFailed(message: "The update check was interrupted."))
            } catch where !showingCurrentStatus {
                // Automatic check failed; nothing to surface.
            } catch {
                presentation.present(.checkFailed(message: error.localizedDescription))
            }
            // A cached or very fast check would flash the CHECKING state imperceptibly, so hold it
            // long enough to read and stamp the result so the UI can report when that last happened.
            let remaining = Self.minimumUpdateCheckVisibility - (ContinuousClock.now - startedAt)
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
            OPNUpdatePreferences.lastUpdateCheckDate = Date()
            updateCheckTask = nil
            presentation.endUpdateCheck()
        }
    }

    private static let minimumUpdateCheckVisibility: Duration = .milliseconds(800)

    /// An automatic check that lands mid-session would drop a modal over the game, so it waits for
    /// the stream to end. A check the user asked for is shown immediately either way.
    private func presentUpdate(for release: OPNGitHubRelease, automatic: Bool) {
        guard !(automatic && StreamSessionLifecycle.hasActiveStream) else {
            OPNLog.info(.app, "Deferring update prompt for \(release.version) until the active stream ends")
            deferredUpdateRelease = release
            observeStreamEndForDeferredUpdate()
            return
        }
        updateInstallTask?.cancel()
        OPNUpdatePresentation.shared.present(.available(release))
    }

    private func observeStreamEndForDeferredUpdate() {
        guard streamEndUpdateObserver == nil else { return }
        streamEndUpdateObserver = NotificationCenter.default.addObserver(
            forName: StreamSessionLifecycle.activeStreamDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                (NSApp.delegate as? OPNAppDelegate)?.presentDeferredUpdateIfStreamEnded()
            }
        }
    }

    private func presentDeferredUpdateIfStreamEnded() {
        guard !StreamSessionLifecycle.hasActiveStream, let release = deferredUpdateRelease else { return }
        deferredUpdateRelease = nil
        removeStreamEndUpdateObserver()
        OPNUpdatePresentation.shared.present(.available(release))
    }

    private func removeStreamEndUpdateObserver() {
        guard let streamEndUpdateObserver else { return }
        NotificationCenter.default.removeObserver(streamEndUpdateObserver)
        self.streamEndUpdateObserver = nil
    }

    private func installUpdate(_ release: OPNGitHubRelease) {
        guard updateInstallTask == nil else { return }
        updateInstallTask = Task { @MainActor in
            defer { updateInstallTask = nil }
            do {
                let launchedInstaller = try await githubUpdater.installRelease(release) { progress in
                    Task { @MainActor in
                        OPNUpdatePresentation.shared.reportDownloadProgress(progress)
                    }
                }
                guard launchedInstaller else {
                    OPNUpdatePresentation.shared.reportInstallFailure("OpenNOW could not launch the update installer.")
                    return
                }
                NSApp.terminate(self)
            } catch is CancellationError {
            } catch {
                OPNUpdatePresentation.shared.reportInstallFailure(error.localizedDescription.isEmpty ? "OpenNOW could not install the downloaded update." : error.localizedDescription)
            }
        }
    }
}
