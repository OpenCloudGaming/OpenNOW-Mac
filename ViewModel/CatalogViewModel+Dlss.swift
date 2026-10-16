//  The catalog's side of cloud DLSS: the global override the settings card edits, the membership
//  state that decides what may be requested, and the selected game's compatibility presentation.
//
//  Everything here describes a request. Nothing in this file claims an override is active, and
//  nothing in it touches the stream HUD.

import Foundation

/// Where the BETA tag belongs, in one place. The tag qualifies OpenNOW's integration, so it rides
/// the two headings that present that integration - never the Video destination, never the other
/// feature rows, and never the compact compatibility chip.
enum DlssBetaScope {
    static let cardTitle = "Cloud DLSS Overrides"
    static let sectionTitle = "DLSS Compatibility"
    static let cardHeadingAccessibilityLabel = "Cloud DLSS Overrides, Beta"
    static let sectionHeadingAccessibilityLabel = "DLSS Compatibility, Beta"
    static let chipLabel = "DLSS"

    /// The surfaces that carry the tag. The compact chip is listed as untagged so a future change
    /// that tags it has to change this list deliberately.
    static let taggedSurfaces = [cardTitle, sectionTitle]
    static let untaggedSurfaces = ["Video destination", "Compact compatibility chip", "Feature rows"]

    static func isTagged(_ surface: String) -> Bool {
        taggedSurfaces.contains(surface)
    }
}

/// Everything the Cloud DLSS Overrides card renders, derived from the saved preference and the
/// membership state so every combination is assertable without standing up a view.
struct DlssSettingsState: Equatable, Sendable {
    /// The card's one-line status: signed out, still checking, or what the controls will do.
    var statusText: String
    var superResolutionEnabled: Bool
    var frameGenerationEnabled: Bool
    /// Dynamic frame generation additionally needs at least one multiplier in the membership.
    var dynamicFrameGenerationEnabled: Bool
    var rayReconstructionEnabled: Bool
    /// Multipliers the membership includes, ascending. Empty when frame generation is not included.
    var allowedMultipliers: [Int]
    /// Features the membership lacks but NVIDIA upsells, in display order.
    var upsellFeatureLabels: [String]
    /// Whether the "Next session request" summary is meaningful yet.
    var showsSummary: Bool
    var summaryText: String
    /// True while a stream is live, so an edit says it applies to the next session rather than now.
    var showsNextSessionOnlyNote: Bool
    var overrides: DlssOverrides

    static let descriptionText = "Runs on the GeForce NOW cloud rig. Applies when your next session starts."
    static let betaHelpText = "OpenNOW's DLSS integration is in beta. Availability and results depend on the game, membership, and cloud rig."
    static let signedOutText = "Sign in to check DLSS override availability."
    static let membershipLoadingText = "Checking your membership…"
    static let missingAccessText = "Not included with your membership."
    static let nextSessionOnlyText = "Saved for your next session. Your current stream is unchanged."
    static let summaryHeading = "Next session request"
    static let resetActionTitle = "Use game settings"

    static func make(overrides: DlssOverrides, membership: DlssMembershipState, isStreamRunning: Bool) -> DlssSettingsState {
        let entitlements = membership.entitlements
        let statusText: String
        if membership.isSignedOut {
            statusText = signedOutText
        } else if membership.isLoading {
            statusText = membershipLoadingText
        } else if !entitlements.hasAnyEntitlement {
            statusText = missingAccessText
        } else {
            statusText = descriptionText
        }
        return DlssSettingsState(
            statusText: statusText,
            superResolutionEnabled: entitlements.superResolution.isEntitled,
            frameGenerationEnabled: entitlements.frameGeneration.isEntitled,
            dynamicFrameGenerationEnabled: entitlements.supportsDynamicFrameGeneration,
            rayReconstructionEnabled: entitlements.rayReconstruction.isEntitled,
            allowedMultipliers: entitlements.allowedFrameGenerationMultipliers,
            upsellFeatureLabels: entitlements.upsellFeatureLabels,
            showsSummary: entitlements.hasAnyEntitlement,
            summaryText: overrides.applyingAccess(entitlements).nextSessionRequestSummary,
            showsNextSessionOnlyNote: isStreamRunning,
            overrides: overrides
        )
    }
}

