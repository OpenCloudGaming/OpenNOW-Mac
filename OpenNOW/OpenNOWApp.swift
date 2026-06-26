//
//  OpenNOWApp.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import Darwin
import OpenNOWTelemetry
import SwiftUI
import SwiftData
import WebRTCMedia

enum OpenNOWUpdatePreferences {
    static let automaticUpdateChecksEnabledKey = "OpenNOWAutomaticUpdateChecksEnabled"
    static let defaultAutomaticUpdateChecksEnabled = true

    private static let remindAfterKey = "OpenNOWUpdateRemindAfter"

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
struct OpenNOWApp: App {
    @NSApplicationDelegateAdaptor(OpenNOWAppDelegate.self) private var appDelegate

    let sharedModelContainer: ModelContainer

    init() {
        OPNSentry.clearDiagnosticsLogForNewRun()
        OPNSentry.initializeSentry()
        OpenNOWLog.info(.app, "OpenNOW application initializing")
        let container = Self.makeModelContainer()
        sharedModelContainer = container
        CatalogImageCache.shared.configure(container: container)
        OpenNOWLog.info(.app, "OpenNOW application initialization completed")
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
            OpenNOWLog.info(.app, "SwiftData model container created")
            return container
        } catch {
            OpenNOWLog.fatal(.app, "Could not create SwiftData model container: \(error.localizedDescription)")
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        Window("OpenNOW", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.hiddenTitleBar)
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class OpenNOWAppDelegate: NSObject, NSApplicationDelegate {
    private let githubUpdater = OpenNOWGitHubUpdater(owner: "OpenCloudGaming", repository: "OpenNOW-Mac")
    private var applicationUpdateCheckTimer: Timer?
    private var updateCheckTask: Task<Void, Never>?
    private var updateInstallTask: Task<Void, Never>?
    private var isCompletingUserApprovedTermination = false

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        OpenNOWLog.info(.shortcut, "application(openFile:) received: \(filename)")
        postOpenedFile(URL(fileURLWithPath: filename))
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        OpenNOWLog.info(.shortcut, "application(openFiles:) received \(filenames.count) file(s)")
        for filename in filenames {
            postOpenedFile(URL(fileURLWithPath: filename))
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        OpenNOWLog.info(.app, "NSApplication did finish launching")
        startApplicationUpdateChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        OpenNOWLog.info(.app, "NSApplication will terminate")
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
                        let currentVersion = githubUpdater.currentVersion
                        let alert = NSAlert()
                        alert.messageText = "OpenNOW is up to date"
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

    private func presentUpdateAlert(for release: OpenNOWGitHubRelease) {
        updateInstallTask?.cancel()
        Task { @MainActor in
            let currentVersion = githubUpdater.currentVersion
            var notes = release.releaseNotes.isEmpty ? "No release notes were provided." : release.releaseNotes
            if notes.count > 1400 {
                notes = String(notes.prefix(1400)) + "\n..."
            }

            let alert = NSAlert()
            alert.messageText = "OpenNOW \(release.version) is available"
            alert.informativeText = "Current version: \(currentVersion)\n\nA newer signed OpenNOW build is available.\n\n\(notes)"
            alert.addButton(withTitle: "Install and Relaunch")
            alert.addButton(withTitle: "Remind Me Tomorrow")
            alert.addButton(withTitle: "Cancel")
            presentAlert(alert) { [weak self] response in
                switch response {
                case .alertFirstButtonReturn:
                    self?.installUpdate(release)
                case .alertSecondButtonReturn:
                    OpenNOWUpdatePreferences.remindTomorrow()
                default:
                    break
                }
            }
        }
    }

    private func installUpdate(_ release: OpenNOWGitHubRelease) {
        guard updateInstallTask == nil else { return }
        updateInstallTask = Task { @MainActor in
            defer { updateInstallTask = nil }
            do {
                let launchedInstaller = try await githubUpdater.installRelease(release)
                guard launchedInstaller else {
                    showUpdateInstallFailed(message: "OpenNOW could not launch the update installer.")
                    return
                }
                NSApp.terminate(self)
            } catch is CancellationError {
            } catch {
                showUpdateInstallFailed(message: error.localizedDescription.isEmpty ? "OpenNOW could not install the downloaded update." : error.localizedDescription)
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

extension Notification.Name {
    static let openNOWDidOpenFile = Notification.Name("OpenNOWDidOpenFile")
}
