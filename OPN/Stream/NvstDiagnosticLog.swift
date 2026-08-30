import Foundation

/// Durable file copy of the NVST stream diagnostics.
///
/// The transport's counter lines go to the unified log at info level, and macOS purges those
/// within minutes — the 120 FPS investigation lost a whole evening's counter timeline that way,
/// with a single tail sample surviving. This appends the same lines to a per-session file under
/// `~/Library/Logs/OpenNOW/` so the timeline can be read after the fact.
///
/// Writes happen on a utility queue; the caller's logging path never blocks on the filesystem.
public final class NvstDiagnosticLog: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.opennow.nvst.diagnostic-log", qos: .utility)
    private let handle: FileHandle?
    /// Where this session's log lives, for surfacing in the stream log itself.
    public let url: URL?

    private static let retentionDays = 7.0

    public init(directory: URL? = nil, now: Date = Date()) {
        let base = directory ?? FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/OpenNOW", isDirectory: true)
        guard let base else {
            handle = nil
            url = nil
            return
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        Self.pruneOldLogs(in: base, now: now)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let fileURL = base.appendingPathComponent("nvst-\(formatter.string(from: now)).log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        url = handle == nil ? nil : fileURL
    }

    deinit {
        try? handle?.close()
    }

    public func append(_ line: String, at date: Date = Date()) {
        guard let handle else { return }
        queue.async { [self] in
            let stamp = timestampFormatter.string(from: date)
            guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
            try? handle.write(contentsOf: data)
        }
    }

    /// Only ever touched on the serial log queue.
    private nonisolated(unsafe) let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func pruneOldLogs(in directory: URL, now: Date) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix("nvst-") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > retentionDays * 86_400 else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
