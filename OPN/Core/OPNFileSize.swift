//  One place that asks the filesystem how big a file is, so the replay ring, the retained store and
//  the editor cannot disagree about it.
//

import Foundation

extension URL {
    /// The file's size on disk in bytes, or zero when it cannot be read.
    var fileSizeBytes: Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
