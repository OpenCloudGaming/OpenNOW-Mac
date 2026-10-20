//  The polite VoiceOver sequence for DLSS compatibility lookups. An announcement describes a
//  semantic transition, never a render, and the app owns only what it queued.

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
        guard !text.isEmpty, let application = NSApp, application.isActive else { return }
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

/// Owns at most one pending start and one pending outcome per lookup cycle. Timing is independent of
/// speech: the start is held for 500 ms and outcomes coalesce for 200 ms.
@MainActor
public final class OPNDlssCompatibilityAnnouncer {
    public static let startDelay: TimeInterval = 0.5
    public static let outcomeCoalescingDelay: TimeInterval = 0.2

    private let scheduler: DlssAnnouncementScheduling
    private let post: @MainActor (String) -> Void

    private var cycle = 0
    private var isActive = false
    private var isStartScheduled = false
    private var isStartSubmitted = false
    private var isRecoveryAnnounced = false
    private var isFailureReported = false
    private var lastSubmittedAnnouncement: String?
    private var pendingStart: DlssAnnouncementTicket?
    private var pendingOutcome: DlssAnnouncementTicket?

    public init(
        scheduler: DlssAnnouncementScheduling = DlssMainQueueScheduler(),
        post: @escaping @MainActor (String) -> Void = { DlssVoiceOver.post($0) }
    ) {
        self.scheduler = scheduler
        self.post = post
    }

    /// A new lookup cycle for a newly selected game, or an explicit retry. Anything still queued from
    /// the previous cycle is dropped, and results arriving for it are ignored.
    public func beginCycle() {
        cancelPendingAnnouncements()
        isActive = true
        cycle += 1
        resetCycleState()
    }

    /// The section closed, another game was selected, or the app lost focus. Queued announcements are
    /// cancelled and never replayed on return.
    public func endCycle() {
        cancelPendingAnnouncements()
        isActive = false
        cycle += 1
        resetCycleState()
    }

    public func handle(_ transition: DlssCompatibilityTransition, isAutomaticRetry: Bool = false) {
        // Outside a live cycle nothing is announced: a late result updates the section silently.
        guard isActive else { return }
        guard !transition.isStart else {
            handleStart(transition, isAutomaticRetry: isAutomaticRetry)
            return
        }
        guard !isAutomaticRetry else {
            handleAutomaticRetryOutcome(transition)
            return
        }
        submitOutcome(transition)
    }

    private func handleStart(_ transition: DlssCompatibilityTransition, isAutomaticRetry: Bool) {
        // A background retry announcing its own start every sixty seconds is noise.
        guard !isAutomaticRetry, !isStartScheduled else { return }
        isStartScheduled = true
        scheduleStartAnnouncement(transition)
    }

    private func handleAutomaticRetryOutcome(_ transition: DlssCompatibilityTransition) {
        // A retry's failure is recorded even though it is silent, so a later success can be told
        // apart from a first answer.
        guard !transition.isFailure else {
            isFailureReported = true
            return
        }
        guard transition.isSuccess, !isRecoveryAnnounced else { return }
        guard isStartSubmitted || isFailureReported || lastSubmittedAnnouncement != nil else { return }
        isRecoveryAnnounced = true
        submitOutcome(transition)
    }

    private func submitOutcome(_ transition: DlssCompatibilityTransition) {
        guard lastSubmittedAnnouncement != transition.announcement else { return }
        if transition.isFailure { isFailureReported = true }
        // A result cancels a start that has not been handed over yet, and replaces an outcome that has
        // not been handed over yet.
        pendingStart?.cancel()
        pendingStart = nil
        pendingOutcome?.cancel()
        let token = cycle
        pendingOutcome = scheduler.schedule(after: Self.outcomeCoalescingDelay) { [weak self] in
            guard let self, self.cycle == token else { return }
            self.pendingOutcome = nil
            self.lastSubmittedAnnouncement = transition.announcement
            self.post(transition.announcement)
        }
    }

    private func scheduleStartAnnouncement(_ transition: DlssCompatibilityTransition) {
        pendingStart?.cancel()
        let token = cycle
        pendingStart = scheduler.schedule(after: Self.startDelay) { [weak self] in
            guard let self, self.cycle == token else { return }
            self.pendingStart = nil
            self.isStartSubmitted = true
            self.post(transition.announcement)
        }
    }

    private func resetCycleState() {
        isStartScheduled = false
        isStartSubmitted = false
        isRecoveryAnnounced = false
        isFailureReported = false
        lastSubmittedAnnouncement = nil
    }

    private func cancelPendingAnnouncements() {
        pendingStart?.cancel()
        pendingStart = nil
        pendingOutcome?.cancel()
        pendingOutcome = nil
    }
}
