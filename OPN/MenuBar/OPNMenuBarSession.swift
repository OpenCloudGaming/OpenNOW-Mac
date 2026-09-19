import Foundation

/// What the status item is showing. `streaming` carries nothing but the fact of the stream: the
/// start of a session is the moment `StreamSessionLifecycle` reported it, and the model holds that
/// stamp, so the elapsed readout cannot disagree with the session that is actually running.
enum OPNMenuBarSessionPhase: Equatable, Sendable {
    case idle
    case queued(position: Int)
    case connecting
    case streaming
}

/// A recently played game, reduced to what the menu shows and what launching one needs. The
/// artwork is the catalog's box art when the catalog knows this game, which it does whenever the
/// window that produced the list has loaded.
struct OPNMenuBarRecentGame: Equatable, Sendable, Identifiable {
    let title: String
    let appId: String
    let artworkURL: String?

    var id: String { appId.isEmpty ? title : appId }

    init(title: String, appId: String, artworkURL: String? = nil) {
        self.title = title
        self.appId = appId
        self.artworkURL = artworkURL
    }
}

/// Everything the surface needs from the window that owns the launch: the phase, the game it is
/// about, and the games the menu can relaunch. Pushed by the catalog view model; the menu bar owns
/// no launch state of its own.
struct OPNMenuBarSessionSnapshot: Equatable, Sendable {
    var phase: OPNMenuBarSessionPhase = .idle
    var title = ""
    var recentGames: [OPNMenuBarRecentGame] = []
}

/// A window that owns the launch flow: it describes an in-flight launch (so the menu bar can follow
/// it without the launch flow having to remember to notify anyone) and it can act on a launch
/// handed to it, which is the only way a game chosen from the menu reaches the vendor.
@MainActor
protocol OPNMenuBarSessionSource: AnyObject {
    var menuBarSnapshot: OPNMenuBarSessionSnapshot { get }
    func launchRecentGame(_ game: OPNMenuBarRecentGame)
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

    /// The popover's status line. Unlike the compressed status item it has room to say what idle and
    /// streaming mean, so it never falls back to an empty line.
    static func panelStatusText(for phase: OPNMenuBarSessionPhase, estimatedSeconds: TimeInterval?) -> String {
        switch phase {
        case .idle:
            return "No session running"
        case .streaming:
            return "Streaming now"
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
        case .streaming:
            return nil
        }
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
