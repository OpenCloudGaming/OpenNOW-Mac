import Testing
import Foundation
@testable import OpenNOW

// Library filtering, sorting and summarising, extracted from RecordingsView in the MVVM migration.
// All of it used to be `private` inside a `View` and could only run inside a render.

private func makeRecording(
    title: String,
    application: String = "com.example.game",
    createdAt: Date,
    duration: Double = 60,
    width: Int = 1920,
    height: Int = 1080,
    enhanced: Bool = false,
    bytes: Int64 = 100_000_000,
    fileName: String = "clip.mp4"
) -> WebRTCStreamRecording {
    WebRTCStreamRecording(
        id: UUID(),
        title: title,
        applicationID: application,
        createdAt: createdAt,
        durationSeconds: duration,
        width: width,
        height: height,
        videoBitrateMbps: 40,
        audioBitrateKbps: 160,
        enhancedVideo: enhanced,
        fileName: fileName,
        fileSizeBytes: bytes,
        storageDirectoryPath: NSTemporaryDirectory()
    )
}

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

@Test func sortOrdersCoverEveryColumnTheUICanPick() {
    let older = makeRecording(title: "Beta", createdAt: epoch, duration: 30, bytes: 900)
    let newer = makeRecording(title: "Alpha", createdAt: epoch.addingTimeInterval(3600), duration: 120, bytes: 100)
    let list = [older, newer]

    #expect(list.sorted(using: .newest).first?.id == newer.id)
    #expect(list.sorted(using: .oldest).first?.id == older.id)
    #expect(list.sorted(using: .longest).first?.id == newer.id)
    #expect(list.sorted(using: .largest).first?.id == older.id)
    #expect(list.sorted(using: .title).first?.id == newer.id, "Alpha sorts before Beta")
}

@Test func resolutionFiltersMatchOnEitherAxis() {
    let uhd = makeRecording(title: "UHD", createdAt: epoch, width: 3840, height: 2160)
    let qhd = makeRecording(title: "QHD", createdAt: epoch, width: 2560, height: 1440)
    let hd = makeRecording(title: "HD", createdAt: epoch, width: 1280, height: 720)

    #expect(RecordingFilter.fourK.matches(uhd))
    #expect(RecordingFilter.fourK.matches(qhd) == false)
    #expect(RecordingFilter.qhd.matches(qhd))
    #expect(RecordingFilter.fullHD.matches(hd) == false)
    #expect(RecordingFilter.fullHD.matches(qhd))
}

@Test func enhancedAndLargeFiltersReadTheirOwnFields() {
    let plain = makeRecording(title: "Plain", createdAt: epoch, enhanced: false, bytes: 999_999_999)
    let enhanced = makeRecording(title: "Enhanced", createdAt: epoch, enhanced: true, bytes: 1_000_000_000)

    #expect(RecordingFilter.enhanced.matches(plain) == false)
    #expect(RecordingFilter.enhanced.matches(enhanced))
    #expect(RecordingFilter.large.matches(plain) == false, "the threshold is inclusive at 1 GB, not below it")
    #expect(RecordingFilter.large.matches(enhanced))
}

@Test @MainActor func searchMatchesTitleApplicationIdOrFileName() {
    let byTitle = makeRecording(title: "Manor Lords", createdAt: epoch)
    let byApp = makeRecording(title: "Other", application: "com.coffeestain.satisfactory", createdAt: epoch)
    let byFile = makeRecording(title: "Third", createdAt: epoch, fileName: "beamng-run.mp4")
    let all = [byTitle, byApp, byFile]

    func search(_ query: String) -> [UUID] {
        RecordingsViewModel.visibleRecordings(in: all, searchText: query, filters: [], sortOrder: .newest).map(\.id)
    }

    #expect(search("manor") == [byTitle.id], "match is case-insensitive")
    #expect(search("satisfactory") == [byApp.id], "the application id is searchable")
    #expect(search("beamng") == [byFile.id], "so is the file name")
    #expect(search("   ") .count == 3, "a whitespace-only query is not a filter")
    #expect(search("nothing-here").isEmpty)
}

@Test @MainActor func filtersCombineWithAndNotOr() {
    let both = makeRecording(title: "Both", createdAt: epoch, width: 3840, height: 2160, enhanced: true)
    let onlyUHD = makeRecording(title: "UHD only", createdAt: epoch, width: 3840, height: 2160, enhanced: false)

    let matched = RecordingsViewModel.visibleRecordings(
        in: [both, onlyUHD],
        searchText: "",
        filters: [.fourK, .enhanced],
        sortOrder: .newest
    )

    #expect(matched.map(\.id) == [both.id])
}

@Test @MainActor func searchAndFilterAndSortAllApplyTogether() {
    let a = makeRecording(title: "Run one", createdAt: epoch, width: 3840, height: 2160)
    let b = makeRecording(title: "Run two", createdAt: epoch.addingTimeInterval(60), width: 3840, height: 2160)
    let excluded = makeRecording(title: "Run three", createdAt: epoch.addingTimeInterval(120), width: 1280, height: 720)

    let matched = RecordingsViewModel.visibleRecordings(
        in: [a, b, excluded],
        searchText: "run",
        filters: [.fourK],
        sortOrder: .oldest
    )

    #expect(matched.map(\.id) == [a.id, b.id])
}

@Test func libraryStatsSumTheWholeLibraryAndNameTheNewest() {
    let older = makeRecording(title: "Older", createdAt: epoch, duration: 30, bytes: 1_000)
    let newer = makeRecording(title: "Newer", createdAt: epoch.addingTimeInterval(1), duration: 45, bytes: 2_000)

    let stats = RecordingLibraryStats(recordings: [older, newer])

    #expect(stats.count == 2)
    #expect(stats.totalDurationSeconds == 75)
    #expect(stats.totalBytes == 3_000)
    #expect(stats.newest?.id == newer.id)
}

@Test func libraryStatsHandleAnEmptyLibrary() {
    let stats = RecordingLibraryStats(recordings: [])

    #expect(stats.count == 0)
    #expect(stats.totalBytes == 0)
    #expect(stats.newest == nil)
}

@Test @MainActor func togglingAFilterAddsThenRemovesIt() {
    let model = RecordingsViewModel()

    model.toggleFilter(.enhanced)
    #expect(model.activeFilters == [.enhanced])

    model.toggleFilter(.fourK)
    #expect(model.activeFilters == [.enhanced, .fourK])

    model.toggleFilter(.enhanced)
    #expect(model.activeFilters == [.fourK])
}

@Test @MainActor func clearingResetsBothSearchAndFilters() {
    let model = RecordingsViewModel()
    model.searchText = "manor"
    model.activeFilters = [.fourK, .enhanced]

    model.clearSearchAndFilters()

    #expect(model.searchText.isEmpty)
    #expect(model.activeFilters.isEmpty)
}
