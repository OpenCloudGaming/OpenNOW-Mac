//  The in-stream clipboard history: text recognized off a captured frame, filed locally and capped.
//  A single JSON file in Application Support, following the screenshot metadata precedent, so the
//  store is a document the reader can find rather than a database, and nothing leaves the device.
//

import Foundation

/// One recognized frame's text. `id` is what a HUD row and a pad focus entry key off, so the row and
/// its focus entry cannot drift while the list re-sorts.
public struct StreamClipboardEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let capturedAt: Date
    public let applicationID: String
    public let gameTitle: String

    public init(id: UUID = UUID(), text: String, capturedAt: Date = Date(), applicationID: String, gameTitle: String) {
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
        self.applicationID = applicationID
        self.gameTitle = gameTitle
    }
}

/// The persisted history. An instance owns one file, so a test can point it at a temporary
/// directory and the app reads the shared one under Application Support.
public struct StreamClipboardHistoryStore: Sendable {
    /// FIFO cap. The oldest entry past this falls off the end of the list.
    public static let entryLimit = 100
    /// Identical text captured again inside this window is the same copy, not a second one — a
    /// double press or a held chord must not file the frame twice.
    public static let dedupeWindow: TimeInterval = 5 * 60

    public static let didChangeNotification = Notification.Name("OPNStreamClipboardHistoryDidChange")

    public static let shared = StreamClipboardHistoryStore(fileURL: defaultFileURL)

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Newest first, which is the order the HUD lists entries in.
    public func load() -> [StreamClipboardEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let entries = try? JSONDecoder.recordingDecoder.decode([StreamClipboardEntry].self, from: data) else { return [] }
        return entries.sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Files `text`, unless the same text was captured inside `dedupeWindow`. Returns the stored
    /// entry, or nil when it was a duplicate.
    @discardableResult
    public func append(
        text: String,
        applicationID: String,
        gameTitle: String,
        capturedAt: Date = Date(),
        dedupeWindow: TimeInterval = StreamClipboardHistoryStore.dedupeWindow
    ) -> StreamClipboardEntry? {
        let existing = load()
        guard !existing.contains(where: { $0.text == text && capturedAt.timeIntervalSince($0.capturedAt) < dedupeWindow }) else { return nil }
        let entry = StreamClipboardEntry(text: text, capturedAt: capturedAt, applicationID: applicationID, gameTitle: gameTitle)
        store([entry] + existing)
        return entry
    }

    /// Empties the history. The file stays in place, written as an empty list, so a reader who
    /// clears history does not then wonder whether the store was deleted.
    public func clear() {
        store([])
    }

    private func store(_ entries: [StreamClipboardEntry]) {
        let capped = Array(entries.sorted { $0.capturedAt > $1.capturedAt }.prefix(Self.entryLimit))
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.recordingEncoder.encode(capped)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            OPNLog.error(.stream, "Clipboard history write failed: \(error.localizedDescription)")
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent(OPNProductIdentity.releaseBundleIdentifier, isDirectory: true)
            .appendingPathComponent("ClipboardHistory.json")
    }
}

/// Whether in-stream copy files the selected text. Read by the capture path and written by Settings.
/// Two switches gate it: the Labs flag that offers the feature at all, and this page's toggle that
/// turns the trigger off while keeping whatever history is already filed.
public enum StreamTextCaptureSettings {
    public static let enabledKey = "OpenNOW.Stream.ClipboardCaptureEnabled"
    /// The trigger is on by default once the feature is on trial; `object(forKey:)` rather than
    /// `bool(forKey:)` so an untouched preference is not mistaken for the `false` an absent value
    /// would otherwise give.
    public static var isTriggerEnabled: Bool {
        get { OPNAppPreferenceStorage.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { OPNAppPreferenceStorage.standard.set(newValue, forKey: enabledKey) }
    }

    /// Both switches, because "inert" has to mean inert: a feature that its Labs flag has not
    /// offered yet must not fire even if a previous run left the toggle on.
    public static var isEnabled: Bool {
        OPNLabs.isClipboardCaptureEnabled && isTriggerEnabled
    }
}
