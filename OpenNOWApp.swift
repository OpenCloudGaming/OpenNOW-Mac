//
//  OpenNOWApp.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import SwiftUI
import SwiftData

@main
struct OpenNOWApp: App {
    @NSApplicationDelegateAdaptor(OpenNOWAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    let sharedModelContainer: ModelContainer

    init() {
        OPNSentry.clearDiagnosticsLogForNewRun()
        OPNSentry.initializeSentry()
        Task.detached(priority: .userInitiated) {
            OpenNOWNVIDIAFont.prepare()
            VendorResourceImage.prewarm()
        }
        OpenNOWLog.info(.app, "OpenNOW application initializing")
        let container = Self.makeModelContainer()
        sharedModelContainer = container
        OpenNOWLog.info(.app, "OpenNOW application initialization completed")
        Self.preloadImageCacheContainerAsync()
        Self.startCatalogLaunchPrefetch(container: container)
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
            OpenNOWLog.info(.app, "SwiftData model container created")
            return container
        } catch {
            OpenNOWLog.error(.app, "Could not create SwiftData model container, attempting store recovery: \(error.localizedDescription)")
        }

        Self.removePersistentStoreFiles(at: modelConfiguration.url)
        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            OpenNOWLog.warning(.app, "SwiftData model container recreated after removing unreadable store")
            return container
        } catch {
            OpenNOWLog.error(.app, "SwiftData store recovery failed, falling back to in-memory store: \(error.localizedDescription)")
        }

        do {
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            OpenNOWLog.warning(.app, "SwiftData running with an in-memory store; sessions will not persist across launches")
            return container
        } catch {
            OpenNOWLog.fatal(.app, "Could not create an in-memory SwiftData model container: \(error.localizedDescription)")
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
                OpenNOWLog.warning(.app, "Could not remove SwiftData store file \(candidate.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    // Kicks the home panel fetch off before SwiftUI has even built the scene, so the
    // request runs underneath the splash screen instead of after it. An expired session
    // cannot fetch until auth is refreshed (the catalog view model handles that), but it
    // can still paint from the panel cache, which needs no token.
    private static func startCatalogLaunchPrefetch(container: ModelContainer) {
        Task { @MainActor in
            let context = container.mainContext
            var sessionDescriptor = FetchDescriptor<LoginSession>(sortBy: [SortDescriptor(\LoginSession.issuedAt, order: .reverse)])
            sessionDescriptor.fetchLimit = 8
            guard let sessions = try? context.fetch(sessionDescriptor),
                  let session = sessions.first(where: \.isActive) else { return }
            var userId = session.userId
            if userId.isEmpty {
                let email = session.accountEmail
                var accountDescriptor = FetchDescriptor<LoginAccount>(predicate: #Predicate { $0.email == email })
                accountDescriptor.fetchLimit = 1
                userId = (try? context.fetch(accountDescriptor))?.first?.userId ?? ""
            }
            guard !userId.isEmpty else { return }
            guard !session.isExpired else {
                CatalogLaunchPrefetch.shared.primeFromCache(accountIdentifier: userId)
                return
            }
            CatalogLaunchPrefetch.shared.start(accountIdentifier: userId, accessToken: session.accessToken, idToken: session.idToken)
        }
    }

    // The catalog image cache store backs the first frame's artwork, so it is opened at
    // user-initiated priority: until it is ready the cache cannot serve stored images and
    // re-downloads them instead. It still lives in its own container (see below).
    private static func preloadImageCacheContainerAsync() {
        Task.detached(priority: .userInitiated) {
            guard let imageCacheContainer = Self.makeImageCacheContainer() else { return }
            CatalogImageCache.shared.configure(container: imageCacheContainer)
        }
    }

    // The image cache writes access metadata continuously; it must live in its own
    // container so those saves never invalidate the auth @Query views (ContentView).
    nonisolated private static func makeImageCacheContainer() -> ModelContainer? {
        let schema = Schema([CatalogImageCacheEntry.self])
        let storeURL = URL.applicationSupportDirectory.appending(path: "CatalogImageCache.store")
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            OpenNOWLog.info(.app, "Catalog image cache container created")
            return container
        } catch {
            OpenNOWLog.warning(.app, "Could not create catalog image cache container, image caching disabled: \(error.localizedDescription)")
            return nil
        }
    }

    var body: some Scene {
        Window("OpenNOW", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 680)
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button {
                    OpenNOWAppDelegate.requestApplicationUpdateCheck()
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                }
                #if DEBUG
                Menu("Preview Update Dialog") {
                    Button("Update Available") {
                        OpenNOWUpdatePresentation.shared.presentSampleUpdate()
                    }
                    Button("Up To Date") {
                        OpenNOWUpdatePresentation.shared.presentSampleStatus(.upToDate(version: SettingsAppMetadata.version))
                    }
                    Button("Check Failed") {
                        OpenNOWUpdatePresentation.shared.presentSampleStatus(.checkFailed(message: "The Internet connection appears to be offline."))
                    }
                    Button("Install Failed") {
                        OpenNOWUpdatePresentation.shared.presentSampleStatus(.installFailed(message: "The downloaded app bundle did not pass macOS code-signature verification."))
                    }
                }
                #endif
            }
            CommandMenu("Stream") {
                Button("Join Remote Co-Op as Guest…") {
                    openWindow(id: "remote-coop-guest")
                }
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

        Window("Join Remote Co-Op", id: "remote-coop-guest") {
            RemoteCoOpGuestView()
        }
        .defaultSize(width: 1280, height: 800)
    }
}
