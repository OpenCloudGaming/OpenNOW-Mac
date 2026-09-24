import Foundation

/// Per-launch auth timeline under `~/Library/Logs/OpenNOW/`. The unified log purges these events
/// within minutes, which left re-authentication reports undiagnosable after the fact.
public final class AuthDiagnosticLog: @unchecked Sendable {
    public static let shared = AuthDiagnosticLog()

    private let queue = DispatchQueue(label: "com.opennow.auth.diagnostic-log", qos: .utility)
    private let handle: FileHandle?
    public let url: URL?

    private static let retentionDays = 14.0
    public static let maxFileBytes = 4 * 1024 * 1024
    public static let maxDirectoryBytes = 32 * 1024 * 1024

    private var isFull = false
    private var bytesWritten = 0
    private let fileBudget: Int

    init(directory: URL? = nil,
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
        Self.prune(in: base, olderThanDays: Self.retentionDays, now: now)
        Self.pruneOverBudget(in: base, budget: directoryBudget)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let fileURL = base.appendingPathComponent("auth-\(formatter.string(from: now)).log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        url = handle == nil ? nil : fileURL
    }

    deinit {
        let handle = handle
        queue.sync {}
        try? handle?.close()
    }

    public func record(_ message: String, at date: Date = Date()) {
        guard let handle else { return }
        queue.async { [self] in
            guard !isFull else { return }
            let stamp = timestampFormatter.string(from: date)
            guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
            try? handle.write(contentsOf: data)
            bytesWritten += data.count
            guard bytesWritten >= fileBudget else { return }
            isFull = true
            let notice = "\(stamp) auth diagnostics log reached its \(fileBudget) byte ceiling; no further lines are recorded for this session.\n"
            if let noticeData = notice.data(using: .utf8) { try? handle.write(contentsOf: noticeData) }
        }
    }

    /// Only ever touched on the serial log queue.
    private nonisolated(unsafe) let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func pruneOverBudget(in directory: URL, budget: Int = maxDirectoryBytes) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let logs = files
            .filter { $0.lastPathComponent.hasPrefix("auth-") }
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

    private static func prune(in directory: URL, olderThanDays days: Double, now: Date) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix("auth-") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > days * 86_400 else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
