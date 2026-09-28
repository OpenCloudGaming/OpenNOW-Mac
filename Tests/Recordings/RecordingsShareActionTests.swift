import Foundation
import Testing
@testable import OpenNOW

/// The recording library's file actions. The view model must reach the desktop seam only for a file
/// that is still there, and must say so when it is not.
@MainActor
struct RecordingsShareActionTests {
    private func recording(directory: URL, fileName: String = "clip.mp4") -> StreamRecording {
        StreamRecording(
            id: UUID(),
            title: "Test Game",
            applicationID: "com.example.game",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 60,
            width: 1920,
            height: 1080,
            videoBitrateMbps: 40,
            audioBitrateKbps: 160,
            enhancedVideo: false,
            fileName: fileName,
            fileSizeBytes: 1_000,
            storageDirectoryPath: directory.path
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func shareHandsTheVideoToTheSystemShareSheet() throws {
        let directory = try temporaryDirectory()
        let video = directory.appendingPathComponent("clip.mp4")
        try Data([0x00]).write(to: video)
        let sample = recording(directory: directory)
        let spy = OPNSystemIntegrationSpy()
        let model = RecordingsViewModel(systemIntegration: spy)

        model.share(sample)

        #expect(spy.sharedURLs == [video])
        #expect(model.message == "Sharing clip.mp4.")
    }

    @Test func copyFilePutsTheFileOnThePasteboard() throws {
        let directory = try temporaryDirectory()
        let video = directory.appendingPathComponent("clip.mp4")
        try Data([0x00]).write(to: video)
        let sample = recording(directory: directory)
        let spy = OPNSystemIntegrationSpy()
        let model = RecordingsViewModel(systemIntegration: spy)

        model.copyFile(sample)

        #expect(spy.copiedFileURLs == [video])
        #expect(model.message == "Copied clip.mp4.")
    }

    @Test func everyNewActionRefusesAHiddenFromTheLibraryFile() throws {
        let directory = try temporaryDirectory()
        let sample = recording(directory: directory, fileName: "missing.mp4")
        let spy = OPNSystemIntegrationSpy()
        let model = RecordingsViewModel(systemIntegration: spy)

        #expect(model.quickLookURL(for: sample) == nil)
        model.share(sample)
        model.copyFile(sample)

        #expect(spy.sharedURLs.isEmpty)
        #expect(spy.copiedFileURLs.isEmpty)
        #expect(model.message == "missing.mp4 is no longer on disk.")
    }

    @Test func quickLookURLIsTheVideoWhileItExists() throws {
        let directory = try temporaryDirectory()
        let video = directory.appendingPathComponent("clip.mp4")
        try Data([0x00]).write(to: video)
        let sample = recording(directory: directory)
        let model = RecordingsViewModel(systemIntegration: OPNSystemIntegrationSpy())

        #expect(model.quickLookURL(for: sample) == video)
    }
}