@MainActor
extension CatalogViewModel {
    /// The card's derived state. Reads the live stream flag so an edit made mid-stream says so.
    var dlssSettingsState: DlssSettingsState {
        DlssSettingsState.make(overrides: dlssOverrides, membership: dlssMembershipState, isStreamRunning: isStreamRunning)
    }

    /// The three-way model preset the per-feature pickers sit under. "Custom" whenever the features
    /// disagree, which is also what a per-feature edit produces.
    var dlssModelPreset: DlssModelPreset.Choice {
        let overrides = dlssOverrides.normalized()
        let models = [overrides.superResolutionModel, overrides.frameGenerationModel, overrides.rayReconstructionModel]
        if models.allSatisfy({ $0 == 0 }) { return .inGame }
        if models.allSatisfy({ $0 == 1 }) { return .recommended }
        return .custom
    }

    // MARK: - Writers

    func setDlssSuperResolutionMode(_ mode: DlssSuperResolutionMode) {
        guard dlssMembershipState.entitlements.superResolution.isEntitled else { return }
        var overrides = dlssOverrides
        overrides.superResolutionMode = mode.rawValue
        overrides.superResolutionScale = mode.fixedInputScale ?? overrides.superResolutionScale
        // Naming a mode is naming an override, so a model left to the game has to be raised with it.
        if mode != .inGame, overrides.superResolutionModel == 0 { overrides.superResolutionModel = 1 }
        saveDlssOverrides(overrides)
    }

    func setDlssSuperResolutionScale(_ scale: Int) {
        guard dlssMembershipState.entitlements.superResolution.isEntitled else { return }
        var overrides = dlssOverrides
        overrides.superResolutionMode = DlssSuperResolutionMode.custom.rawValue
        overrides.superResolutionScale = scale
        if overrides.superResolutionModel == 0 { overrides.superResolutionModel = 1 }
        saveDlssOverrides(overrides)
    }

    func setDlssSuperResolutionModel(_ model: Int) {
        guard dlssMembershipState.entitlements.superResolution.isEntitled else { return }
        var overrides = dlssOverrides
        overrides.superResolutionModel = model
        if model == 0 {
            overrides.superResolutionMode = 0
            overrides.superResolutionScale = DlssSuperResolutionMode.inGame.fixedInputScale ?? 100
        }
        saveDlssOverrides(overrides)
    }

    func setDlssFrameGenerationMode(_ mode: DlssFrameGenerationMode) {
        let entitlements = dlssMembershipState.entitlements
        guard entitlements.frameGeneration.isEntitled else { return }
        guard mode != .dynamic || entitlements.supportsDynamicFrameGeneration else { return }
        var overrides = dlssOverrides
        overrides.frameGenerationMode = mode.rawValue
        if mode == .inGame {
            overrides.frameGenerationMultiplier = 0
        } else {
            if overrides.frameGenerationModel == 0 { overrides.frameGenerationModel = 1 }
            let allowed = entitlements.allowedFrameGenerationMultipliers
            if !allowed.contains(overrides.frameGenerationMultiplier) {
                overrides.frameGenerationMultiplier = allowed.min() ?? DlssOverrides.frameGenerationMultipliers[0]
            }
        }
        saveDlssOverrides(overrides)
    }

    func setDlssFrameGenerationMultiplier(_ multiplier: Int) {
        let entitlements = dlssMembershipState.entitlements
        guard entitlements.frameGeneration.isEntitled, entitlements.allowedFrameGenerationMultipliers.contains(multiplier) else { return }
        var overrides = dlssOverrides
        overrides.frameGenerationMode = DlssFrameGenerationMode.dynamic.rawValue
        overrides.frameGenerationMultiplier = multiplier
        if overrides.frameGenerationModel == 0 { overrides.frameGenerationModel = 1 }
        saveDlssOverrides(overrides)
    }

    func setDlssFrameGenerationModel(_ model: Int) {
        guard dlssMembershipState.entitlements.frameGeneration.isEntitled else { return }
        var overrides = dlssOverrides
        overrides.frameGenerationModel = model
        if model == 0 {
            overrides.frameGenerationMode = 0
            overrides.frameGenerationMultiplier = 0
        }
        saveDlssOverrides(overrides)
    }

