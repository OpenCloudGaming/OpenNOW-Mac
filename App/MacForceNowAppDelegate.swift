import AppKit

@MainActor
final class MacForceNowAppDelegate: NSObject, NSApplicationDelegate {
    private static let microphoneShortcutKeyCode: UInt16 = 46
    private static let recordingShortcutKeyCode: UInt16 = 15
    private static let antiAFKShortcutKeyCode: UInt16 = 40
    private static let initialUpdateCheckDelaySeconds: TimeInterval = 5

    private let githubUpdater = MacForceNowGitHubUpdater(owner: "anderson-oki", repository: "macforce-now")
    private var applicationUpdateCheckTimer: Timer?
    private var updateCheckTask: Task<Void, Never>?
    private var updateInstallTask: Task<Void, Never>?
    private var streamShortcutMonitor: Any?
    private var isCompletingUserApprovedTermination = false

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        MacForceNowLog.info(.shortcut, "application(openFile:) received: \(filename)")
        postOpenedFile(URL(fileURLWithPath: filename))
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        MacForceNowLog.info(.app, "application(openFiles:) received \(filenames.count) file(s)")
        for filename in filenames {
            postOpenedFile(URL(fileURLWithPath: filename))
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MacForceNowLog.info(.app, "NSApplication did finish launching")
        installStreamShortcutMonitor()
        startApplicationUpdateChecks()
        SteamControllerHIDMonitor.shared.setEnabled(SteamControllerPreference.isEnabled)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MacForceNowLog.info(.app, "NSApplication will terminate")
        removeStreamShortcutMonitor()
        stopApplicationUpdateChecks()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MacForceNowLog.info(.app, "Application will terminate after last window closes")
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isCompletingUserApprovedTermination {
            MacForceNowLog.info(.app, "Completing user-approved application termination")
            return .terminateNow
        }
        guard WebRTCMediaStreamLifecycle.hasActiveStream else {
            MacForceNowLog.info(.app, "Application termination allowed with no active stream")
            return .terminateNow
        }
        MacForceNowLog.warning(.app, "Application termination requested while a stream is active")
        guard WebRTCMediaStreamLifecycle.requestApplicationQuitDecision(completion: { [weak self, sender] shouldTerminateApplication in
            if shouldTerminateApplication {
                self?.isCompletingUserApprovedTermination = true
                MacForceNowLog.info(.app, "User approved application termination with active stream")
            } else {
                MacForceNowLog.info(.app, "User cancelled application termination with active stream")
            }
            sender.reply(toApplicationShouldTerminate: shouldTerminateApplication)
        }) else {
            MacForceNowLog.warning(.app, "Active stream quit decision unavailable; allowing termination")
            return .terminateNow
        }
        return .terminateLater
    }

    private func postOpenedFile(_ url: URL) {
        Task { @MainActor in
            MacForceNowFileOpenCoordinator.shared.enqueue(url)
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
        (NSApp.delegate as? MacForceNowAppDelegate)?.checkForApplicationUpdates()
    }

    static func setAutomaticApplicationUpdateChecksEnabled(_ enabled: Bool) {
        MacForceNowUpdatePreferences.automaticUpdateChecksEnabled = enabled
        (NSApp.delegate as? MacForceNowAppDelegate)?.refreshApplicationUpdateCheckSchedule()
    }

    private func startApplicationUpdateChecks() {
        guard MacForceNowUpdatePreferences.automaticUpdateChecksCanBeScheduled else { return }
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

    private func stopApplicationUpdateChecks() {
        stopAutomaticApplicationUpdateChecks(cancelActiveCheck: true)
        updateInstallTask?.cancel()
        updateInstallTask = nil
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
        guard MacForceNowUpdatePreferences.automaticUpdateChecksCanBeScheduled else {
            stopAutomaticApplicationUpdateChecks(cancelActiveCheck: true)
            return
        }
        startApplicationUpdateChecks()
    }

    private func checkForApplicationUpdates() {
        checkForApplicationUpdates(showingCurrentStatus: true, automatic: false)
    }

    private func checkForApplicationUpdates(showingCurrentStatus: Bool, automatic: Bool) {
        if automatic, !MacForceNowUpdatePreferences.shouldRunAutomaticUpdateCheck() { return }
        guard updateCheckTask == nil, updateInstallTask == nil else { return }
        updateCheckTask = Task { @MainActor in
            defer { updateCheckTask = nil }
            do {
                let release = try await githubUpdater.checkForUpdate()
                guard let release else {
                    if showingCurrentStatus {
                        let currentVersion = githubUpdater.currentVersion
                        let alert = NSAlert()
                        alert.messageText = "MacForce Now is up to date"
                        alert.informativeText = "Version \(currentVersion) is the latest release available on GitHub."
                        alert.addButton(withTitle: "OK")
                        presentAlert(alert)
                    }
                    return
                }
                presentUpdateAlert(for: release)
            } catch is CancellationError {
            } catch {
                guard showingCurrentStatus else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Update check failed"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                presentAlert(alert)
            }
        }
    }

    private func presentUpdateAlert(for release: MacForceNowGitHubRelease) {
        updateInstallTask?.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let currentVersion = githubUpdater.currentVersion
            var notes = release.releaseNotes.isEmpty ? "No release notes were provided." : release.releaseNotes
            if notes.count > 1400 {
                notes = String(notes.prefix(1400)) + "\n..."
            }

            let alert = NSAlert()
            alert.messageText = "MacForce Now \(release.version) is available"
            alert.informativeText = "Current version: \(currentVersion)\n\nA newer signed MacForce Now build is available.\n\n\(notes)"
            alert.addButton(withTitle: "Install and Relaunch")
            alert.addButton(withTitle: "Remind Me Tomorrow")
            alert.addButton(withTitle: "Cancel")
            presentAlert(alert) { [weak self] response in
                switch response {
                case .alertFirstButtonReturn:
                    self?.installUpdate(release)
                case .alertSecondButtonReturn:
                    MacForceNowUpdatePreferences.remindTomorrow()
                default:
                    break
                }
            }
        }
    }

    private func installUpdate(_ release: MacForceNowGitHubRelease) {
        guard updateInstallTask == nil else { return }
        updateInstallTask = Task { @MainActor in
            defer { updateInstallTask = nil }
            do {
                let launchedInstaller = try await githubUpdater.installRelease(release)
                guard launchedInstaller else {
                    showUpdateInstallFailed(message: "MacForce Now could not launch the update installer.")
                    return
                }
                NSApp.terminate(self)
            } catch is CancellationError {
            } catch {
                showUpdateInstallFailed(message: error.localizedDescription.isEmpty ? "MacForce Now could not install the downloaded update." : error.localizedDescription)
            }
        }
    }

    private func showUpdateInstallFailed(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update install failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        presentAlert(alert)
    }

    private func presentAlert(_ alert: NSAlert, completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            alert.beginSheetModal(for: window) { response in
                completion?(response)
            }
        } else {
            let response = alert.runModal()
            completion?(response)
        }
    }
}
