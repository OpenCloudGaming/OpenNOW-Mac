//
//  MacForceNowApp.swift
//  MacForceNow
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import Darwin
import SwiftUI
import SwiftData

enum MacForceNowUpdatePreferences {
    static let automaticUpdateChecksEnabledKey = "MacForceNowAutomaticUpdateChecksEnabled"
    static let defaultAutomaticUpdateChecksEnabled = true

    private static let remindAfterKey = "MacForceNowUpdateRemindAfter"

    static var automaticUpdateChecksEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: automaticUpdateChecksEnabledKey) != nil else {
                return defaultAutomaticUpdateChecksEnabled
            }
            return UserDefaults.standard.bool(forKey: automaticUpdateChecksEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: automaticUpdateChecksEnabledKey)
        }
    }

    static var updateChecksAreSuspendedForDebugging: Bool {
        #if DEBUG
        return true
        #else
        return isDebuggerAttached
        #endif
    }

    static var automaticUpdateChecksCanBeScheduled: Bool {
        automaticUpdateChecksEnabled && !updateChecksAreSuspendedForDebugging
    }

    static func shouldRunAutomaticUpdateCheck(now: Date = Date()) -> Bool {
        guard automaticUpdateChecksCanBeScheduled else { return false }
        guard let remindAfterDate else { return true }
        if remindAfterDate <= now {
            clearReminder()
            return true
        }
        return false
    }

    static func remindTomorrow(from date: Date = Date()) {
        let reminderDate = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(24 * 60 * 60)
        UserDefaults.standard.set(reminderDate.timeIntervalSince1970, forKey: remindAfterKey)
    }

    private static var remindAfterDate: Date? {
        guard UserDefaults.standard.object(forKey: remindAfterKey) != nil else { return nil }
        let timestamp = UserDefaults.standard.double(forKey: remindAfterKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func clearReminder() {
        UserDefaults.standard.removeObject(forKey: remindAfterKey)
    }

    private static var isDebuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}

@main
struct MacForceNowApp: App {
    @NSApplicationDelegateAdaptor(MacForceNowAppDelegate.self) private var appDelegate
    @StateObject private var twitchRealtime = TwitchRealtimeController()

    let sharedModelContainer: ModelContainer

    init() {
        OPNSentry.clearDiagnosticsLogForNewRun()
        OPNSentry.initializeSentry()
        MacForceNowLog.info(.app, "MacForce Now application initializing")
        let container = Self.makeModelContainer()
        sharedModelContainer = container
        CatalogImageCache.shared.configure(container: container)
        MacForceNowLog.info(.app, "MacForce Now application initialization completed")
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            LoginAccount.self,
            LoginSession.self,
            LoginDeviceRegistration.self,
            CatalogImageCacheEntry.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            MacForceNowLog.info(.app, "SwiftData model container created")
            return container
        } catch {
            MacForceNowLog.fatal(.app, "Could not create SwiftData model container: \(error.localizedDescription)")
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        Window("MacForce Now", id: "main") {
            ContentView()
                .environmentObject(twitchRealtime)
                .onAppear { twitchRealtime.start() }
        }
        .defaultSize(width: 1100, height: 720)
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Stream") {
                Button("Toggle Microphone") {
                    _ = WebRTCMediaStreamLifecycle.sendCommand(.toggleMicrophone)
                }
                .keyboardShortcut("m", modifiers: .command)
                Button("Toggle Recording") {
                    _ = WebRTCMediaStreamLifecycle.sendCommand(.toggleRecording)
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Toggle Anti-AFK") {
                    _ = WebRTCMediaStreamLifecycle.sendCommand(.toggleAntiAFK)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}

@MainActor
final class MacForceNowAppDelegate: NSObject, NSApplicationDelegate {
    private static let microphoneShortcutKeyCode: UInt16 = 46
    private static let recordingShortcutKeyCode: UInt16 = 15
    private static let antiAFKShortcutKeyCode: UInt16 = 40

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
        MacForceNowLog.info(.shortcut, "application(openFiles:) received \(filenames.count) file(s)")
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
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        guard modifiers == .command else { return nil }
        switch event.keyCode {
        case microphoneShortcutKeyCode: return .toggleMicrophone
        case recordingShortcutKeyCode: return .toggleRecording
        case antiAFKShortcutKeyCode: return .toggleAntiAFK
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
        checkForApplicationUpdates(showingCurrentStatus: false, automatic: true)
        applicationUpdateCheckTimer = Timer.scheduledTimer(timeInterval: 60 * 60, target: self, selector: #selector(applicationUpdateCheckTimerFired(_:)), userInfo: nil, repeats: true)
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
