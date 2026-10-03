import AppKit

@MainActor
final class OPNAppDelegate: NSObject, NSApplicationDelegate {
    private static let microphoneShortcutKeyCode: UInt16 = 46
    private static let recordingShortcutKeyCode: UInt16 = 15
    private static let antiAFKShortcutKeyCode: UInt16 = 40
    /// The wait before the first automatic update check. It must clear the launch splash hold, capped
    /// at `StartupReadiness.maximumTimeout` (6 s), so the request never contends with the launch fetches.
    static let initialUpdateCheckDelaySeconds: TimeInterval = 30

    private let githubUpdater: OPNGitHubUpdater
    private let updateChecks: OPNUpdateCheckCoordinator
    private var applicationUpdateCheckTimer: Timer?
    private var updateInstallTask: Task<Void, Never>?
    private var deferredUpdateRelease: OPNGitHubRelease?
    private var streamEndUpdateObserver: NSObjectProtocol?
    private var streamShortcutMonitor: Any?
    private var isCompletingUserApprovedTermination = false

    /// The instance SwiftUI created for `@NSApplicationDelegateAdaptor`: `NSApp.delegate` is SwiftUI's
    /// wrapper, so the static entry points the app menu and Settings reach resolve the delegate here.
    private(set) static weak var activeApplicationDelegate: OPNAppDelegate?

    override init() {
        let updater = OPNGitHubUpdater(owner: "OpenCloudGaming", repository: "openNOW-Mac")
        githubUpdater = updater
        updateChecks = OPNUpdateCheckCoordinator(
            checkForUpdate: { try await updater.checkForUpdate(channel: $0) },
            currentVersion: { updater.currentVersion },
            updateChannel: { OPNUpdatePreferences.updateChannel },
            isSuspended: { OPNUpdatePreferences.updateChecksAreSuspendedForDebugging },
            shouldRunAutomaticCheck: { OPNUpdatePreferences.shouldRunAutomaticUpdateCheck() }
        )
        super.init()
        Self.activeApplicationDelegate = self
    }

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
        // Before the first preference read, which the catalog makes from a detached task: the
        // screen snapshot is captured here, on the main actor, so that read never has to reach the
        // main thread for it.
        OPNStreamScreenSnapshotCache.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything can log: installed from the stream view's `onAppear`, every line captured
        // ahead of the first stream took the sinkless path and went to `NSLog` only — out of the
        // unified log's category and out of the diagnostics file the user uploads.
        OPNStreamTelemetry.configure(sink: OPNStreamTelemetrySink())
        OPNLog.info(.app, "NSApplication did finish launching")
        installStreamShortcutMonitor()
        bindUpdatePresentation()
        startApplicationUpdateChecks()
        OPNMainWindowCloseGuard.install()
        OPNDockIconController.install()
        // The Steam Controller HID monitor starts on demand instead of here: nothing needs pad input
        // until a stream starts, controller mode is entered, or the controller settings page opens.

        // Before the first sync pass: a launch that synced first would copy the legacy folder's
        // contents into an empty new library.
        let migration = OPNCaptureMigration.runMigration()
        if !migration.movedLibraries.isEmpty || !migration.warnings.isEmpty {
            OPNLog.info(.app, "Capture library migration moved \(migration.movedLibraries.map(\.rawValue)) warnings=\(migration.warnings.count)")
        }
        OPNCloudSyncCoordinator.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        OPNLog.info(.app, "NSApplication will terminate")
        removeStreamShortcutMonitor()
        stopApplicationUpdateChecks()
        OPNMainWindowCloseGuard.uninstall()
        OPNDockIconController.uninstall()
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

