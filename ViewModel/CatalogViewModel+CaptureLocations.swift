//  Where the Capture page's two libraries are written, and the three things a reader can do to a
//  folder: change it, put it back, or go there.
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
    var isSharingOneFolder = false
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
            isSharingOneFolder: OPNCaptureLocations.isSharingOneFolder(),
            migrationNotice: OPNCaptureMigration.pendingNotice
        )
    }

    func chooseCaptureDirectory(_ library: OPNCaptureLibrary) {
        guard isCaptureLocationEditingEnabled else {
            reportCaptureLocationLocked(library)
            return
        }
        guard let chosen = systemIntegration.chooseDirectory(
            prompt: "Choose where OpenNOW saves \(library.displayName.lowercased()).",
            startingAt: resolvedCaptureDirectory(library)
        ) else {
            return
        }
        setCaptureDirectory(chosen, for: library)
    }

    func setCaptureDirectory(_ url: URL, for library: OPNCaptureLibrary) {
        guard isCaptureLocationEditingEnabled else {
            reportCaptureLocationLocked(library)
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
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    func acknowledgeCaptureMigrationNotice() {
        OPNCaptureMigration.acknowledgeNotice()
        captureLocations.migrationNotice = nil
    }

    private func reportCaptureLocationLocked(_ library: OPNCaptureLibrary) {
        actionMessage = "Change the \(library.displayName.lowercased()) folder once the stream has ended."
    }

    private func resolvedCaptureDirectory(_ library: OPNCaptureLibrary) -> URL {
        captureLocations.directories[library]?.url ?? OPNCaptureLocations.directory(for: library)
    }
}
