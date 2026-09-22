import Foundation
import Observation

/// The file work behind a sync, kept off the main actor: reading and writing the container, folding
/// local preferences and catalog data into the shared files, and mirroring the screenshot library.
actor OPNCloudSyncEngine {
    /// Runs one pass and returns the conflicts it found, one per category. A conflict is reported to
    /// the reader rather than resolved, so the other categories still sync while it is pending.
    func sync(root: URL, categories: Set<OPNCloudSyncCategory>, device: String) throws -> [OPNCloudSyncConflict] {
        try assertBackupIsReadableSchema(root: root)
        try writeManifest(root: root, device: device)
        var conflicts: [OPNCloudSyncConflict] = []
        if categories.contains(.settings), let conflict = try syncSettings(root: root, device: device) {
            conflicts.append(conflict)
        }
        if categories.contains(.catalog), let conflict = try syncCatalog(root: root, device: device) {
            conflicts.append(conflict)
        }
        if categories.contains(.screenshots) {
            try syncScreenshots(root: root)
        }
        return conflicts
    }

    /// Refuses to touch a backup written by a newer build. Writing over it would drop data this build
    /// does not understand, so the reader is told to update instead.
    private func assertBackupIsReadableSchema(root: URL) throws {
        let url = OPNCloudSyncLayout.url(root: root, relativePath: OPNCloudSyncLayout.manifestFileName)
        guard let manifest = OPNCloudSyncJSON.load(OPNCloudSyncManifest.self, from: url) else { return }
        guard manifest.schemaVersion > OPNCloudSyncLayout.schemaVersion else { return }
        throw OPNCloudSyncError.backupFromNewerBuild(found: manifest.schemaVersion, supported: OPNCloudSyncLayout.schemaVersion)
    }

    /// The collection icon images travel with the catalog: a collection stores only the asset id, so
    /// the bytes have to reach the container for the id to mean anything on another Mac.
    private func syncCollectionIcons(root: URL) throws {
        let containerDirectory = OPNCloudSyncLayout.collectionIconsDirectory(root: root)
        let localDirectory = OPNCollectionIconStore.directory
        let uploaded = try OPNCloudSyncFileMirror.mirror(from: localDirectory, to: containerDirectory)
        let downloaded = try OPNCloudSyncFileMirror.mirror(from: containerDirectory, to: localDirectory)
        guard uploaded.copied > 0 || downloaded.copied > 0 else { return }
        NotificationCenter.default.post(name: OPNCollectionIconStore.didChangeNotification, object: nil)
    }

    private func writeManifest(root: URL, device: String) throws {
        let url = OPNCloudSyncLayout.url(root: root, relativePath: OPNCloudSyncLayout.manifestFileName)
        try OPNCloudSyncJSON.write(OPNCloudSyncManifest(deviceID: device, deviceName: OPNCloudSyncDevice.name), to: url)
    }

    /// Loads a synced file, refusing to proceed when the file exists but cannot be read so an
    /// unreadable backup is never mistaken for an absent one. Nil means the file is absent.
    private func loadRemote<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        let remote = OPNCloudSyncJSON.load(type, from: url)
        if remote == nil, OPNCloudSyncJSON.fileExists(at: url) {
            throw OPNCloudSyncError.backupUnreadable
        }
        return remote
    }

    /// Reconciles one Mac's settings with the shared file. Returns a conflict instead of merging when
    /// both sides changed since the last settled sync.
    private func syncSettings(root: URL, device: String) throws -> OPNCloudSyncConflict? {
        let url = OPNCloudSyncLayout.url(root: root, relativePath: OPNCloudSyncLayout.settingsFileName)
        let remote = try loadRemote(OPNCloudSyncSettingsFile.self, from: url) ?? OPNCloudSyncSettingsFile()
        guard remote.schemaVersion <= OPNCloudSyncLayout.schemaVersion else {
            throw OPNCloudSyncError.backupFromNewerBuild(found: remote.schemaVersion, supported: OPNCloudSyncLayout.schemaVersion)
        }

        if let conflict = OPNCloudSyncSettingsRegistry.detectConflict(
            local: OPNCloudSyncSettingsRegistry.snapshot(),
            remote: remote,
            baseline: OPNCloudSyncSettingsRegistry.loadSignatureBaseline()
        ) {
            OPNLog.info(.sync, "Settings conflict with \(conflict.remoteDisplayName); awaiting resolution")
            return conflict
        }
        return try writeSettings(remote: remote, url: url, device: device)
    }

    /// Merges this Mac's settings over the shared file and writes the result when it changed.
    private func writeSettings(remote: OPNCloudSyncSettingsFile, url: URL, device: String) throws -> OPNCloudSyncConflict? {
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
        recordSettingsSignatureBaseline(at: url)
        return nil
    }

    /// Overwrites the shared settings with this Mac's values: the reader's "keep this Mac" choice.
    func forceUploadSettings(root: URL, device: String) throws {
        let url = OPNCloudSyncLayout.url(root: root, relativePath: OPNCloudSyncLayout.settingsFileName)
        let file = OPNCloudSyncSettingsRegistry.localFile(device: device)
        try OPNCloudSyncJSON.write(file, to: url)
        OPNCloudSyncSettingsRegistry.saveBaseline(file.entries)
        OPNCloudSyncSettingsRegistry.saveSignatureBaseline(.init(
            local: OPNCloudSyncSettingsRegistry.contentSignature(values: OPNCloudSyncSettingsRegistry.snapshot()),
            remote: OPNCloudSyncSettingsRegistry.contentSignature(values: OPNCloudSyncSettingsRegistry.decodedValues(from: file))
        ))
    }

    /// Replaces this Mac's settings with the shared copy: the reader's "use the other Mac" choice.
    func forceRestoreSettings(root: URL) throws {
        let url = OPNCloudSyncLayout.url(root: root, relativePath: OPNCloudSyncLayout.settingsFileName)
        guard let remote = try loadRemote(OPNCloudSyncSettingsFile.self, from: url) else { return }
        guard remote.schemaVersion <= OPNCloudSyncLayout.schemaVersion else {
            throw OPNCloudSyncError.backupFromNewerBuild(found: remote.schemaVersion, supported: OPNCloudSyncLayout.schemaVersion)
        }
        OPNCloudSyncSettingsRegistry.apply(remote)
        OPNCloudSyncSettingsRegistry.saveBaseline(remote.entries)
        OPNCloudSyncSettingsRegistry.saveSignatureBaseline(.init(
            local: OPNCloudSyncSettingsRegistry.contentSignature(values: OPNCloudSyncSettingsRegistry.snapshot()),
            remote: OPNCloudSyncSettingsRegistry.contentSignature(values: OPNCloudSyncSettingsRegistry.decodedValues(from: remote))
        ))
    }

    private func recordSettingsSignatureBaseline(at url: URL) {
        guard let remote = OPNCloudSyncJSON.load(OPNCloudSyncSettingsFile.self, from: url) else { return }
        OPNCloudSyncSettingsRegistry.saveSignatureBaseline(.init(
            local: OPNCloudSyncSettingsRegistry.contentSignature(values: OPNCloudSyncSettingsRegistry.snapshot()),
            remote: OPNCloudSyncSettingsRegistry.contentSignature(values: OPNCloudSyncSettingsRegistry.decodedValues(from: remote))
        ))
    }

    /// Reconciles one Mac's catalog with the shared file. Returns a conflict instead of merging when
    /// both sides changed the home arrangement since the last settled sync.
    private func syncCatalog(root: URL, device: String) throws -> OPNCloudSyncConflict? {
        try syncCollectionIcons(root: root)
        let url = OPNCloudSyncLayout.url(root: root, relativePath: OPNCloudSyncLayout.catalogFileName)
        guard let remote = try loadRemote(OPNCloudSyncCatalogFile.self, from: url) else {
            return try writeCatalog(remote: nil, url: url, device: device)
        }
        guard remote.schemaVersion <= OPNCloudSyncLayout.schemaVersion else {
            throw OPNCloudSyncError.backupFromNewerBuild(found: remote.schemaVersion, supported: OPNCloudSyncLayout.schemaVersion)
        }

        if let conflict = OPNCloudSyncCatalogCodec.detectConflict(
            remote: remote,
            baseline: OPNCloudSyncCatalogCodec.loadSignatureBaseline(),
            local: OPNCloudSyncCatalogCodec.snapshot()
        ) {
            OPNLog.info(.sync, "Catalog conflict with \(conflict.remoteDisplayName); awaiting resolution")
            return conflict
        }
        return try writeCatalog(remote: remote, url: url, device: device)
    }

    /// Merges this Mac's catalog over the shared file and writes the result when it changed.
    private func writeCatalog(remote: OPNCloudSyncCatalogFile?, url: URL, device: String) throws -> OPNCloudSyncConflict? {
        let result = OPNCloudSyncCatalogCodec.merge(remote: remote, device: device)
        let isContentPresent = !result.file.collectionsByAccount.isEmpty
            || !result.file.railOrder.isEmpty
            || !result.file.railsHidden.isEmpty
        guard remote != nil || isContentPresent else { return nil }
        if result.isLocalFileChanged || remote == nil {
            try OPNCloudSyncJSON.write(result.file, to: url)
        }
        recordCatalogSignatureBaseline(at: url)
        return nil
    }

    /// Overwrites the shared catalog with this Mac's copy: the reader's "keep this Mac" choice.
    func forceUploadCatalog(root: URL, device: String) throws {
        try syncCollectionIcons(root: root)
        let url = OPNCloudSyncLayout.url(root: root, relativePath: OPNCloudSyncLayout.catalogFileName)
        let local = OPNCloudSyncCatalogCodec.snapshot()
        try OPNCloudSyncJSON.write(local, to: url)
        OPNCloudSyncCatalogCodec.saveSignatureBaseline(.init(
            local: OPNCloudSyncCatalogCodec.arrangementSignature(local),
            remote: OPNCloudSyncCatalogCodec.arrangementSignature(local)
        ))
    }

    /// Replaces this Mac's catalog with the shared copy: the reader's "use the other Mac" choice.
    func forceRestoreCatalog(root: URL) throws {
        try syncCollectionIcons(root: root)
        let url = OPNCloudSyncLayout.url(root: root, relativePath: OPNCloudSyncLayout.catalogFileName)
        guard let remote = try loadRemote(OPNCloudSyncCatalogFile.self, from: url) else { return }
        guard remote.schemaVersion <= OPNCloudSyncLayout.schemaVersion else {
            throw OPNCloudSyncError.backupFromNewerBuild(found: remote.schemaVersion, supported: OPNCloudSyncLayout.schemaVersion)
        }
        OPNCloudSyncCatalogCodec.replaceLocal(with: remote)
        OPNCloudSyncCatalogCodec.saveSignatureBaseline(.init(
            local: OPNCloudSyncCatalogCodec.arrangementSignature(OPNCloudSyncCatalogCodec.snapshot()),
            remote: OPNCloudSyncCatalogCodec.arrangementSignature(remote)
        ))
    }

    /// Records what this Mac and the shared file now agree on, so the next sync can tell a one-sided
    /// change from a conflict where both sides moved.
    private func recordCatalogSignatureBaseline(at url: URL) {
        guard let remote = OPNCloudSyncJSON.load(OPNCloudSyncCatalogFile.self, from: url) else { return }
        OPNCloudSyncCatalogCodec.saveSignatureBaseline(.init(
            local: OPNCloudSyncCatalogCodec.arrangementSignature(OPNCloudSyncCatalogCodec.snapshot()),
            remote: OPNCloudSyncCatalogCodec.arrangementSignature(remote)
        ))
    }

    private func syncScreenshots(root: URL) throws {
        let containerDirectory = OPNCloudSyncLayout.screenshotsDirectory(root: root)
        let library = StreamScreenshotLibrary.screenshotsDirectory
        let uploaded = try OPNCloudSyncFileMirror.mirror(from: library, to: containerDirectory)
        let downloaded = try OPNCloudSyncFileMirror.mirror(from: containerDirectory, to: library)
        guard uploaded.copied > 0 || downloaded.copied > 0 else { return }
        NotificationCenter.default.post(name: StreamScreenshotLibrary.didChangeNotification, object: nil)
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
        case conflict([OPNCloudSyncConflict])
        case failed(String)

        public var isAvailable: Bool {
            if case .unavailable = self { return false }
            return true
        }
    }

    public private(set) var status: Status
    public private(set) var isEnabled: Bool
    public private(set) var lastSyncAt: Date?
    /// Divergences the reader must settle, one per category. Held across passes: syncing skips a
    /// conflicting category while its entry is set, and it re-appears after a relaunch from the
    /// persisted signature baselines.
    public private(set) var pendingConflicts: [OPNCloudSyncConflict] = []

    private let engine = OPNCloudSyncEngine()
    private var root: URL?
    private var defaultsObserver: NSObjectProtocol?
    private var metadataQuery: NSMetadataQuery?
    private var pendingSync: Task<Void, Never>?
    private var isSyncing = false
    private var isResyncRequested = false
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

    /// Re-imports the container's contents, discarding this Mac's own catalog and settings so the
    /// shared copy wins outright.
    public func restoreNow() {
        pendingConflicts = []
        Task { await restoreFromBackup() }
    }

    private func restoreFromBackup() async {
        guard isEnabled else {
            status = .disabled
            return
        }
        guard let containerRoot = await resolvedContainerRoot() else { return }
        root = containerRoot
        status = .syncing
        do {
            try await engine.forceRestoreSettings(root: containerRoot)
            try await engine.forceRestoreCatalog(root: containerRoot)
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        await performSync(root: containerRoot)
        startMetadataQuery()
    }

    /// Settles one category's conflict by keeping this Mac's copy and overwriting the backup.
    public func resolveConflictKeepingLocal(_ conflict: OPNCloudSyncConflict) {
        Task { await resolveConflict(conflict, keepingLocal: true) }
    }

    /// Settles one category's conflict by discarding this Mac's copy for the backup.
    public func resolveConflictUsingRemote(_ conflict: OPNCloudSyncConflict) {
        Task { await resolveConflict(conflict, keepingLocal: false) }
    }

    private func resolveConflict(_ conflict: OPNCloudSyncConflict, keepingLocal: Bool) async {
        guard isEnabled, let root else { return }
        status = .syncing
        do {
            switch (conflict.category, keepingLocal) {
            case (.settings, true): try await engine.forceUploadSettings(root: root, device: OPNCloudSyncDevice.identifier)
            case (.settings, false): try await engine.forceRestoreSettings(root: root)
            case (.catalog, true): try await engine.forceUploadCatalog(root: root, device: OPNCloudSyncDevice.identifier)
            case (.catalog, false): try await engine.forceRestoreCatalog(root: root)
            case (.screenshots, _): break
            }
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        pendingConflicts.removeAll { $0.category == conflict.category }
        lastSyncAt = Date()
        status = pendingConflicts.isEmpty ? .idle(lastSyncAt) : .conflict(pendingConflicts)
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
        guard isEnabled else {
            status = .disabled
            return
        }
        guard !isSyncing else {
            // A pass is already running. Re-run once it finishes rather than dropping this request.
            isResyncRequested = true
            return
        }
        isSyncing = true
        status = .syncing
        defer {
            isSyncing = false
            if isResyncRequested {
                isResyncRequested = false
                Task { [weak self] in
                    guard let self, let root = self.root else { return }
                    await self.performSync(root: root)
                }
            }
        }

        do {
            let conflicts = try await engine.sync(root: root, categories: OPNCloudSyncPreferences.enabledCategories, device: OPNCloudSyncDevice.identifier)
            pendingConflicts = conflicts
            guard conflicts.isEmpty else {
                status = .conflict(conflicts)
                return
            }
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
        pendingConflicts = []
        isStarted = false
    }
}
