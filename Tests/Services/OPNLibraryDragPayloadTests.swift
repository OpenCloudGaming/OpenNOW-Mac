import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import OpenNOW

/// The drag-out contract for both libraries: a real file representation for external apps plus the
/// internal editor payload for recordings, and no file promise at all once the file is gone.
@Suite struct OPNLibraryDragPayloadTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drag-payload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func recording(id: UUID, directory: URL, fileName: String = "clip.mp4") -> StreamRecording {
        StreamRecording(
            id: id,
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

    private func screenshot(id: UUID, directory: URL, fileName: String = "shot.png") -> StreamScreenshot {
        StreamScreenshot(
            id: id,
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

    private func loadedData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// The exact load the editor timeline's drop delegate performs, so a representation change that
    /// silently broke the internal drop would fail here.
    private func loadedEditorPayload(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: object as? String)
            }
        }
    }

    private func loadedFile(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    @Test func recordingProviderCarriesBothTheEditorPayloadAndTheVideoFile() async throws {
        let directory = try temporaryDirectory()
        let id = UUID()
        let video = directory.appendingPathComponent("clip.mp4")
        try Data([0x00, 0x01, 0x02]).write(to: video)
        let provider = OPNLibraryDragPayload.recording(for: recording(id: id, directory: directory))

        let types = provider.registeredTypeIdentifiers
        #expect(types.contains(UTType.fileURL.identifier), "External apps need the file, not an opaque id")
        #expect(types.contains(UTType.utf8PlainText.identifier), "The editor drop still reads its custom payload")

        let text = try #require(await loadedData(provider, type: .utf8PlainText))
        #expect(String(data: text, encoding: .utf8) == RecordingEditorDragPayload.recording(id).stringValue)
        let payload = try #require(await loadedEditorPayload(provider))
        #expect(RecordingEditorDragPayload(stringValue: payload) == .recording(id))

        let file = try #require(await loadedFile(provider, type: .mpeg4Movie))
        #expect(try Data(contentsOf: file) == Data([0x00, 0x01, 0x02]))
    }

    @Test func recordingProviderKeepsTheEditorPayloadWhenTheVideoIsGone() throws {
        let directory = try temporaryDirectory()
        let id = UUID()
        let provider = OPNLibraryDragPayload.recording(for: recording(id: id, directory: directory, fileName: "missing.mp4"))

        #expect(provider.registeredTypeIdentifiers.contains(UTType.utf8PlainText.identifier))
        #expect(!provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier), "No file promise for a file that is gone")
    }

    @Test func screenshotProviderCarriesPNGDataAndTheFile() async throws {
        let directory = try temporaryDirectory()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
        try bytes.write(to: directory.appendingPathComponent("shot.png"))
        let provider = OPNLibraryDragPayload.screenshot(for: screenshot(id: UUID(), directory: directory))

        let types = provider.registeredTypeIdentifiers
        #expect(types.contains(UTType.png.identifier), "Messages gets an inline image")
        #expect(types.contains(UTType.fileURL.identifier), "Finder gets a file copy")

        #expect(try #require(await loadedData(provider, type: .png)) == bytes)
        let file = try #require(await loadedFile(provider, type: .png))
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func screenshotProviderIsEmptyWhenTheImageIsGone() throws {
        let directory = try temporaryDirectory()
        let provider = OPNLibraryDragPayload.screenshot(for: screenshot(id: UUID(), directory: directory, fileName: "missing.png"))

        #expect(provider.registeredTypeIdentifiers.isEmpty, "A deleted screenshot must not start an empty drag")
    }
}
