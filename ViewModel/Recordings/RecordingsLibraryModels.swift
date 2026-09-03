//  How the recordings library is summarised, sorted and filtered. Moved out of `RecordingsView`
//  where these were `private`, so `RecordingsViewModel` can own the list state and tests can build
//  the shapes directly.
//
//  `RecordingLibraryStats` no longer formats its own subtitle: turning a date into "Latest: 3 days
//  ago" is presentation and stayed with the view's other formatters.
//

import Foundation

struct RecordingLibraryStats {
    let count: Int
    let totalDurationSeconds: Double
    let totalBytes: Int64
    let newest: WebRTCStreamRecording?

    init(recordings: [WebRTCStreamRecording]) {
        count = recordings.count
        totalDurationSeconds = recordings.reduce(0) { $0 + $1.durationSeconds }
        totalBytes = recordings.reduce(0) { $0 + $1.fileSizeBytes }
        newest = recordings.max { $0.createdAt < $1.createdAt }
    }
}

enum RecordingSortOrder: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case longest
    case largest
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .longest: return "Longest"
        case .largest: return "Largest"
        case .title: return "Title A-Z"
        }
    }
}

extension Array where Element == WebRTCStreamRecording {
    func sorted(using order: RecordingSortOrder) -> [WebRTCStreamRecording] {
        switch order {
        case .newest: return sorted { $0.createdAt > $1.createdAt }
        case .oldest: return sorted { $0.createdAt < $1.createdAt }
        case .longest: return sorted { $0.durationSeconds > $1.durationSeconds }
        case .largest: return sorted { $0.fileSizeBytes > $1.fileSizeBytes }
        case .title: return sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }
}

enum RecordingFilter: String, CaseIterable, Identifiable {
    case fourK
    case qhd
    case fullHD
    case enhanced
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fourK: return "4K"
        case .qhd: return "1440p+"
        case .fullHD: return "1080p+"
        case .enhanced: return "Enhanced"
        case .large: return "Large"
        }
    }

    var systemImage: String {
        switch self {
        case .fourK: return "4k.tv"
        case .qhd: return "display"
        case .fullHD: return "rectangle.inset.filled"
        case .enhanced: return "sparkles"
        case .large: return "externaldrive.fill"
        }
    }

    func matches(_ recording: WebRTCStreamRecording) -> Bool {
        switch self {
        case .fourK: return recording.width >= 3840 || recording.height >= 2160
        case .qhd: return recording.width >= 2560 || recording.height >= 1440
        case .fullHD: return recording.width >= 1920 || recording.height >= 1080
        case .enhanced: return recording.enhancedVideo
        case .large: return recording.fileSizeBytes >= 1_000_000_000
        }
    }
}
