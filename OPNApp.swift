import AppKit
import SwiftUI
import SwiftData

@main
struct OPNApp: App {
    @NSApplicationDelegateAdaptor(OPNAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var keybindings = OPNKeybindingsObserver.shared
    /// The status item's insertion flag, observed here because `isInserted` is a scene argument:
    /// whether the item exists at all is decided in this body. Deliberately this small object and
    /// not `OPNMenuBarSessionModel` — that model publishes at stream cadence (a 1 Hz elapsed clock,
    /// queue ETAs on every poll), and observing it here re-evaluated the whole scene graph once a
    /// second. The session itself is read inside the popover, which observes it directly.
    @ObservedObject private var menuBarStatusItem = OPNMenuBarStatusItemModel.shared
    /// The scene argument for `MenuBarExtra(isInserted:)`, mirrored from the surface instead of
    /// handing SwiftUI the published property itself: SwiftUI writes this binding back on every
    /// graph change, and a `@Published` write invalidates the body even when the value is unchanged
    /// — a feedback loop that crashed the app on launch. Plain scene state ignores a write that
    /// changes nothing, which is what breaks the loop.
    @State private var isMenuBarStatusItemInserted = OPNMenuBarSessionModel.shared.isStatusItemInserted

    let sharedModelContainer: ModelContainer

    init() {
        OPNSentry.clearDiagnosticsLogForNewRun()
        OPNSentry.initializeSentry()
        Task.detached(priority: .userInitiated) {
            OPNUIFont.prepare()
            VendorResourceImage.prewarm()
        }
        OPNLog.info(.app, "OpenNOW application initializing")
        let container = Self.makeModelContainer()
        sharedModelContainer = container
        OPNLog.info(.app, "OpenNOW application initialization completed")
        Self.preloadImageCacheContainerAsync()
        Self.startCatalogLaunchPrefetch(container: container)
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            LoginAccount.self,
            LoginSession.self,
            LoginDeviceRegistration.self,
        ])
        // CloudKit is explicitly off. The app carries an iCloud entitlement for its backup container,
        // and SwiftData reads any iCloud entitlement as an invitation to attach CloudKit to this store,
        // which then rejects the model's non-optional attributes and unique constraints.
        let modelConfiguration = Self.authStoreConfiguration(schema: schema)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            OPNLog.info(.app, "SwiftData model container created")
            AuthDiagnosticLog.shared.record("store.open outcome=created url=\(modelConfiguration.url.lastPathComponent)")
            return container
        } catch {
            OPNLog.error(.app, "Could not open the SwiftData store: \(error.localizedDescription)")
            AuthDiagnosticLog.shared.record("store.open outcome=failed error=\(error.localizedDescription)")
            quarantineStoreIfUnreadable(at: modelConfiguration.url, errorDescription: error.localizedDescription)
        }

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            OPNLog.warning(.app, "SwiftData model container opened after quarantining an unreadable store")
            AuthDiagnosticLog.shared.record("store.open outcome=quarantined url=\(modelConfiguration.url.lastPathComponent)")
            return container
        } catch {
            OPNLog.error(.app, "SwiftData store still unreadable after quarantine: \(error.localizedDescription)")
            AuthDiagnosticLog.shared.record("store.open outcome=still-unreadable error=\(error.localizedDescription)")
        }

        do {
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            OPNLog.warning(.app, "SwiftData running with an in-memory store; sessions will not persist across launches")
            AuthDiagnosticLog.shared.record("store.open outcome=in-memory")
            return container
        } catch {
            OPNLog.fatal(.app, "Could not create an in-memory SwiftData model container: \(error.localizedDescription)")
            AuthDiagnosticLog.shared.record("store.open outcome=in-memory-failed error=\(error.localizedDescription)")
            preconditionFailure("SwiftData model container could not be created in any configuration: \(error)")
        }
    }

    /// The release build keeps the shared default store so existing installs keep their sessions;
    /// every other identity gets its own so two running copies cannot clobber each other's rows.
    private static func authStoreURL(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "") -> URL? {
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier != OPNProductIdentity.releaseBundleIdentifier else { return nil }
        let directory = URL.applicationSupportDirectory
            .appending(path: "OpenNOW", directoryHint: .isDirectory)
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "auth.store", directoryHint: .notDirectory)
    }

    private static func authStoreConfiguration(schema: Schema) -> ModelConfiguration {
        if let url = authStoreURL() {
            return ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        }
        return ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
    }

    /// Moves unreadable store files aside so a fresh store can open. The files are archived, never
    /// deleted, and a configuration error is left untouched: a bug must not cost the reader their
    /// saved sessions.
    private static func quarantineStoreIfUnreadable(at storeURL: URL, errorDescription: String) {
        let fileManager = FileManager.default
        let storeExists = fileManager.fileExists(atPath: storeURL.path)
        let decision = OPNStoreRecoveryPolicy.decision(storeExists: storeExists, errorDescription: errorDescription)
        guard decision == .quarantine else {
            OPNLog.warning(.app, "SwiftData store left in place; the failure is not an unreadable store")
            return
        }

        let archiveSuffix = ".unreadable-\(Int(Date().timeIntervalSince1970))"
        for storeFileSuffix in ["", "-wal", "-shm"] {
            let candidate = URL(fileURLWithPath: storeURL.path + storeFileSuffix)
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            let archived = URL(fileURLWithPath: candidate.path + archiveSuffix)
            do {
                try fileManager.moveItem(at: candidate, to: archived)
            } catch {
                OPNLog.warning(.app, "Could not archive store file \(candidate.lastPathComponent): \(error.localizedDescription)")
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
            let email = session.accountEmail
            var accountDescriptor = FetchDescriptor<LoginAccount>(predicate: #Predicate { $0.email == email })
            accountDescriptor.fetchLimit = 1
            let account = (try? context.fetch(accountDescriptor))?.first
            // The account list is seeded before the launch prefetch: a windowless launch has no
            // catalog to push it, and the menu bar shows who is signed in from the first open.
            seedMenuBarAccounts(context: context, activeEmail: email)
            let userId = session.userId.isEmpty ? (account?.userId ?? "") : session.userId
            guard !userId.isEmpty else { return }
            // Favorites are painted from the local cache before anything else: a windowless launch
            // never builds a catalog to push them, and even a windowed one shows the tab before the
            // catalog attaches. The account list is seeded above for the same reason.
            OPNMenuBarFavorites.primeFromCache(accountIdentifier: userId)
            // Collections are local, so the list paints from the store at once; the members still
            // unresolved are fetched below when no window will load a catalog to resolve them.
            OPNMenuBarCollections.primeFromCache(accountIdentifier: userId)
            // The play history is keyed by the playtime identifier, which needs the account; seeding
            // it here is what keeps the menu bar's Continue Playing list populated on a windowless
            // launch, where no catalog view model ever attaches to push it.
            if let account {
                let playtimeIdentifier = CatalogViewModel.playtimeAccountIdentifier(account: account, session: session)
                OPNMenuBarSessionModel.shared.primeRecentGames(
                    CatalogViewModel.persistedMenuBarRecentGames(accountIdentifier: playtimeIdentifier)
                )
            }
            // A launch with no window has no splash to hide and nothing to paint the catalog into, so
            // the home prefetch is skipped; the menu bar's own tabs are fetched once the session is usable.
            guard OPNLaunchPreferences.startupPresentation == .window else {
                OPNLog.info(.catalog, "Catalog prefetch skipped: launching menu bar only")
                guard !session.isExpired else { return }
                OPNMenuBarFavorites.start(accountIdentifier: userId, accessToken: session.accessToken, idToken: session.idToken)
                OPNMenuBarCollections.start(accountIdentifier: userId, accessToken: session.accessToken, idToken: session.idToken)
                return
            }
            guard !session.isExpired else {
                CatalogLaunchPrefetch.shared.primeFromCache(accountIdentifier: userId)
                return
            }
            CatalogLaunchPrefetch.shared.start(accountIdentifier: userId, accessToken: session.accessToken, idToken: session.idToken)
        }
    }

    /// Seeds the menu bar's account list from persistence. A windowless launch has no catalog view
    /// model to push the live list, so this is what names the signed-in user and offers the others.
    /// The list is later overwritten by the catalog's own snapshot once a window attaches.
    @MainActor
    private static func seedMenuBarAccounts(context: ModelContext, activeEmail: String) {
        let accounts = (try? context.fetch(FetchDescriptor<LoginAccount>(sortBy: [SortDescriptor(\LoginAccount.lastLoginAt, order: .reverse)]))) ?? []
        guard !accounts.isEmpty else { return }
        let sessions = (try? context.fetch(FetchDescriptor<LoginSession>())) ?? []
        let usableEmails = Set(sessions.filter { !$0.accessToken.isEmpty }.map(\.accountEmail))
        OPNMenuBarSessionModel.shared.primeAccounts(accounts.map { account in
            OPNMenuBarAccount(
                email: account.email,
                displayName: account.displayName,
                membershipTier: account.membershipTier,
                isSignedOut: !usableEmails.contains(account.email),
                isActive: account.email == activeEmail
            )
        })
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
        let configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            OPNLog.info(.app, "Catalog image cache container created")
            return container
        } catch {
            OPNLog.warning(.app, "Could not create catalog image cache container, image caching disabled: \(error.localizedDescription)")
            return nil
        }
    }

    /// What macOS is set to, watched in one place: Match System reads it, and both content roots
    /// resolve the palette from it.
    @StateObject private var systemAppearance = OPNSystemAppearance()

    var body: some Scene {
        Window("OpenNOW", id: "main") {
            ContentView()
                .environmentObject(systemAppearance)
        }
        .defaultSize(width: 1100, height: 680)
        .defaultLaunchBehavior(OPNLaunchPreferences.startupPresentation == .menuBarOnly ? .suppressed : .automatic)
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button {
                    OPNAppDelegate.requestApplicationUpdateCheck()
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            CommandGroup(replacing: .help) {
                Button {
                    OPNReportIssuePresentation.shared.present(context: .appEnvironment())
                } label: {
                    Label("Report an Issue…", systemImage: "exclamationmark.bubble")
                }
            }
            CommandMenu("Stream") {
                Button("Join Remote Co-Op as Guest…") {
                    openWindow(id: "remote-coop-guest")
                }
                Button("Co-Op Spike (manual port)…") {
                    openWindow(id: "remote-coop-native-guest")
                }
                Button("Toggle Microphone") {
                    _ = StreamSessionLifecycle.sendCommand(.toggleMicrophone)
                }
                .opnKeyboardShortcut(keybindings.combo(for: .toggleMicrophone))
                Button("Toggle Recording") {
                    _ = StreamSessionLifecycle.sendCommand(.toggleRecording)
                }
                .opnKeyboardShortcut(keybindings.combo(for: .toggleRecording))
                Button("Save Replay") {
                    _ = StreamSessionLifecycle.sendCommand(.saveReplay)
                }
                .opnKeyboardShortcut(keybindings.combo(for: .saveReplay))
                Button("Take Screenshot") {
                    _ = StreamSessionLifecycle.sendCommand(.takeScreenshot)
                }
                .opnKeyboardShortcut(keybindings.combo(for: .takeScreenshot))
                Button("Toggle Anti-AFK") {
                    _ = StreamSessionLifecycle.sendCommand(.toggleAntiAFK)
                }
                .opnKeyboardShortcut(keybindings.combo(for: .toggleAntiAFK))
            }
        }

        #if DEBUG
        // Dev-only preview menus, in their own `Commands` value rather than written out here, so the
        // shipping scene body stays small: see `OPNUpdatePreviewCommands`.
        .commands {
            OPNUpdatePreviewCommands()
        }
        #endif

        // The app stays a regular app — with its ordinary focus, activation, and Dock behaviour — for
        // every close choice except menu bar only. `OPNDockIconController` is the single place that
        // trades the Dock icon away, and only while no window is on screen.
        MenuBarExtra(isInserted: $isMenuBarStatusItemInserted) {
            OPNMenuBarSceneContent(session: OPNMenuBarSessionModel.shared)
        } label: {
            OPNMenuBarStatusLabel(session: OPNMenuBarSessionModel.shared)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: menuBarStatusItem.isInserted) { @MainActor _, isInserted in
            isMenuBarStatusItemInserted = isInserted
        }

        Window("Join Remote Co-Op", id: "remote-coop-guest") {
            RemoteCoOpGuestView()
        }
        .defaultSize(width: 1280, height: 800)

        Window("Co-Op Spike (manual port)", id: "remote-coop-native-guest") {
            RemoteCoOpNativeGuestView()
        }
        .defaultSize(width: 960, height: 600)
    }

}
