//
//  OpenNOWApp.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import OpenNOWTelemetry
import SwiftUI
import SwiftData
import WebRTCMedia

@main
struct OpenNOWApp: App {
    @NSApplicationDelegateAdaptor(OpenNOWAppDelegate.self) private var appDelegate

    let sharedModelContainer: ModelContainer

    init() {
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        OpenNOWLog.info(.app, "NSApplication will terminate")
        cancelApplicationUpdateTasks()
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
        guard WebRTCMediaStreamLifecycle.requestApplicationQuitDecision(completion: { [weak self, weak sender] shouldTerminateApplication in
            guard let sender else { return }
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

    private func cancelApplicationUpdateTasks() {
        updateCheckTask?.cancel()
        updateCheckTask = nil
        updateInstallTask?.cancel()
        updateInstallTask = nil
    }

    private func checkForApplicationUpdates() {
        checkForApplicationUpdates(showingCurrentStatus: true)
    }

    private func checkForApplicationUpdates(showingCurrentStatus: Bool) {
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
            alert.informativeText = "Current version: \(currentVersion)\n\nThis update is required to continue using OpenNOW.\n\n\(notes)"
            alert.addButton(withTitle: "Install and Relaunch")
            presentAlert(alert) { [weak self] _ in
                self?.installUpdate(release)
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
