import Foundation
import Observation

/// The file work behind a sync, kept off the main actor: reading and writing the container, folding
/// local preferences and catalog data into the shared files, and mirroring the screenshot library.
actor OPNCloudSyncEngine {
    func sync(root: URL, categories: Set<OPNCloudSyncCategory>, device: String) throws {
        try writeManifest(root: root, device: device)
        if categories.contains(.settings) {
            try syncSettings(root: root, device: device)
        }
        if categories.contains(.catalog) {
            try syncCatalog(root: root, device: device)
        }
        if categories.contains(.screenshots) {
            try syncScreenshots(root: root)
        }
    }

    private func writeManifest(root: URL, device: String) throws {
        let url = OPNCloudSyncLayout.url(root: root, relativePath: OPNCloudSyncLayout.manifestFileName)
        try OPNCloudSyncJSON.write(OPNCloudSyncManifest(deviceID: device), to: url)
    }

    private func syncSettings(root: URL, device: String) throws {
        let url = OPNCloudSyncLayout.url(root: root, relativePath: OPNCloudSyncLayout.settingsFileName)
        let remote = OPNCloudSyncJSON.load(OPNCloudSyncSettingsFile.self, from: url) ?? OPNCloudSyncSettingsFile()
        let result = OPNCloudSyncSettingsRegistry.merge(
            local: OPNCloudSyncSettingsRegistry.snapshot(),
            remote: remote,
            baseline: OPNCloudSyncSettingsRegistry.loadBaseline(),
            device: device
        )
        OPNCloudSyncSettingsRegistry.apply(result.appliedValues)

        if result.file != remote {
            try OPNCloudSyncJSON.write(result.file, to: url)
        }
        OPNCloudSyncSettingsRegistry.saveBaseline(result.file.entries)
    }

    private func syncCatalog(root: URL, device: String) throws {
        let url = OPNCloudSyncLayout.url(root: root, relativePath: OPNCloudSyncLayout.catalogFileName)
        let remote = OPNCloudSyncJSON.load(OPNCloudSyncCatalogFile.self, from: url)
        let result = OPNCloudSyncCatalogCodec.merge(
            remote: remote,
            baseline: OPNCloudSyncCatalogCodec.loadBaseline(),
            device: device
        )

        guard result.isLocalFileChanged || remote == nil else {
            OPNCloudSyncCatalogCodec.saveBaseline(remote?.generatedAt ?? result.file.generatedAt)
            return
        }
        try OPNCloudSyncJSON.write(result.file, to: url)
        OPNCloudSyncCatalogCodec.saveBaseline(result.file.generatedAt)
    }

    private func syncScreenshots(root: URL) throws {
        let containerDirectory = OPNCloudSyncLayout.screenshotsDirectory(root: root)
        let library = StreamScreenshotLibrary.screenshotsDirectory
        try OPNCloudSyncScreenshotMirror.mirror(from: library, to: containerDirectory)
        try OPNCloudSyncScreenshotMirror.mirror(from: containerDirectory, to: library)
    }
}

/// Owns iCloud sync for the app's lifetime: whether it runs, what it last did, and when. The file
/// work is delegated to `OPNCloudSyncEngine`; this type decides when to run it and reports status.
@MainActor
@Observable
public final class OPNCloudSyncCoordinator {
    public static let shared = OPNCloudSyncCoordinator()

    public enum Status: Equatable, Sendable {
        case disabled
        case unavailable(String)
        case syncing
        case idle(Date?)
        case failed(String)

        public var isAvailable: Bool {
            if case .unavailable = self { return false }
            return true
        }
    }

    public private(set) var status: Status
    public private(set) var isEnabled: Bool
    public private(set) var lastSyncAt: Date?

    private let engine = OPNCloudSyncEngine()
    private var root: URL?
    private var defaultsObserver: NSObjectProtocol?
    private var metadataQuery: NSMetadataQuery?
    private var pendingSync: Task<Void, Never>?
    private var isSyncing = false
    private var isStarted = false

    private init() {
        let isEnabled = OPNCloudSyncPreferences.isEnabled
        self.isEnabled = isEnabled
        status = isEnabled ? .idle(nil) : .disabled
    }

    /// Called once at launch. A disabled feature does nothing, so the cost of shipping this is a
    /// single preference read until the reader turns it on.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        guard isEnabled else {
            status = .disabled
            return
        }
        observeLocalChanges()
        Task { await synchronize() }
    }

    public func setEnabled(_ isEnabled: Bool) {
        OPNCloudSyncPreferences.isEnabled = isEnabled
        self.isEnabled = isEnabled
        guard isEnabled else {
            teardown()
            status = .disabled
            return
        }
        isStarted = true
        status = .idle(lastSyncAt)
        observeLocalChanges()
        Task { await synchronize() }
    }

    /// Pushes any local changes that have not reached the container.
    public func backupNow() {
        Task { await synchronize() }
    }

    /// Re-imports the container's contents, discarding this Mac's record of what it had already seen
    /// so the shared copy wins outright.
    public func restoreNow() {
        OPNCloudSyncSettingsRegistry.saveBaseline([:])
        OPNAppPreferenceStorage.standard.removeObject(forKey: OPNCloudSyncCatalogCodec.baselineKey)
        Task { await synchronize() }
    }

    private func synchronize() async {
        guard isEnabled else {
            status = .disabled
            return
        }
        guard let containerRoot = await resolvedContainerRoot() else { return }
        root = containerRoot
        await performSync(root: containerRoot)
        startMetadataQuery()
    }

    private func resolvedContainerRoot() async -> URL? {
        let availability = await OPNCloudSyncContainer.resolve()
        switch availability {
        case .unavailable(let reason):
            status = .unavailable(reason)
            OPNLog.warning(.sync, "iCloud container unavailable: \(reason)")
            return nil
        case .available(let root):
            do {
                try OPNCloudSyncContainer.prepare(root)
                OPNLog.info(.sync, "iCloud container resolved")
                return root
            } catch {
                status = .failed(error.localizedDescription)
                return nil
            }
        }
    }

    private func performSync(root: URL) async {
        guard isEnabled, !isSyncing else { return }
        isSyncing = true
        status = .syncing
        defer { isSyncing = false }

        do {
            try await engine.sync(root: root, categories: OPNCloudSyncPreferences.enabledCategories, device: OPNCloudSyncDevice.identifier)
            lastSyncAt = Date()
            status = .idle(lastSyncAt)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Every preference write reaches `UserDefaults`, so watching its change notification is what
    /// keeps a settings edit from waiting for the next launch to travel.
    private func observeLocalChanges() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync() }
        }
    }

    private func scheduleSync() {
        guard isEnabled, root != nil else { return }
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let root = self.root else { return }
            await self.performSync(root: root)
        }
    }

    /// iCloud delivers a remote change as a metadata update for the container. It fires for this
    /// Mac's own uploads too, which is harmless: the following sync finds nothing to do.
    private func startMetadataQuery() {
        guard metadataQuery == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(value: true)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMetadataUpdate),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        query.start()
        metadataQuery = query
    }

    @objc private func handleMetadataUpdate() {
        scheduleSync()
    }

    private func teardown() {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        if let metadataQuery {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: metadataQuery)
            metadataQuery.stop()
            self.metadataQuery = nil
        }
        pendingSync?.cancel()
        pendingSync = nil
        root = nil
        isStarted = false
    }
}
