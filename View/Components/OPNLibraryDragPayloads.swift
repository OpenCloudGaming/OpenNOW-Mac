import AppKit
import UniformTypeIdentifiers

/// The item providers the two capture libraries drag out with: a real file representation for
/// Finder, Mail and Messages, the editor payload for recordings, and inline PNG for screenshots.
enum OPNLibraryDragPayload {
    static func recording(for recording: StreamRecording) -> NSItemProvider {
        let provider = fileProvider(at: recording.videoURL) ?? NSItemProvider()
        registerText(on: provider, value: RecordingEditorDragPayload.recording(recording.id).stringValue)
        return provider
    }

    static func screenshot(for screenshot: StreamScreenshot) -> NSItemProvider {
        let provider = fileProvider(at: screenshot.imageURL) ?? NSItemProvider()
        registerPNG(on: provider, at: screenshot.imageURL)
        return provider
    }

    /// The provider `NSItemProvider` builds for the file itself. Nil once the file is gone, so a
    /// missing capture never promises the drop target an empty file.
    private static func fileProvider(at url: URL) -> NSItemProvider? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSItemProvider(contentsOf: url)
    }

    private static func registerPNG(on provider: NSItemProvider, at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(try? Data(contentsOf: url), nil)
            return nil
        }
    }

    private static func registerText(on provider: NSItemProvider, value: String) {
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
            completion(value.data(using: .utf8), nil)
            return nil
        }
    }
}