    /// The Dock icon's own way back to the window. A hidden window is not re-presented by SwiftUI —
    /// the scene never closed — so clicking the Dock icon orders the retained window front with its
    /// place kept rather than leaving the app with no way back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        guard OPNMainWindow.existing() != nil else { return false }
        OPNDockIconController.showDockIcon()
        OPNMainWindow.present()
        return true
    }

    /// The Dock icon's menu, rebuilt every time the Dock asks for it — which is on each right-click,
    /// and is also what keeps the games in it current.
    ///
    /// Only reachable while the app has a Dock icon: `Close, Menu Bar Only` with nothing on screen
    /// hands the Dock away, and the menu, the badge, and the progress bar go with it. The menu bar is
    /// the surface that answers there.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let session = OPNMenuBarSessionModel.shared
        return OPNDockMenu.make(
            recentGames: session.recentGames,
            phase: session.phase,
            gameTitle: session.gameTitle
        )
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
        case .toggleMicrophone, .toggleRecording, .saveReplay, .takeScreenshot, .toggleAntiAFK:
            return command
        default: return nil
        }
    }

    static func requestApplicationUpdateCheck() {
        Self.activeApplicationDelegate?.checkForApplicationUpdates(isAutomatic: false)
    }

    static func setAutomaticApplicationUpdateChecksEnabled(_ enabled: Bool) {
        OPNUpdatePreferences.automaticUpdateChecksEnabled = enabled
        Self.activeApplicationDelegate?.refreshApplicationUpdateCheckSchedule()
    }

    private func startApplicationUpdateChecks() {
        guard OPNUpdatePreferences.automaticUpdateChecksCanBeScheduled else { return }
        guard applicationUpdateCheckTimer == nil else { return }
        applicationUpdateCheckTimer = Timer.scheduledTimer(timeInterval: 60 * 60, target: self, selector: #selector(applicationUpdateCheckTimerFired(_:)), userInfo: nil, repeats: true)
        // Delay the first check so it doesn't contend with the launch-time catalog and login fetches;
        // subsequent checks stay on the hourly timer.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.initialUpdateCheckDelaySeconds))
            guard !Task.isCancelled else { return }
            self?.checkForApplicationUpdates(isAutomatic: true)
        }
    }

    @objc private func applicationUpdateCheckTimerFired(_ timer: Timer) {
        checkForApplicationUpdates(isAutomatic: true)
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
        updateChecks.onCheckStarted = {
            presentation.beginUpdateCheck()
        }
        updateChecks.onCheckFinished = {
            presentation.endUpdateCheck()
        }
        updateChecks.onCheckCompleted = {
            OPNUpdatePreferences.lastUpdateCheckDate = Date()
        }
        updateChecks.onOutcome = { [weak self] outcome, kind in
            self?.surfaceUpdateCheckOutcome(outcome, kind: kind)
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
            updateChecks.cancel()
        }
    }

    private func refreshApplicationUpdateCheckSchedule() {
        guard OPNUpdatePreferences.automaticUpdateChecksCanBeScheduled else {
            stopAutomaticApplicationUpdateChecks(cancelActiveCheck: true)
            return
        }
        startApplicationUpdateChecks()
    }

    /// Manual requests clear the "remind tomorrow" snooze before the gate, matching prior behaviour.
    private func checkForApplicationUpdates(isAutomatic: Bool) {
        guard !isAutomatic else {
            requestUpdateCheck(.automatic)
            return
        }
        OPNUpdatePreferences.clearReminder()
        requestUpdateCheck(.manual)
    }

    /// An install owns the update modal: its scrim blocks the Settings control, and a check result
    /// would replace the running install's progress.
    private func requestUpdateCheck(_ kind: OPNUpdateCheckCoordinator.Kind) {
        guard updateInstallTask == nil else { return }
        updateChecks.request(kind)
    }

    private func surfaceUpdateCheckOutcome(_ outcome: OPNUpdateCheckCoordinator.Outcome, kind: OPNUpdateCheckCoordinator.Kind) {
        guard kind == .manual else {
            surfaceAutomaticUpdateCheckOutcome(outcome)
            return
        }
        surfaceManualUpdateCheckOutcome(outcome)
    }

    /// An automatic check only ever interrupts the user for an installable release.
    private func surfaceAutomaticUpdateCheckOutcome(_ outcome: OPNUpdateCheckCoordinator.Outcome) {
        guard case .available(let release) = outcome else { return }
        presentUpdate(for: release, isAutomatic: true)
    }

    /// A manual request always surfaces: the release, "up to date", the failure, or the suspension.
    private func surfaceManualUpdateCheckOutcome(_ outcome: OPNUpdateCheckCoordinator.Outcome) {
        let presentation = OPNUpdatePresentation.shared
        switch outcome {
        case .available(let release):
            presentUpdate(for: release, isAutomatic: false)
        case .upToDate(let version):
            presentation.present(.upToDate(version: version))
        case .failed(let message):
            presentation.present(.checkFailed(message: message))
        case .suspended:
            presentation.present(.checkUnavailable(message: Self.updateChecksSuspendedMessage))
        }
    }

    static let updateChecksSuspendedMessage = "Update checks are suspended while OpenNOW runs as a debug build or with a debugger attached, because those report version 0.0.0 and would always think an update is available. Use OpenNOW ▸ Preview Update Dialog to test the update dialogs."

    /// An automatic check that lands mid-session would drop a modal over the game, so it waits for
    /// the stream to end. A check the user asked for is shown immediately either way.
    private func presentUpdate(for release: OPNGitHubRelease, isAutomatic: Bool) {
        guard !(isAutomatic && StreamSessionLifecycle.hasActiveStream) else {
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
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.presentDeferredUpdateIfStreamEnded()
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
