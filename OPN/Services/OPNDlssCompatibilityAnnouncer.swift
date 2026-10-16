//  The polite VoiceOver sequence for DLSS compatibility lookups.
//
//  Two rules shape this. First, an announcement describes a semantic transition, never a render:
//  re-renders, spinner ticks, a timestamp-only refresh and chip insertion must all stay silent.
//  Second, the app owns only what it queued - submission is not proof of speech, and AppKit exposes
//  no verified way to withdraw an utterance VoiceOver has already taken. So a start that has not
//  been submitted yet is cancelled when the result arrives, while a start already submitted is left
//  to finish and the outcome follows politely behind it.
//
//  Timing is deliberately independent of speech: the start is held for 500 ms so a fast answer
//  replaces it, and outcomes coalesce for 200 ms so a burst of state changes reads as one update.

import AppKit
import Foundation

/// Every announcement the compatibility section can make, as a transition rather than a string.
public enum DlssCompatibilityTransition: Equatable, Sendable {
    case initialLookupStarted
    case initialLookupSucceeded
    case initialLookupUnknown
    case refreshStarted
    case refreshSucceeded
    case refreshSucceededUnknown
    case refreshFailedWithSavedData
    case lookupFailedWithoutSavedData

    public var announcement: String {
        switch self {
        case .initialLookupStarted: "Checking DLSS compatibility."
        case .initialLookupSucceeded: "DLSS compatibility available."
        case .initialLookupUnknown: "DLSS compatibility unknown."
        case .refreshStarted: "Updating DLSS compatibility. Showing saved information."
        case .refreshSucceeded: "DLSS compatibility updated."
        case .refreshSucceededUnknown: "DLSS compatibility updated. Compatibility is unknown."
        case .refreshFailedWithSavedData: "Couldn't update DLSS compatibility. Showing saved information."
        case .lookupFailedWithoutSavedData: "DLSS compatibility information unavailable."
        }
    }

    public var isStart: Bool {
        self == .initialLookupStarted || self == .refreshStarted
    }

    /// Whether the outcome reported confirmed compatibility. Used to tell a meaningful recovery
    /// from a repeat.
    public var isSuccess: Bool {
        switch self {
        case .initialLookupSucceeded, .refreshSucceeded, .refreshSucceededUnknown: true
        default: false
        }
    }

    public var isFailure: Bool {
        self == .refreshFailedWithSavedData || self == .lookupFailedWithoutSavedData
    }
}

/// One scheduled announcement, cancellable until it fires.
@MainActor
public final class DlssAnnouncementTicket {
    private var cancelAction: (() -> Void)?

    public init(cancel: @escaping () -> Void) {
        self.cancelAction = cancel
    }

    public func cancel() {
        cancelAction?()
        cancelAction = nil
    }

    public var isPending: Bool { cancelAction != nil }
}

@MainActor
public protocol DlssAnnouncementScheduling: AnyObject {
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> DlssAnnouncementTicket
}

/// The live scheduler. Work lands on the main queue because the announcement is a UI action.
@MainActor
public final class DlssMainQueueScheduler: DlssAnnouncementScheduling {
    public init() {}

    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> DlssAnnouncementTicket {
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return DlssAnnouncementTicket { item.cancel() }
    }
}

/// Posts one announcement. `NSAccessibility` is the only supported channel, and it offers no
/// retraction, so nothing here tries to withdraw what it already handed over.
@MainActor
public enum DlssVoiceOver {
    public static func post(_ text: String) {
        guard !text.isEmpty, let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

/// Owns at most one pending start and one pending outcome per lookup cycle.
@MainActor
public final class OPNDlssCompatibilityAnnouncer {
    public static let startDelay: TimeInterval = 0.5
    public static let outcomeCoalescingDelay: TimeInterval = 0.2

    private let scheduler: DlssAnnouncementScheduling
    private let post: @MainActor (String) -> Void

    private var cycle = 0
    private var pendingStart: DlssAnnouncementTicket?
    private var pendingOutcome: DlssAnnouncementTicket?
    private var isActive = false
    private var startScheduled = false
    private var submittedStart = false
    private var submittedOutcome: String?
    private var announcedRecovery = false
    private var reportedFailure = false

    public init(
        scheduler: DlssAnnouncementScheduling = DlssMainQueueScheduler(),
        post: @escaping @MainActor (String) -> Void = { DlssVoiceOver.post($0) }
    ) {
        self.scheduler = scheduler
        self.post = post
    }

    /// A new lookup cycle for a newly selected game, or an explicit retry. Anything still queued
    /// from the previous cycle is dropped, and results arriving for it are ignored.
    public func beginCycle() {
        cancelPending()
        isActive = true
        cycle += 1
        startScheduled = false
        submittedStart = false
        submittedOutcome = nil
        announcedRecovery = false
        reportedFailure = false
    }

    /// The section closed, another game was selected, or the app lost focus. Queued announcements
    /// are cancelled and never replayed on return.
    public func endCycle() {
        cancelPending()
        isActive = false
        cycle += 1
        startScheduled = false
        submittedStart = false
        submittedOutcome = nil
        announcedRecovery = false
        reportedFailure = false
    }

    public func handle(_ transition: DlssCompatibilityTransition, isAutomaticRetry: Bool = false) {
        // Nothing is announced outside a live cycle: a result that lands after the surface closed
        // updates the section silently instead of being replayed on the next visit.
        guard isActive else { return }
        if transition.isStart {
            // A background retry announcing its own start every sixty seconds is noise.
            guard !isAutomaticRetry, !startScheduled else { return }
            startScheduled = true
            scheduleStart(transition)
            return
        }
        if isAutomaticRetry {
            // A retry's failure is recorded even though it is not spoken, so a later success can be
            // told apart from a first answer.
            if transition.isFailure {
                reportedFailure = true
                return
            }
            guard transition.isSuccess, !announcedRecovery else { return }
            // Nothing was ever said for this cycle, so there is no recovery to describe.
            guard submittedStart || reportedFailure || submittedOutcome != nil else { return }
            announcedRecovery = true
        }
        if transition.isFailure { reportedFailure = true }
        // A result cancels a start that has not been handed over yet, and replaces an outcome that
        // has not been handed over yet. An identical repeat is dropped rather than spoken twice.
        guard submittedOutcome != transition.announcement else { return }
        pendingStart?.cancel()
        pendingStart = nil
        pendingOutcome?.cancel()
        let token = cycle
        pendingOutcome = scheduler.schedule(after: Self.outcomeCoalescingDelay) { [weak self] in
            guard let self, self.cycle == token else { return }
            self.pendingOutcome = nil
            self.submittedOutcome = transition.announcement
            self.post(transition.announcement)
        }
    }

    private func scheduleStart(_ transition: DlssCompatibilityTransition) {
        pendingStart?.cancel()
        let token = cycle
        pendingStart = scheduler.schedule(after: Self.startDelay) { [weak self] in
            guard let self, self.cycle == token else { return }
            self.pendingStart = nil
            self.submittedStart = true
            self.post(transition.announcement)
        }
    }

    private func cancelPending() {
        pendingStart?.cancel()
        pendingStart = nil
        pendingOutcome?.cancel()
        pendingOutcome = nil
    }
}
