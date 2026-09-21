//  How the screenshot library is summarised, sorted and filtered, kept out of the view so the view
//  model owns the list state and tests can build the shapes directly. Mirrors the recordings
//  library models.
//

import Foundation

struct ScreenshotLibraryStats {
    let count: Int
    let totalBytes: Int64
    let newest: StreamScreenshot?
    let albumCount: Int

    init(screenshots: [StreamScreenshot], albums: [ScreenshotAlbum]) {
        count = screenshots.count
        totalBytes = screenshots.reduce(0) { $0 + $1.fileSizeBytes }
        newest = screenshots.max { $0.createdAt < $1.createdAt }
        albumCount = albums.count
    }
}

enum ScreenshotSortOrder: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case largest
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .largest: return "Largest"
        case .title: return "Title A-Z"
        }
    }
}

extension Array where Element == StreamScreenshot {
    func sorted(using order: ScreenshotSortOrder) -> [StreamScreenshot] {
        switch order {
        case .newest: return sorted { $0.createdAt > $1.createdAt }
        case .oldest: return sorted { $0.createdAt < $1.createdAt }
        case .largest: return sorted { $0.fileSizeBytes > $1.fileSizeBytes }
        case .title: return sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }
}

enum ScreenshotFilter: String, CaseIterable, Identifiable {
    case fourK
    case qhd
    case fullHD
    case wide
    case tall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fourK: return "4K+"
        case .qhd: return "1440p+"
        case .fullHD: return "1080p+"
        case .wide: return "Landscape"
        case .tall: return "Portrait"
        }
    }

    var systemImage: String {
        switch self {
        case .fourK: return "4k.tv"
        case .qhd: return "display"
        case .fullHD: return "rectangle.inset.filled"
        case .wide: return "rectangle"
        case .tall: return "rectangle.portrait"
        }
    }

    func matches(_ screenshot: StreamScreenshot) -> Bool {
        switch self {
        case .fourK: return screenshot.width >= 3840 || screenshot.height >= 2160
        case .qhd: return screenshot.width >= 2560 || screenshot.height >= 1440
        case .fullHD: return screenshot.width >= 1920 || screenshot.height >= 1080
        case .wide: return screenshot.width > screenshot.height
        case .tall: return screenshot.height > screenshot.width
        }
    }
}