    func setDlssRayReconstructionModel(_ model: Int) {
        guard dlssMembershipState.entitlements.rayReconstruction.isEntitled else { return }
        var overrides = dlssOverrides
        overrides.rayReconstructionModel = model
        saveDlssOverrides(overrides)
    }

    /// The model preset above the per-feature pickers. It writes every feature the membership
    /// includes, so the three stay in step.
    func setDlssModelPreset(_ preset: DlssModelPreset.Choice) {
        let entitlements = dlssMembershipState.entitlements
        guard entitlements.hasAnyEntitlement else { return }
        var overrides = dlssOverrides
        switch preset {
        case .inGame:
            if entitlements.superResolution.isEntitled {
                overrides.superResolutionModel = 0
                overrides.superResolutionMode = 0
                overrides.superResolutionScale = DlssSuperResolutionMode.inGame.fixedInputScale ?? 100
            }
            if entitlements.frameGeneration.isEntitled {
                overrides.frameGenerationModel = 0
                overrides.frameGenerationMode = 0
                overrides.frameGenerationMultiplier = 0
            }
            if entitlements.rayReconstruction.isEntitled { overrides.rayReconstructionModel = 0 }
        case .recommended:
            if entitlements.superResolution.isEntitled { overrides.superResolutionModel = 1 }
            if entitlements.frameGeneration.isEntitled { overrides.frameGenerationModel = 1 }
            if entitlements.rayReconstruction.isEntitled { overrides.rayReconstructionModel = 1 }
        case .custom:
            break
        }
        saveDlssOverrides(overrides)
    }

    func resetDlssOverrides() {
        saveDlssOverrides(.useGameSettings)
    }

    private func saveDlssOverrides(_ overrides: DlssOverrides) {
        OPNStreamPreferences.saveDlssOverrides(overrides)
        dlssOverrides = overrides
    }

    // MARK: - Compatibility

    /// The compact chip the detail panel may wear for this game. Nil until the lookup has answered
    /// for this exact game, so an unknown or still-loading title gets no empty placeholder pill.
    func dlssCompactChip(for game: OPNCatalogGameObject) -> DlssCompatibilityPresentation.CompactChip? {
        guard dlssCompatibilityGameKey == game.catalogIdentity else { return nil }
        return dlssCompatibility.compactChip
    }

    /// Leaves the details page for the Video destination's DLSS card. The selection is kept, so
    /// returning to the catalog lands back on the game the reader came from.
    func configureGlobalDlssOverrides() {
        closeGameInfo()
        showSettings(.video)
        pendingSettingsSectionID = "dlss"
    }

    /// Starts (or joins) the lookup for the game whose details are open. The UI's bounded wait is
    /// the first 1.5 seconds; a slow download finishes in the background and replaces the result
    /// once, and a failure leaves the saved copy in place.
    func beginDlssCompatibilityLookup(for game: OPNCatalogGameObject) {
        let key = game.catalogIdentity
        guard !dlssLookupActive || dlssCompatibilityGameKey != key else { return }
        dlssLookupTask?.cancel()
        dlssLookupActive = true
        dlssAnnouncer.beginCycle()
        if dlssCompatibilityGameKey != key {
            // A different game is a genuinely new cycle: the previous presentation and its queued
            // announcements both belong to a game that is no longer on screen.
            dlssCompatibilityGameKey = key
            dlssLastSnapshot = nil
            dlssCompatibility = .checking
            dlssAnnouncer.handle(.initialLookupStarted)
        }
        dlssCompatibilityIsWaiting = true
        let title = game.title
        dlssLookupTask = Task { [weak self] in
            guard let self else { return }
            let service = self.dlssCompatibilityService
            _ = await service.index(waitingUpTo: DlssCompatibilityLimits.presentationWait)
            guard !Task.isCancelled, self.dlssCompatibilityGameKey == key else { return }
            let snapshot = await service.currentSnapshot(forTitle: title)
            self.applyDlssSnapshot(snapshot, key: key)
            self.dlssCompatibilityIsWaiting = false
            guard !snapshot.hasSavedData else { return }
            // No usable data yet. Wait for the background attempt so a slow first download still
            // lands, and so a failure can replace the loading state.
            await service.awaitPendingRefresh()
            guard !Task.isCancelled, self.dlssCompatibilityGameKey == key else { return }
            let recovered = await service.currentSnapshot(forTitle: title)
            self.applyDlssSnapshot(recovered, key: key)
        }
    }

