import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import OpenNOW

/// The pasteboard payloads behind Copy Image and Copy. Serialized because the general pasteboard is
/// one global resource and these tests read back exactly what they wrote.
@Suite(.serialized) @MainActor
struct SystemIntegrationPasteboardTests {
    private let integration = AppKitSystemIntegration()

    private func temporaryPNG(_ bytes: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pasteboard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shot.png")
        try bytes.write(to: url)
        return url
    }

    @Test func copyImageWritesPNGDataWithTheFileURL() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x03, 0x04])
        let url = try temporaryPNG(bytes)

        #expect(integration.copyImageToPasteboard(url))

        let pasteboard = NSPasteboard.general
        #expect(pasteboard.data(forType: .png) == bytes)
        #expect(pasteboard.string(forType: .fileURL) == url.absoluteString)
    }

    @Test func copyFileURLWritesAFileReference() throws {
        let url = try temporaryPNG(Data([0x00]))

        #expect(integration.copyFileURLToPasteboard(url))

        let pasteboard = NSPasteboard.general
        #expect(pasteboard.string(forType: .fileURL) == url.absoluteString)
        #expect(pasteboard.canReadItem(withDataConformingToTypes: [UTType.fileURL.identifier]))
    }

    @Test func copiesFailWhenTheFileIsGone() throws {
        let url = try temporaryPNG(Data([0x00]))
        try FileManager.default.removeItem(at: url)

        #expect(!integration.copyImageToPasteboard(url))
        #expect(!integration.copyFileURLToPasteboard(url))
    }
}
