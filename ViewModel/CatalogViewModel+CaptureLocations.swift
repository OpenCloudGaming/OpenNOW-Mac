//  Where the Capture page's two libraries are written, and the three things a reader can do to a
//  folder: change it, put it back, or go there. Kept out of `CatalogViewModel+Settings` so the
//  preference setters stay one file about stream settings.
//

import Foundation

/// One Capture-page row's folder: where the library resolves to, and why it is not the reader's
/// chosen folder when it is not.
struct CatalogCaptureDirectoryState: Equatable {
    var url: URL
    var rejectionReason: String?
}

/// Everything the Capture page's Storage card reads, refreshed together so the page cannot show a
/// new folder beside a stale warning.
struct CatalogCaptureLocationState: Equatable {
    var directories: [OPNCaptureLibrary: CatalogCaptureDirectoryState] = [:]
    var shareOneFolder = false
    var migrationNotice: String?
}

extension CatalogViewModel {
    /// False while a session is live, so one capture cannot split across two roots when the folder
    /// changes mid-recording.
    var isCaptureLocationEditingEnabled: Bool {
        !StreamSessionLifecycle.hasActiveStream
    }

    /// Re-reads both roots together, so the page cannot show a new folder beside a stale warning.
    func refreshCaptureLocations() {
        var directories: [OPNCaptureLibrary: CatalogCaptureDirectoryState] = [:]
        for library in OPNCaptureLibrary.allCases {
            let resolution = OPNCaptureLocations.resolve(library)
            directories[library] = CatalogCaptureDirectoryState(url: resolution.url, rejectionReason: resolution.rejectionReason)
        }
        captureLocations = CatalogCaptureLocationState(
            directories: directories,
            shareOneFolder: OPNCaptureLocations.librariesShareDirectory(),
            migrationNotice: OPNCaptureMigration.pendingNotice
        )
    }

    func chooseCaptureDirectory(_ library: OPNCaptureLibrary) {
        guard isCaptureLocationEditingEnabled else {
            actionMessage = "Change the \(library.displayName.lowercased()) folder once the stream has ended."
            return
        }
        let current = resolvedCaptureDirectory(library)
        guard let chosen = systemIntegration.chooseDirectory(
            prompt: "Choose where OpenNOW saves \(library.displayName.lowercased()).",
            startingAt: current
        ) else {
            return
        }
        setCaptureDirectory(chosen, for: library)
    }

    func setCaptureDirectory(_ url: URL, for library: OPNCaptureLibrary) {
        guard isCaptureLocationEditingEnabled else {
            actionMessage = "Change the \(library.displayName.lowercased()) folder once the stream has ended."
            return
        }
        do {
            let validated = try OPNCaptureLocations.validateDirectory(url)
            OPNCaptureLocations.setOverride(validated, for: library)
            OPNNewSettings.acknowledge(.captureLocations)
            actionMessage = "\(library.displayName) will be saved to \(validated.path)."
        } catch {
            actionMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        refreshCaptureLocations()
    }

    func resetCaptureDirectory(_ library: OPNCaptureLibrary) {
        OPNCaptureLocations.resetOverride(for: library)
        OPNNewSettings.acknowledge(.captureLocations)
        actionMessage = "\(library.displayName) will be saved to the default folder again."
        refreshCaptureLocations()
    }

    func revealCaptureDirectory(_ library: OPNCaptureLibrary) {
        let url = resolvedCaptureDirectory(library)
        _ = try? OPNCaptureLocations.ensureWritableDirectory(at: url)
        systemIntegration.revealInFinder(url)
    }

    /// The path as the row reads it, with the home directory collapsed to `~`.
    func captureDirectoryDisplayPath(for library: OPNCaptureLibrary) -> String {
        let path = resolvedCaptureDirectory(library).path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    func acknowledgeCaptureMigrationNotice() {
        OPNCaptureMigration.acknowledgeNotice()
        captureLocations.migrationNotice = nil
    }

    private func resolvedCaptureDirectory(_ library: OPNCaptureLibrary) -> URL {
        captureLocations.directories[library]?.url ?? OPNCaptureLocations.directory(for: library)
    }
}
