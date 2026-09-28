//  The in-stream clipboard history: text read off a captured frame, filed locally and capped.
//

import Foundation

/// One recognized frame's text. `id` keys both the HUD row and its pad focus entry.
public struct StreamClipboardEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// Mutable so a clipped read is completed in place rather than leaving two fragments behind.
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

/// The persisted history, as one JSON file in Application Support.
public struct StreamClipboardHistoryStore: Sendable {
    /// FIFO cap; the oldest entry past this falls off the end.
    public static let entryLimit = 100
    /// Identical text inside this window is the same copy, not a second one.
    public static let dedupeWindow: TimeInterval = 5 * 60

    public static let didChangeNotification = Notification.Name("OPNStreamClipboardHistoryDidChange")

    public static let shared = StreamClipboardHistoryStore(fileURL: defaultFileURL)

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Newest first, which is the order the HUD lists entries in.
    public func load() -> [StreamClipboardEntry] {
        guard let storedData = try? Data(contentsOf: fileURL) else { return [] }
        guard let entries = try? JSONDecoder.recordingDecoder.decode([StreamClipboardEntry].self, from: storedData) else { return [] }
        return entries.sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Files `text`, unless the same text was captured inside `dedupeWindow`.
    @discardableResult
    public func append(
        text: String,
        applicationID: String,
        gameTitle: String,
        capturedAt: Date = Date(),
        dedupeWindow: TimeInterval = StreamClipboardHistoryStore.dedupeWindow
    ) -> StreamClipboardEntry? {
        guard !isDuplicate(text, capturedAt: capturedAt, dedupeWindow: dedupeWindow) else { return nil }
        let entry = StreamClipboardEntry(text: text, capturedAt: capturedAt, applicationID: applicationID, gameTitle: gameTitle)
        store([entry] + load())
        return entry
    }

    /// Replaces one entry's text, keeping its place and its capture time.
    @discardableResult
    public func replace(id: UUID, text: String) -> StreamClipboardEntry? {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        entries[index].text = text
        store(entries)
        return entries[index]
    }

    /// Drops one entry, answering false when it was already gone.
    @discardableResult
    public func remove(id: UUID) -> Bool {
        let entries = load()
        guard entries.contains(where: { $0.id == id }) else { return false }
        store(entries.filter { $0.id != id })
        return true
    }

    /// Empties the history, leaving the file in place as an empty list.
    public func clear() {
        store([])
    }

    private func isDuplicate(_ text: String, capturedAt: Date, dedupeWindow: TimeInterval) -> Bool {
        load().contains { $0.text == text && capturedAt.timeIntervalSince($0.capturedAt) < dedupeWindow }
    }

    private func store(_ entries: [StreamClipboardEntry]) {
        let cappedEntries = Array(entries.sorted { $0.capturedAt > $1.capturedAt }.prefix(Self.entryLimit))
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encodedEntries = try JSONEncoder.recordingEncoder.encode(cappedEntries)
            try encodedEntries.write(to: fileURL, options: .atomic)
        } catch {
            OPNLog.error(.stream, "Clipboard history write failed: \(error.localizedDescription)")
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private static var defaultFileURL: URL {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return supportDirectory
            .appendingPathComponent(OPNProductIdentity.releaseBundleIdentifier, isDirectory: true)
            .appendingPathComponent("ClipboardHistory.json")
    }
}

/// What pressing copy in a stream does.
public enum StreamTextCaptureMode: String, CaseIterable, Identifiable, Sendable {
    /// Inert: the copy is left entirely to the game.
    case off
    /// Read the text the reader has highlighted.
    case selection
    /// Freeze the frame and read the area the reader drags over it.
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

/// How in-stream copy reads text: the Labs flag offers the feature, the mode says what it reads.
public enum StreamTextCaptureSettings {
    public static let modeKey = "OpenNOW.Stream.ClipboardCaptureMode"
    /// The on/off preference the mode replaced, read once so an old choice still decides.
    public static let enabledKey = "OpenNOW.Stream.ClipboardCaptureEnabled"

    public static var mode: StreamTextCaptureMode {
        get { storedMode ?? legacyMode }
        set { OPNAppPreferenceStorage.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// Whether the capture path runs at all.
    public static var isEnabled: Bool {
        OPNLabs.isClipboardCaptureEnabled && mode != .off
    }

    private static var storedMode: StreamTextCaptureMode? {
        guard let rawMode = OPNAppPreferenceStorage.standard.string(forKey: modeKey) else { return nil }
        return StreamTextCaptureMode(rawValue: rawMode)
    }

    /// A reader who had turned capture off keeps Off; everyone else lands on the selection read.
    private static var legacyMode: StreamTextCaptureMode {
        let wasEnabled = OPNAppPreferenceStorage.standard.object(forKey: enabledKey) as? Bool ?? true
        return wasEnabled ? .selection : .off
    }
}
