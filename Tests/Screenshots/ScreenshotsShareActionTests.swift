import Foundation
import Testing
@testable import OpenNOW

/// The screenshot library's file actions, including the Copy Image payload path and its honest
/// failure when the image can no longer be read.
@MainActor
struct ScreenshotsShareActionTests {
    private func screenshot(directory: URL, fileName: String = "shot.png") -> StreamScreenshot {
        StreamScreenshot(
            id: UUID(),
            title: "Test Shot",
            applicationID: "100",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            width: 1920,
            height: 1080,
            fileName: fileName,
            fileSizeBytes: 1_000,
            albumIDs: [],
            storageDirectoryPath: directory.path
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func copyImageMarksTheScreenshotItCopied() throws {
        let directory = try temporaryDirectory()
        let image = directory.appendingPathComponent("shot.png")
        try Data([0x00]).write(to: image)
        let sample = screenshot(directory: directory)
        let spy = OPNSystemIntegrationSpy()
        let model = ScreenshotsViewModel(systemIntegration: spy)

        model.copyImage(sample)

        #expect(spy.copiedImageURLs == [image])
        #expect(model.copiedPathScreenshotID == sample.id)
        #expect(model.message == "Copied shot.png.")
    }

    @Test func copyImageReportsAReadFailureWithoutClaimingSuccess() throws {
        let directory = try temporaryDirectory()
        let image = directory.appendingPathComponent("shot.png")
        try Data([0x00]).write(to: image)
        let sample = screenshot(directory: directory)
        let spy = OPNSystemIntegrationSpy()
        spy.isCopyImageSuccessful = false
        let model = ScreenshotsViewModel(systemIntegration: spy)

        model.copyImage(sample)

        #expect(model.copiedPathScreenshotID == nil)
        #expect(model.message == "OpenNOW could not read this screenshot.")
    }

    @Test func shareRefusesAFileThatIsGone() throws {
        let directory = try temporaryDirectory()
        let sample = screenshot(directory: directory, fileName: "missing.png")
        let spy = OPNSystemIntegrationSpy()
        let model = ScreenshotsViewModel(systemIntegration: spy)

        model.share(sample)

        #expect(spy.sharedURLs.isEmpty)
        #expect(model.message == "missing.png is no longer on disk.")
    }

    @Test func quickLookReturnsNothingForAFileThatIsGone() throws {
        let directory = try temporaryDirectory()
        let sample = screenshot(directory: directory, fileName: "missing.png")
        let model = ScreenshotsViewModel(systemIntegration: OPNSystemIntegrationSpy())

        #expect(model.quickLookURL(for: sample) == nil)
        #expect(model.message == "missing.png is no longer on disk.")
    }
}
