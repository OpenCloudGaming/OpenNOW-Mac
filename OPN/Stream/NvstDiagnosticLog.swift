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
    /// A ceiling per session file and across the directory. Age alone did not bound anything: the
    /// transport writes counters every two seconds, so an hour of streaming is about 8 MB and a
    /// week of long sessions is hundreds of megabytes of logs nobody asked for.
    public static let maxFileBytes = 16 * 1024 * 1024
    public static let maxDirectoryBytes = 128 * 1024 * 1024
    /// Set once the file hits its ceiling, so the session stops writing rather than truncating a
    /// timeline that is being read from the top.
    private var isFull = false
    private var bytesWritten = 0
    private let fileBudget: Int

    public init(directory: URL? = nil,
                now: Date = Date(),
                fileBudget: Int = maxFileBytes,
                directoryBudget: Int = maxDirectoryBytes) {
        self.fileBudget = fileBudget
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
        Self.pruneLogsOverBudget(in: base, budget: directoryBudget)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let fileURL = base.appendingPathComponent("nvst-\(formatter.string(from: now)).log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        url = handle == nil ? nil : fileURL
    }

    deinit {
        // `append` enqueues, so a session that ends right after its last counter dump still has
        // writes in flight; closing the handle from under them dropped the end of every log.
        let handle = handle
        queue.sync {}
        try? handle?.close()
    }

    public func append(_ line: String, at date: Date = Date()) {
        guard let handle else { return }
        queue.async { [self] in
            guard !isFull else { return }
            let stamp = timestampFormatter.string(from: date)
            guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
            try? handle.write(contentsOf: data)
            bytesWritten += data.count
            guard bytesWritten >= fileBudget else { return }
            isFull = true
            let notice = "\(stamp) NVST diagnostics log reached its \(fileBudget) byte ceiling; no further lines are recorded for this session.\n"
            if let noticeData = notice.data(using: .utf8) { try? handle.write(contentsOf: noticeData) }
        }
    }

    /// Only ever touched on the serial log queue.
    private nonisolated(unsafe) let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Drops the oldest session logs until the directory is back under budget. Age-based pruning
    /// alone cannot bound a week of four-hour sessions.
    static func pruneLogsOverBudget(in directory: URL, budget: Int = maxDirectoryBytes) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let logs = files
            .filter { $0.lastPathComponent.hasPrefix("nvst-") }
            .compactMap { url -> (url: URL, modified: Date, size: Int)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modified = values.contentModificationDate, let size = values.fileSize else { return nil }
                return (url, modified, size)
            }
            .sorted { $0.modified > $1.modified }
        var total = 0
        for log in logs {
            total += log.size
            guard total > budget else { continue }
            try? FileManager.default.removeItem(at: log.url)
        }
    }

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
