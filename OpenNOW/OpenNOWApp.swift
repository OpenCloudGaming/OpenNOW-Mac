//
//  OpenNOWApp.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import Backend
import SwiftUI
import SwiftData

@main
struct OpenNOWApp: App {
    @NSApplicationDelegateAdaptor(OpenNOWAppDelegate.self) private var appDelegate

    let sharedModelContainer: ModelContainer

    init() {
        let container = Self.makeModelContainer()
        sharedModelContainer = container
        CatalogImageCache.shared.configure(container: container)
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
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup("OpenNOW") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 720)
        .modelContainer(sharedModelContainer)
    }
}

final class OpenNOWAppDelegate: NSObject, NSApplicationDelegate {
    private var isCompletingUserApprovedTermination = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isCompletingUserApprovedTermination {
            return .terminateNow
        }
        guard OPNEmbeddedStreamLifecycle.hasActiveStream else {
            return .terminateNow
        }
        guard OPNEmbeddedStreamLifecycle.requestApplicationQuitDecision(completion: { [weak self, weak sender] shouldTerminateApplication in
            guard let sender else { return }
            if shouldTerminateApplication {
                self?.isCompletingUserApprovedTermination = true
            }
            sender.reply(toApplicationShouldTerminate: shouldTerminateApplication)
        }) else {
            return .terminateNow
        }
        return .terminateLater
    }
}
