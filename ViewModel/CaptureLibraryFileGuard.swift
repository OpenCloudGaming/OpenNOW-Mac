import Foundation

/// Both capture libraries scan their folder at load, so a file action can find the file already
/// moved or deleted. One guard keeps that failure to a single honest sentence.
@MainActor
protocol CaptureLibraryFileGuard: AnyObject {
    var message: String { get set }
}

extension CaptureLibraryFileGuard {
    func isFileOnDisk(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            message = "\(url.lastPathComponent) is no longer on disk."
            return false
        }
        return true
    }
}

extension RecordingsViewModel: CaptureLibraryFileGuard {}
extension ScreenshotsViewModel: CaptureLibraryFileGuard {}
