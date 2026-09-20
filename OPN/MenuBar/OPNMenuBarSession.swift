import Foundation

/// What the status item is showing. `streaming` carries nothing but the fact of the stream: the
/// start of a session is the moment `StreamSessionLifecycle` reported it, and the model holds that
/// stamp, so the elapsed readout cannot disagree with the session that is actually running.
///
/// `starting` is the window between a launch and its first frame — the launch overlay's allocate,
/// offer, and negotiate steps. It is deliberately separate from `queued`, which is a measured wait
/// with a position to report, and from `streaming`, which means frames are arriving. The stream
/// surface registers itself with the lifecycle as soon as it is mounted, so the lifecycle alone
/// cannot draw that line; the launch flow's snapshot can.
enum OPNMenuBarSessionPhase: Equatable, Sendable {
    case idle
    case queued(position: Int)
    case connecting
    case starting
    case streaming

    /// Whether a seat is being acquired right now, rather than merely being connected to.
    var isQueued: Bool {
        if case .queued = self { return true }
        return false
    }

    /// The queue position as it appears beside the status item's mark, or nil when there is no queue.
    ///
    /// The number only, deliberately: the ETA is a projection that changes on every queue poll —
    /// six seconds apart at the vendor's cadence — and text that changes that often is exactly what
    /// the status item's native renderer must not be driven by. A position that changes only when
    /// the seat advances is cheap to redraw. The ETA stays in the popover, where it can be read
    /// without resizing the status item.
    var menuBarQueueCountText: String? {
        guard case let .queued(position) = self, position > 0 else { return nil }
        return String(position)
    }

    /// The cloud mark: hollow when nothing streams, the hourglass while a seat is being acquired,
    /// the spinner while the stream itself is starting, filled once a stream is running.
    var symbolName: String {
        switch self {
        case .idle: return "cloud"
        case .queued, .connecting: return "hourglass"
        case .starting: return "arrow.triangle.2.circlepath"
        case .streaming: return "cloud.fill"
        }
    }
}

/// A recently played game, reduced to what the menu shows and what launching one needs. The
/// artwork is the catalog's box art when the catalog knows this game, which it does whenever the
/// window that produced the list has loaded.
struct OPNMenuBarRecentGame: Equatable, Sendable, Identifiable {
    let title: String
    let appId: String
    let artworkURL: String?
    /// When this account last played the game, for the row's subtitle. Nil when the local history
    /// carries no timestamp for it, which renders as a title-only row rather than a placeholder.
    let lastPlayedAt: Date?

    var id: String { appId.isEmpty ? title : appId }

    init(title: String, appId: String, artworkURL: String? = nil, lastPlayedAt: Date? = nil) {
        self.title = title
        self.appId = appId
        self.artworkURL = artworkURL
        self.lastPlayedAt = lastPlayedAt
    }
}

/// Everything the surface needs from the window that owns the launch: the phase, the game it is
/// about, the games the menu can relaunch, and the title of a cloud session that exists but is not
/// streaming locally. Pushed by the catalog view model; the menu bar owns no launch state of its own.
struct OPNMenuBarSessionSnapshot: Equatable, Sendable {
    var phase: OPNMenuBarSessionPhase = .idle
    var title = ""
    var recentGames: [OPNMenuBarRecentGame] = []
    /// A resumable session detected while nothing streams locally — a seat this Mac paused, or one
    /// another device is holding. Nil when there is nothing to resume.
    var resumableSessionTitle: String?
}

/// One of the main window's pages, for a surface outside the window to ask for by name. A reduction
/// of `CatalogMainPage` rather than that type itself: the surfaces that ask are in the service layer,
/// and only the two pages they can reach are worth naming here.
enum OPNMainWindowPage: Equatable, Sendable {
    /// Where a session is started: the catalog home.
    case home
    /// The recording library, where an export the Dock reported progress for can be found again.
    case recordings
}

/// A window that owns the launch flow: it describes an in-flight launch (so the menu bar can follow
/// it without the launch flow having to remember to notify anyone) and it can act on a launch
/// handed to it, which is the only way a game chosen from the menu reaches the vendor.
///
/// Every surface outside the window goes through this bridge — the menu bar and the Dock menu both —
/// so there is one answer to "where does a request from outside the window land", and one place that
/// parks it while no window can act on it.
@MainActor
protocol OPNMenuBarSessionSource: AnyObject {
    var menuBarSnapshot: OPNMenuBarSessionSnapshot { get }
    func launchRecentGame(_ game: OPNMenuBarRecentGame)
    /// Resumes the resumable session the snapshot named, the same action the home page offers.
    func resumeSession()
    /// Re-checks for a resumable session, so opening the menu reflects a session started elsewhere
    /// since the catalog last looked.
    func refreshActiveSession()
    /// Brings one of the window's own pages forward. A page belongs to the window and nothing outside
    /// it can put one on screen, so the surface asks rather than acts.
    func showMainPage(_ page: OPNMainWindowPage)
}

