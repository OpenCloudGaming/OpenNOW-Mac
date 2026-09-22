import Foundation
import Testing
@testable import OpenNOW

/// The screenshot library is a directory scan plus filter/sort/album logic; these build the shapes
/// directly rather than touching the real Pictures folder.
@MainActor
struct ScreenshotLibraryTests {

    private func screenshot(
        id: UUID = UUID(),
        title: String,
        applicationID: String = "100",
        createdAt: Date,
        width: Int = 1920,
        height: Int = 1080,
        fileSizeBytes: Int64 = 1_000_000,
        albumIDs: [UUID] = []
    ) -> StreamScreenshot {
        StreamScreenshot(
            id: id,
            title: title,
            applicationID: applicationID,
            createdAt: createdAt,
            width: width,
            height: height,
            fileName: id.uuidString + ".png",
            fileSizeBytes: fileSizeBytes,
            albumIDs: albumIDs,
            storageDirectoryPath: "/tmp"
        )
    }

    @Test func newestSortIsDefaultOrder() {
        let older = screenshot(title: "Older", createdAt: Date(timeIntervalSince1970: 100))
        let newer = screenshot(title: "Newer", createdAt: Date(timeIntervalSince1970: 200))
        let sorted = [older, newer].sorted(using: .newest)
        #expect(sorted.map(\.title) == ["Newer", "Older"])
    }

    @Test func largestSortUsesFileSize() {
        let small = screenshot(title: "Small", createdAt: .now, fileSizeBytes: 10)
        let large = screenshot(title: "Large", createdAt: .now, fileSizeBytes: 10_000)
        #expect([small, large].sorted(using: .largest).map(\.title) == ["Large", "Small"])
    }

    @Test func resolutionFiltersMatchTheirTier() {
        let fourK = screenshot(title: "4K", createdAt: .now, width: 3840, height: 2160)
        let hd = screenshot(title: "HD", createdAt: .now, width: 1920, height: 1080)
        #expect(ScreenshotFilter.fourK.matches(fourK))
        #expect(!ScreenshotFilter.fourK.matches(hd))
        #expect(ScreenshotFilter.qhd.matches(fourK))
        #expect(ScreenshotFilter.fullHD.matches(hd))
    }

    @Test func orientationFiltersSplitOnAspect() {
        let wide = screenshot(title: "Wide", createdAt: .now, width: 1920, height: 1080)
        let tall = screenshot(title: "Tall", createdAt: .now, width: 1080, height: 1920)
        #expect(ScreenshotFilter.wide.matches(wide))
        #expect(!ScreenshotFilter.wide.matches(tall))
        #expect(ScreenshotFilter.tall.matches(tall))
    }

    @Test func albumSelectionScopesTheVisibleList() {
        let albumID = UUID()
        let file = screenshot(title: "Filed", createdAt: .now, albumIDs: [albumID])
        let loose = screenshot(title: "Loose", createdAt: .now)
        let all = [file, loose]

        let unfiled = ScreenshotsViewModel.visibleScreenshots(in: all, album: .unfiled, searchText: "", filters: [], sortOrder: .newest)
        #expect(unfiled.map(\.title) == ["Loose"])

        let inAlbum = ScreenshotsViewModel.visibleScreenshots(in: all, album: .album(albumID), searchText: "", filters: [], sortOrder: .newest)
        #expect(inAlbum.map(\.title) == ["Filed"])

        let everything = ScreenshotsViewModel.visibleScreenshots(in: all, album: .all, searchText: "", filters: [], sortOrder: .newest)
        #expect(everything.count == 2)
    }

    @Test func searchMatchesTitleAndApplicationID() {
        let rocket = screenshot(title: "Rocket Launch", applicationID: "100", createdAt: .now)
        let other = screenshot(title: "Menu", applicationID: "200", createdAt: .now)
        let byTitle = ScreenshotsViewModel.visibleScreenshots(in: [rocket, other], album: .all, searchText: "rocket", filters: [], sortOrder: .newest)
        #expect(byTitle.map(\.title) == ["Rocket Launch"])
        let byApp = ScreenshotsViewModel.visibleScreenshots(in: [rocket, other], album: .all, searchText: "200", filters: [], sortOrder: .newest)
        #expect(byApp.map(\.title) == ["Menu"])
    }

    @Test func statsCountBytesAlbumsAndNewest() {
        let older = screenshot(title: "Older", createdAt: Date(timeIntervalSince1970: 100), fileSizeBytes: 5)
        let newer = screenshot(title: "Newer", createdAt: Date(timeIntervalSince1970: 200), fileSizeBytes: 10)
        let album = ScreenshotAlbum(id: UUID(), name: "Trips", createdAt: .now)
        let stats = ScreenshotLibraryStats(screenshots: [older, newer], albums: [album])
        #expect(stats.count == 2)
        #expect(stats.totalBytes == 15)
        #expect(stats.albumCount == 1)
        #expect(stats.newest?.title == "Newer")
    }

    @Test func emptyStatsHaveNoNewest() {
        let stats = ScreenshotLibraryStats(screenshots: [], albums: [])
        #expect(stats.count == 0)
        #expect(stats.totalBytes == 0)
        #expect(stats.newest == nil)
    }

    @Test func libraryWritesAnnounceTheChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let recorder = ScreenshotChangeRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: StreamScreenshotLibrary.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in recorder.count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let id = UUID()
        let shot = StreamScreenshot(
            id: id,
            title: "Shot",
            applicationID: "100",
            createdAt: .now,
            width: 1920,
            height: 1080,
            fileName: id.uuidString + ".png",
            fileSizeBytes: 1_000_000,
            albumIDs: [],
            storageDirectoryPath: directory.path
        )

        try StreamScreenshotLibrary.update(shot)
        #expect(recorder.count == 1)

        try StreamScreenshotLibrary.delete(shot)
        #expect(recorder.count == 2)
    }
}

private final class ScreenshotChangeRecorder: @unchecked Sendable {
    var count = 0
}
