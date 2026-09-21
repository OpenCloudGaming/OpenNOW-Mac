//  The screenshot library: what is on disk, which album is showing, what is selected, and the
//  filter/sort state over it. Albums are local only, so the model owns them alongside the shots.
//

import Combine
import Foundation

/// Which slice of the library the page is showing. `.all` and `.unfiled` are pseudo-albums; a real
/// album is named by id so a rename never breaks the selection.
enum ScreenshotAlbumSelection: Equatable, Hashable {
    case all
    case unfiled
    case album(UUID)
}

@MainActor
final class ScreenshotsViewModel: ObservableObject {
    @Published var screenshots: [StreamScreenshot] = []
    @Published var albums: [ScreenshotAlbum] = []
    @Published var selectedAlbum: ScreenshotAlbumSelection = .all
    @Published var selectedScreenshot: StreamScreenshot?
    @Published var searchText = ""
    @Published var sortOrder: ScreenshotSortOrder = .newest
    @Published var activeFilters = Set<ScreenshotFilter>()
    @Published var pendingDelete: StreamScreenshot?
    @Published var pendingAlbumDelete: ScreenshotAlbum?
    @Published var copiedPathScreenshotID: UUID?
    @Published var message = ""

    private let systemIntegration: any SystemIntegrationServing

    init(systemIntegration: any SystemIntegrationServing = AppKitSystemIntegration()) {
        self.systemIntegration = systemIntegration
    }

    // MARK: - Derived

    var visibleScreenshots: [StreamScreenshot] {
        Self.visibleScreenshots(
            in: screenshots,
            album: selectedAlbum,
            searchText: searchText,
            filters: activeFilters,
            sortOrder: sortOrder
        )
    }

    /// Static and pure so the album-then-search-then-filter-then-sort behaviour can be checked
    /// without a view model instance.
    static func visibleScreenshots(
        in screenshots: [StreamScreenshot],
        album: ScreenshotAlbumSelection,
        searchText: String,
        filters: Set<ScreenshotFilter>,
        sortOrder: ScreenshotSortOrder
    ) -> [StreamScreenshot] {
        let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return screenshots
            .filter { screenshot in
                switch album {
                case .all: return true
                case .unfiled: return screenshot.albumIDs.isEmpty
                case .album(let id): return screenshot.albumIDs.contains(id)
                }
            }
            .filter { screenshot in
                guard !normalizedQuery.isEmpty else { return true }
                return screenshot.title.lowercased().contains(normalizedQuery)
                    || screenshot.applicationID.lowercased().contains(normalizedQuery)
                    || screenshot.fileName.lowercased().contains(normalizedQuery)
            }
            .filter { screenshot in
                filters.allSatisfy { $0.matches(screenshot) }
            }
            .sorted(using: sortOrder)
    }

    var stats: ScreenshotLibraryStats {
        ScreenshotLibraryStats(screenshots: screenshots, albums: albums)
    }

    var albumCounts: [UUID: Int] {
        screenshots.reduce(into: [:]) { counts, screenshot in
            for albumID in screenshot.albumIDs {
                counts[albumID, default: 0] += 1
            }
        }
    }

    var unfiledCount: Int {
        screenshots.reduce(0) { $0 + ($1.albumIDs.isEmpty ? 1 : 0) }
    }

    var currentAlbumName: String {
        switch selectedAlbum {
        case .all: return "All Screenshots"
        case .unfiled: return "Unfiled"
        case .album(let id): return albums.first(where: { $0.id == id })?.name ?? "Album"
        }
    }

    var deleteDialogTitle: String {
        guard let pendingDelete else { return "Delete screenshot?" }
        return "Delete \"\(pendingDelete.title)\"?"
    }

    // MARK: - Library

    func reload(showMessage: Bool) {
        screenshots = StreamScreenshotLibrary.loadScreenshots()
        albums = StreamScreenshotLibrary.loadAlbums()
        pruneAlbumSelection()
        if let selectedScreenshot, let refreshed = screenshots.first(where: { $0.id == selectedScreenshot.id }) {
            self.selectedScreenshot = refreshed
        } else {
            selectedScreenshot = visibleScreenshots.first
        }
        if showMessage {
            message = screenshots.isEmpty ? "No screenshots yet. Take one from a running stream." : "Loaded \(screenshots.count) screenshot\(screenshots.count == 1 ? "" : "s")."
        }
    }

    /// Drops an album selection whose album vanished under it, so a deleted album does not leave the
    /// page showing an empty slice with a stale name.
    private func pruneAlbumSelection() {
        guard case .album(let id) = selectedAlbum else { return }
        guard !albums.contains(where: { $0.id == id }) else { return }
        selectedAlbum = .all
    }

    func select(_ screenshot: StreamScreenshot?) {
        selectedScreenshot = screenshot
    }

    // MARK: - Search, filters, sort

    func clearSearch() {
        searchText = ""
    }

    func clearFilters() {
        activeFilters.removeAll()
    }

    func toggleFilter(_ filter: ScreenshotFilter) {
        if activeFilters.contains(filter) {
            activeFilters.remove(filter)
        } else {
            activeFilters.insert(filter)
        }
    }

    func selectAlbum(_ selection: ScreenshotAlbumSelection) {
        selectedAlbum = selection
        selectedScreenshot = visibleScreenshots.first
    }

    // MARK: - Albums

