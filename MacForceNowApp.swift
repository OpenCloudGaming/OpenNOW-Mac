//
//  MacForceNowApp.swift
//  MacForceNow
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import SwiftUI
import SwiftData

@main
struct MacForceNowApp: App {
    @NSApplicationDelegateAdaptor(MacForceNowAppDelegate.self) private var appDelegate

    let sharedModelContainer: ModelContainer

    init() {
        OPNSentry.clearDiagnosticsLogForNewRun()
        OPNSentry.initializeSentry()
        Task.detached(priority: .userInitiated) { MacForceNowNVIDIAFont.prepare() }
        MacForceNowLog.info(.app, "MacForce Now application initializing")
        let container = Self.makeModelContainer()
        sharedModelContainer = container
        if let imageCacheContainer = Self.makeImageCacheContainer() {
            CatalogImageCache.shared.configure(container: imageCacheContainer)
        }
        MacForceNowLog.info(.app, "MacForce Now application initialization completed")
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            LoginAccount.self,
            LoginSession.self,
            LoginDeviceRegistration.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            MacForceNowLog.info(.app, "SwiftData model container created")
            return container
        } catch {
            MacForceNowLog.error(.app, "Could not create SwiftData model container, attempting store recovery: \(error.localizedDescription)")
        }

        Self.removePersistentStoreFiles(at: modelConfiguration.url)
        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            MacForceNowLog.warning(.app, "SwiftData model container recreated after removing unreadable store")
            return container
        } catch {
            MacForceNowLog.error(.app, "SwiftData store recovery failed, falling back to in-memory store: \(error.localizedDescription)")
        }

        do {
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            MacForceNowLog.warning(.app, "SwiftData running with an in-memory store; sessions will not persist across launches")
            return container
        } catch {
            MacForceNowLog.fatal(.app, "Could not create an in-memory SwiftData model container: \(error.localizedDescription)")
            preconditionFailure("SwiftData model container could not be created in any configuration: \(error)")
        }
    }

    private static func removePersistentStoreFiles(at storeURL: URL) {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let candidate = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            do {
                try fileManager.removeItem(at: candidate)
            } catch {
                MacForceNowLog.warning(.app, "Could not remove SwiftData store file \(candidate.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    // The image cache writes access metadata continuously; it must live in its own
    // container so those saves never invalidate the auth @Query views (ContentView).
    private static func makeImageCacheContainer() -> ModelContainer? {
        let schema = Schema([CatalogImageCacheEntry.self])
        let storeURL = URL.applicationSupportDirectory.appending(path: "CatalogImageCache.store")
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            MacForceNowLog.info(.app, "Catalog image cache container created")
            return container
        } catch {
            MacForceNowLog.warning(.app, "Could not create catalog image cache container, image caching disabled: \(error.localizedDescription)")
            return nil
        }
    }

    var body: some Scene {
        Window("MacForce Now", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 680)
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button {
                    MacForceNowAppDelegate.requestApplicationUpdateCheck()
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                }
            }
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
