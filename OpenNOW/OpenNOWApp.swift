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
}

extension Notification.Name {
    static let openNOWDidOpenFile = Notification.Name("OpenNOWDidOpenFile")
}