/// How long the seat queue is likely to take from here.
///
/// The vendor reports the position, never an estimate, so the number comes from what this queue has
/// actually done: seconds per position advanced, smoothed, projected onto the positions left. A
/// queue that has not moved yet has nothing to project from and falls back to
/// `defaultSecondsPerPosition`.
///
/// UNVERIFIED: no capture in this repository records a real queue's advance rate, and the fallback
/// is a stated approximation rather than a measurement. Settle it by sitting in a queue with the
/// menu bar open and comparing the projection against the clock.
struct OPNMenuBarQueueEstimate: Sendable {
    static let defaultSecondsPerPosition: TimeInterval = 45
    /// Each measured observation moves the rate by this fraction of the way to the new value, so
    /// one slow poll cannot swing the readout.
    static let smoothingFraction = 0.35
    private static let minimumSampleSeconds: TimeInterval = 1

    private var secondsPerPosition: TimeInterval?
    private var sample: (position: Int, at: Date)?

    mutating func observe(position: Int, now: Date) {
        guard position > 0 else {
            reset()
            return
        }
        defer { sample = (position, now) }
        guard let sample, position < sample.position else { return }
        let elapsed = now.timeIntervalSince(sample.at)
        guard elapsed >= Self.minimumSampleSeconds else { return }
        let measured = elapsed / Double(sample.position - position)
        secondsPerPosition = secondsPerPosition.map { $0 + (measured - $0) * Self.smoothingFraction } ?? measured
    }

    mutating func reset() {
        secondsPerPosition = nil
        sample = nil
    }

    /// Seconds left at `position`, or nil when the queue is already empty. Rounded to half a minute:
    /// a status item is not the place to report a projection to the second.
    func remainingSeconds(for position: Int) -> TimeInterval? {
        guard position > 0 else { return nil }
        let raw = (secondsPerPosition ?? Self.defaultSecondsPerPosition) * Double(position)
        return max(30, (raw / 30).rounded() * 30)
    }
}

/// The wording of the status item and of the menu bar item's accessibility label.
enum OPNMenuBarReadout {
    static func titleText(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "OpenNOW" : trimmed
    }

    /// The detail next to the title. Streaming shows a ticking clock instead of words, so it has
    /// nothing to say here.
    /// The popover's title line, or nil when there is no game to name. The status item keeps the
    /// `OpenNOW` fallback because an empty label is invisible; the popover has an icon and a status
    /// line already, so naming the app above "No session running" only repeats itself.
    static func panelTitleText(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The popover's status line while a resumable session is offered but nothing streams locally.
    static let resumableStatusText = "Available to resume"

    /// The popover's status line. Unlike the compressed status item it has room to say what idle and
    /// streaming mean, so it never falls back to an empty line.
    static func panelStatusText(for phase: OPNMenuBarSessionPhase, estimatedSeconds: TimeInterval?) -> String {
        switch phase {
        case .idle:
            return "No session running"
        case .streaming:
            return "Streaming now"
        case .starting:
            return "Starting stream…"
        case .queued, .connecting:
            return detailText(for: phase, estimatedSeconds: estimatedSeconds) ?? "Connecting…"
        }
    }

    static func detailText(for phase: OPNMenuBarSessionPhase, estimatedSeconds: TimeInterval?) -> String? {
        switch phase {
        case .idle:
            return nil
        case let .queued(position):
            let positionText = "Queue #\(position)"
            guard let estimatedSeconds else { return positionText }
            return "\(positionText) · \(durationText(seconds: estimatedSeconds))"
        case .connecting:
            return "Connecting…"
        case .starting:
            return "Starting…"
        case .streaming:
            return nil
        }
    }

    /// The subtitle under a Continue Playing row: how long ago the game was last played, or nil when
    /// the history has no date for it. Named style, so a game just left reads "now" rather than
    /// "0 seconds ago" and yesterday reads "yesterday" rather than "1 day ago".
    static func lastPlayedText(for date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func elapsedText(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start).rounded(.down)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        guard hours > 0 else { return String(format: "%d:%02d", minutes, remainder) }
        return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }

    /// A wait under a minute is reported in seconds; anything longer rounds up to whole minutes, so
    /// the readout never promises less time than the estimate allows.
    static func durationText(seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "~\(Int(seconds.rounded())) sec" }
        return "~\(Int((seconds / 60).rounded())) min"
    }

    /// VoiceOver reads the label as a sentence: the compressed status item is unreadable speech.
    static func spokenSummary(
        phase: OPNMenuBarSessionPhase,
        title: String,
        estimatedSeconds: TimeInterval?,
        startedAt: Date?,
        now: Date
    ) -> String {
        let game = titleText(title)
        switch phase {
        case .idle:
            return "OpenNOW, no session"
        case let .queued(position):
            guard let estimatedSeconds else { return "\(game), in queue at position \(position)" }
            return "\(game), in queue at position \(position), about \(spokenDuration(seconds: estimatedSeconds)) to go"
        case .connecting:
            return "\(game), connecting"
        case .starting:
            return "\(game), starting"
        case .streaming:
            guard let startedAt else { return "\(game), streaming" }
            return "\(game), streaming, \(spokenDuration(seconds: now.timeIntervalSince(startedAt))) elapsed"
        }
    }

    static func spokenDuration(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if remainder > 0 || parts.isEmpty { parts.append("\(remainder) second\(remainder == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }
}
