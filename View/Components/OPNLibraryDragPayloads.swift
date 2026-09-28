import AppKit
import UniformTypeIdentifiers

/// The item providers the two capture libraries drag out with.
///
/// Each one carries a real file representation, so Finder, Mail and Messages receive the captured
/// file. The recording provider also keeps its `RecordingEditorDragPayload` text representation, so
/// a drop on the editor timeline behaves exactly as it did before the file representation existed.
/// The screenshot provider adds inline PNG data, so Messages pastes the picture rather than a file.
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

    /// The provider `NSItemProvider` builds for the file itself, which advertises the file's own type
    /// beside `public.file-url`. Nil once the file is gone: an item provider that promises a missing
    /// file hands the target an empty drop rather than failing where the reader can see it.
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