    /// The details surface closed, the page changed, or the app went to the background. Timers stop
    /// and queued announcements are dropped; a result that lands afterwards still updates the
    /// section, but silently.
    func endDlssCompatibilityLookup() {
        dlssLookupTask?.cancel()
        dlssLookupTask = nil
        dlssLookupActive = false
        dlssCompatibilityIsWaiting = false
        dlssAnnouncer.endCycle()
    }

    /// The app lost focus. Timers stop; the lookup result, if it lands, is applied without an
    /// announcement because the cycle is over.
    func suspendDlssAnnouncements() {
        dlssAnnouncer.endCycle()
    }

    private func applyDlssSnapshot(_ snapshot: OPNDlssCompatibilityService.Snapshot, key: String) {
        guard dlssCompatibilityGameKey == key else { return }
        let previous = dlssLastSnapshot
        dlssLastSnapshot = snapshot
        dlssCompatibility = DlssCompatibilityPresentation.make(snapshot)
        // A re-read that returns exactly what was already shown is not a transition, so nothing is
        // announced for it: that is what keeps re-renders and timestamp-only refreshes silent.
        guard previous != snapshot else { return }
        announceDlssTransition(from: previous, to: snapshot)
    }

    /// Only real transitions are announced. A re-render, a spinner tick or a footer timestamp
    /// never reaches this, and an outcome whose text repeats what was already said is dropped by
    /// the announcer itself.
    private func announceDlssTransition(from previous: OPNDlssCompatibilityService.Snapshot?, to current: OPNDlssCompatibilityService.Snapshot) {
        guard current.listState != .loading else { return }
        guard let previous else {
            announceFirstSnapshot(current)
            return
        }
        if previous.listState != .refreshing, current.listState == .refreshing {
            dlssAnnouncer.handle(.refreshStarted)
            return
        }
        announceOutcome(from: previous, to: current)
    }

    private func announceFirstSnapshot(_ current: OPNDlssCompatibilityService.Snapshot) {
        switch current.listState {
        case .refreshing:
            dlssAnnouncer.handle(.refreshStarted)
        case .unavailable:
            dlssAnnouncer.handle(.lookupFailedWithoutSavedData)
        case .refreshFailed:
            dlssAnnouncer.handle(.refreshFailedWithSavedData)
        case .ready, .stale:
            dlssAnnouncer.handle(outcomeTransition(matched: current.outcome.isMatched, hadSavedData: false))
        case .loading:
            break
        }
    }

    private func announceOutcome(from previous: OPNDlssCompatibilityService.Snapshot, to current: OPNDlssCompatibilityService.Snapshot) {
        switch current.listState {
        case .refreshFailed:
            dlssAnnouncer.handle(.refreshFailedWithSavedData)
        case .unavailable:
            dlssAnnouncer.handle(.lookupFailedWithoutSavedData)
        case .loading:
            break
        case .ready, .refreshing, .stale:
            // A refresh that lands on the same result is a timestamp-only update: the footer
            // moves, nothing is spoken. A first answer is always an outcome, even when it is
            // "unknown"; so is a changed result, and a recovery from a failure the reader was told
            // about.
            let firstAnswer = !previous.hasSavedData && current.hasSavedData
            let changed = previous.outcome.isMatched != current.outcome.isMatched
            let recovers = previous.listState == .refreshFailed || previous.listState == .unavailable
            guard firstAnswer || changed || recovers else { return }
            dlssAnnouncer.handle(outcomeTransition(matched: current.outcome.isMatched, hadSavedData: previous.hasSavedData))
        }
    }

    private func outcomeTransition(matched: Bool, hadSavedData: Bool) -> DlssCompatibilityTransition {
        if hadSavedData {
            return matched ? .refreshSucceeded : .refreshSucceededUnknown
        }
        return matched ? .initialLookupSucceeded : .initialLookupUnknown
    }
}
