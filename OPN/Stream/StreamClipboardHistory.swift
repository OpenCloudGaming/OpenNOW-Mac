//  The in-stream clipboard history: text recognized off a captured frame, filed locally and capped.
//  A single JSON file in Application Support, following the screenshot metadata precedent, so the
//  store is a document the reader can find rather than a database, and nothing leaves the device.
//

import Foundation

/// One recognized frame's text. `id` is what a HUD row and a pad focus entry key off, so the row and
/// its focus entry cannot drift while the list re-sorts.
public struct StreamClipboardEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// Mutable so a clipped read can be completed in place when the reader copies the rest of it,
    /// rather than leaving two fragments in the history.
    public var text: String
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

    /// Replaces one entry's text, keeping its place and its capture time. Used when a clipped read
    /// is joined with the rest of the same text: the reader gets one entry, not two fragments.
    @discardableResult
    public func replace(id: UUID, text: String) -> StreamClipboardEntry? {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        entries[index].text = text
        store(entries)
        return entries[index]
    }

    /// Drops one entry. Returns false when it was already gone, so a double press is not an error.
    @discardableResult
    public func remove(id: UUID) -> Bool {
        let entries = load()
        guard entries.contains(where: { $0.id == id }) else { return false }
        store(entries.filter { $0.id != id })
        return true
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

/// What pressing copy in a stream does.
public enum StreamTextCaptureMode: String, CaseIterable, Identifiable, Sendable {
    /// Inert: the copy is left entirely to the game.
    case off
    /// Read the text the reader has highlighted — the selection highlight, or the rectangle they
    /// dragged over it.
    case selection
    /// Freeze the frame and read the area the reader drags over it, the way ⌘⇧4 works for the screen.
    case region

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: "Off"
        case .selection: "Selection"
        case .region: "Region"
        }
    }

    /// What the mode reads, for the Settings row and the HUD caption.
    public var summary: String {
        switch self {
        case .off: "Copy is left to the game."
        case .selection: "Reads the text you have selected."
        case .region: "Freezes the frame and reads the area you drag."
        }
    }
}

/// How in-stream copy reads text. Read by the capture path and written by Settings and the HUD.
/// Two switches gate it: the Labs flag that offers the feature at all, and this mode — which also
/// covers off, so "inert" is one answer in one place rather than a flag and a toggle to reconcile.
public enum StreamTextCaptureSettings {
    public static let modeKey = "OpenNOW.Stream.ClipboardCaptureMode"
    /// The on/off preference this replaced. Still read once so a reader who turned capture off before
    /// the mode existed lands on Off rather than back on.
    public static let enabledKey = "OpenNOW.Stream.ClipboardCaptureEnabled"

    public static var mode: StreamTextCaptureMode {
        get {
            if let raw = OPNAppPreferenceStorage.standard.string(forKey: modeKey),
               let mode = StreamTextCaptureMode(rawValue: raw) {
                return mode
            }
            // No mode stored yet: the old boolean decides, defaulting to the selection read that was
            // the only capture there was.
            let wasOn = OPNAppPreferenceStorage.standard.object(forKey: enabledKey) as? Bool ?? true
            return wasOn ? .selection : .off
        }
        set { OPNAppPreferenceStorage.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// Whether the capture path runs at all: the Labs flag has to offer the feature before any mode,
    /// including Region, means anything.
    public static var isEnabled: Bool {
        OPNLabs.isClipboardCaptureEnabled && mode != .off
    }
}