    @discardableResult
    func createAlbum(named name: String) -> ScreenshotAlbum? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !albums.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else {
            message = "An album named \"\(trimmed)\" already exists."
            return nil
        }
        let album = ScreenshotAlbum(id: UUID(), name: trimmed, createdAt: Date())
        albums.append(album)
        do {
            try StreamScreenshotLibrary.saveAlbums(albums)
            message = "Created album \"\(trimmed)\"."
            return album
        } catch {
            albums.removeAll { $0.id == album.id }
            message = error.localizedDescription
            return nil
        }
    }

    func renameAlbum(_ album: ScreenshotAlbum, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = albums.firstIndex(where: { $0.id == album.id }) else { return }
        let previous = albums[index].name
        albums[index].name = trimmed
        do {
            try StreamScreenshotLibrary.saveAlbums(albums)
            message = "Renamed album to \"\(trimmed)\"."
        } catch {
            albums[index].name = previous
            message = error.localizedDescription
        }
    }

    func deletePendingAlbum() {
        guard let album = pendingAlbumDelete else { return }
        pendingAlbumDelete = nil
        let previousAlbums = albums
        albums.removeAll { $0.id == album.id }
        do {
            try StreamScreenshotLibrary.saveAlbums(albums)
        } catch {
            albums = previousAlbums
            message = error.localizedDescription
            return
        }
        // Membership lives on each screenshot, so removing the album also unfiles its shots.
        var updatedShots: [StreamScreenshot] = []
        for var screenshot in screenshots where screenshot.albumIDs.contains(album.id) {
            screenshot.albumIDs.removeAll { $0 == album.id }
            if (try? StreamScreenshotLibrary.update(screenshot)) != nil {
                updatedShots.append(screenshot)
            }
        }
        for updated in updatedShots {
            if let index = screenshots.firstIndex(where: { $0.id == updated.id }) {
                screenshots[index] = updated
            }
        }
        if selectedAlbum == .album(album.id) { selectedAlbum = .all }
        message = "Deleted album \"\(album.name)\"."
    }

    func setAlbumMembership(_ screenshot: StreamScreenshot, album: ScreenshotAlbum, isMember: Bool) {
        guard let index = screenshots.firstIndex(where: { $0.id == screenshot.id }) else { return }
        var updated = screenshots[index]
        if isMember {
            guard !updated.albumIDs.contains(album.id) else { return }
            updated.albumIDs.append(album.id)
        } else {
            updated.albumIDs.removeAll { $0 == album.id }
        }
        do {
            try StreamScreenshotLibrary.update(updated)
        } catch {
            message = error.localizedDescription
            return
        }
        screenshots[index] = updated
        if selectedScreenshot?.id == updated.id { selectedScreenshot = updated }
        message = isMember ? "Added to \"\(album.name)\"." : "Removed from \"\(album.name)\"."
    }

    func isSelectedScreenshotMember(of album: ScreenshotAlbum) -> Bool {
        selectedScreenshot?.albumIDs.contains(album.id) ?? false
    }

    // MARK: - Mutations

    func rename(_ screenshot: StreamScreenshot, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != screenshot.title else { return }
        guard let index = screenshots.firstIndex(where: { $0.id == screenshot.id }) else { return }
        var updated = screenshots[index]
        updated.title = trimmed
        do {
            try StreamScreenshotLibrary.update(updated)
        } catch {
            message = error.localizedDescription
            return
        }
        screenshots[index] = updated
        if selectedScreenshot?.id == updated.id { selectedScreenshot = updated }
        message = "Renamed screenshot."
    }

    func deletePendingScreenshot() {
        guard let screenshot = pendingDelete else { return }
        pendingDelete = nil
        do {
            try StreamScreenshotLibrary.delete(screenshot)
        } catch {
            message = error.localizedDescription
            return
        }
        message = "Deleted \(screenshot.title)."
        reload(showMessage: false)
    }

    // MARK: - Desktop integration

    func reveal(_ screenshot: StreamScreenshot) {
        systemIntegration.revealInFinder(screenshot.imageURL)
        message = "Revealed \(screenshot.imageURL.lastPathComponent) in Finder."
    }

    func open(_ screenshot: StreamScreenshot) {
        systemIntegration.open(screenshot.imageURL)
        message = "Opened \(screenshot.imageURL.lastPathComponent)."
    }

    func copyPath(_ screenshot: StreamScreenshot) {
        systemIntegration.copyToPasteboard(screenshot.imageURL.path)
        copiedPathScreenshotID = screenshot.id
        message = "Copied screenshot path."
    }

    /// Drops the selection when its screenshot is no longer visible.
    func reconcileSelection(withVisibleIDs ids: [UUID]) {
        guard let selectedScreenshot, !ids.contains(selectedScreenshot.id) else { return }
        self.selectedScreenshot = visibleScreenshots.first
    }

    /// Pad navigation over the visible list: up/left and down/right walk the selection, confirm
    /// opens the highlighted shot. Selection already shows the image, so moving is enough to browse.
    func applyControllerCommand(_ command: ControllerInputCommand) {
        let screenshots = visibleScreenshots
        guard !screenshots.isEmpty else { return }
        guard let selectedScreenshot, let currentIndex = screenshots.firstIndex(where: { $0.id == selectedScreenshot.id }) else {
            self.selectedScreenshot = screenshots.first
            if case .confirm = command { open(screenshots[0]) }
            return
        }
        switch command {
        case .move(.up), .move(.left):
            let next = max(currentIndex - 1, 0)
            self.selectedScreenshot = screenshots[next]
        case .move(.down), .move(.right):
            let next = min(currentIndex + 1, screenshots.count - 1)
            self.selectedScreenshot = screenshots[next]
        case .confirm:
            open(selectedScreenshot)
        default:
            break
        }
    }
}
