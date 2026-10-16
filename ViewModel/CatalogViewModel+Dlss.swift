//  The catalog's side of cloud DLSS: the global override the settings card edits, the membership
//  state that decides what may be requested, and the selected game's compatibility presentation.

import Foundation

/// Where the BETA tag belongs, in one place. The tag qualifies OpenNOW's integration, so it rides the
/// two headings that present that integration and nothing else.
enum DlssBetaScope {
    static let cardTitle = "Cloud DLSS Overrides"
    static let sectionTitle = "DLSS Compatibility"
    static let cardHeadingAccessibilityLabel = "Cloud DLSS Overrides, Beta"
    static let sectionHeadingAccessibilityLabel = "DLSS Compatibility, Beta"
    static let chipLabel = "DLSS"

    /// The surfaces that carry the tag. The untagged list is stated so extending the tag is a
    /// deliberate edit rather than a local judgement.
    static let taggedSurfaces = [cardTitle, sectionTitle]
    static let untaggedSurfaces = ["Video destination", "Compact compatibility chip", "Feature rows"]

    static func isTagged(_ surface: String) -> Bool {
        taggedSurfaces.contains(surface)
    }
}

/// Every string the DLSS surfaces show, so the settings card and the game info section agree on the
/// account's state and on what a missing entitlement means.
enum DlssAccessCopy {
    static let description = "Runs on the GeForce NOW cloud rig. Applies when your next session starts."
    static let betaHelp = "OpenNOW's DLSS integration is in beta. Availability and results depend on the game, membership, and cloud rig."
    static let signedOut = "Sign in to check DLSS override availability."
    static let membershipLoading = "Checking your membership…"
    static let missing = "Not included with your membership."
    static let upsell = "Not included with your membership. Your membership can add it."
    static let included = "Included with your membership"
    static let nextSessionOnly = "Saved for your next session. Your current stream is unchanged."
    static let summaryHeading = "Next session request"
    static let resetAction = "Use game settings"
    static let notIncludedList = "Not included: %@. A membership with these overrides unlocks them."

    /// The card's one-line status.
    static func statusText(for membership: DlssMembershipState) -> String {
        guard !membership.isSignedOut else { return signedOut }
        guard !membership.isLoading else { return membershipLoading }
        guard membership.entitlements.hasAnyEntitlement else { return missing }
        return description
    }

    /// One feature's membership position, which is separate from what the game supports.
    static func accessText(for feature: DlssCompatibilityFeature, membership: DlssMembershipState) -> String {
        guard !membership.isSignedOut else { return signedOut }
        guard !membership.isLoading else { return membershipLoading }
        let capability = membership.entitlements.capability(for: feature)
        guard capability.isEntitled else { return capability.isUpsell ? upsell : missing }
        return included
    }

    /// The account's multiplier ceiling, which is separate from the maximum NVIDIA lists.
    static func multiplierAccessText(for membership: DlssMembershipState) -> String {
        guard !membership.isSignedOut else { return signedOut }
        guard !membership.isLoading else { return membershipLoading }
        let entitlements = membership.entitlements
        guard entitlements.frameGeneration.isEntitled, let highest = entitlements.highestAllowedFrameGenerationMultiplier else {
            return missing
        }
        return "Your membership includes up to \(highest)×."
    }

    static func notIncludedList(_ labels: [String]) -> String {
        String(format: notIncludedList, labels.joined(separator: ", "))
    }
}

/// Everything the Cloud DLSS Overrides card renders, derived from the saved preference and the
/// membership state so every combination is assertable without standing up a view.
struct DlssSettingsState: Equatable, Sendable {
    let statusText: String
    let isSuperResolutionEnabled: Bool
    let isFrameGenerationEnabled: Bool
    /// Dynamic frame generation additionally needs at least one multiplier in the membership.
    let isDynamicFrameGenerationEnabled: Bool
    let isRayReconstructionEnabled: Bool
    /// Multipliers the membership includes, ascending. Empty when frame generation is not included.
    let allowedMultipliers: [Int]
    /// Features the membership lacks but NVIDIA upsells, in display order.
    let upsellFeatureLabels: [String]
    let isSummaryVisible: Bool
    let summaryText: String
    /// True while a stream is live, so an edit says it applies to the next session rather than now.
    let isNextSessionOnlyNoteVisible: Bool
    let overrides: DlssOverrides

    static func make(overrides: DlssOverrides, membership: DlssMembershipState, isStreamRunning: Bool) -> DlssSettingsState {
        let entitlements = membership.entitlements
        return DlssSettingsState(
            statusText: DlssAccessCopy.statusText(for: membership),
            isSuperResolutionEnabled: entitlements.superResolution.isEntitled,
            isFrameGenerationEnabled: entitlements.frameGeneration.isEntitled,
            isDynamicFrameGenerationEnabled: entitlements.supportsDynamicFrameGeneration,
            isRayReconstructionEnabled: entitlements.rayReconstruction.isEntitled,
            allowedMultipliers: entitlements.allowedFrameGenerationMultipliers,
            upsellFeatureLabels: entitlements.upsellFeatureLabels,
            isSummaryVisible: entitlements.hasAnyEntitlement,
            summaryText: overrides.applyingAccess(entitlements).nextSessionRequestSummary,
            isNextSessionOnlyNoteVisible: isStreamRunning,
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
        guard !models.allSatisfy({ $0 == 0 }) else { return .inGame }
        guard !models.allSatisfy({ $0 == 1 }) else { return .recommended }
        return .custom
    }

    // MARK: - Writers

    func setDlssSuperResolutionMode(_ mode: DlssSuperResolutionMode) {
        guard dlssMembershipState.entitlements.superResolution.isEntitled else { return }
        var overrides = dlssOverrides
        overrides.superResolutionMode = mode.rawValue
        overrides.superResolutionScale = mode.fixedInputScale ?? overrides.superResolutionScale
        raiseUnsetSuperResolutionModel(&overrides)
        saveDlssOverrides(overrides)
    }

    func setDlssSuperResolutionScale(_ scale: Int) {
        guard dlssMembershipState.entitlements.superResolution.isEntitled else { return }
        var overrides = dlssOverrides
        overrides.superResolutionMode = DlssSuperResolutionMode.custom.rawValue
        overrides.superResolutionScale = scale
        raiseUnsetSuperResolutionModel(&overrides)
        saveDlssOverrides(overrides)
    }

    func setDlssSuperResolutionModel(_ model: Int) {
        guard dlssMembershipState.entitlements.superResolution.isEntitled else { return }
        var overrides = dlssOverrides
        overrides.superResolutionModel = model
        guard model == 0 else {
            saveDlssOverrides(overrides)
            return
        }
        overrides.superResolutionMode = DlssSuperResolutionMode.inGame.rawValue
        overrides.superResolutionScale = DlssSuperResolutionMode.inGame.fixedInputScale ?? 100
        saveDlssOverrides(overrides)
    }

    func setDlssFrameGenerationMode(_ mode: DlssFrameGenerationMode) {
        let entitlements = dlssMembershipState.entitlements
        guard entitlements.frameGeneration.isEntitled else { return }
        guard mode != .dynamic || entitlements.supportsDynamicFrameGeneration else { return }
        var overrides = dlssOverrides
        overrides.frameGenerationMode = mode.rawValue
        guard mode == .dynamic else {
            overrides.frameGenerationMultiplier = 0
            saveDlssOverrides(overrides)
            return
        }
        raiseUnsetFrameGenerationModel(&overrides)
        let allowed = entitlements.allowedFrameGenerationMultipliers
        guard !allowed.contains(overrides.frameGenerationMultiplier) else {
            saveDlssOverrides(overrides)
            return
        }
        overrides.frameGenerationMultiplier = allowed.min() ?? DlssOverrides.frameGenerationMultipliers[0]
        saveDlssOverrides(overrides)
    }

    func setDlssFrameGenerationMultiplier(_ multiplier: Int) {
        let entitlements = dlssMembershipState.entitlements
        guard entitlements.frameGeneration.isEntitled else { return }
        guard entitlements.allowedFrameGenerationMultipliers.contains(multiplier) else { return }
        var overrides = dlssOverrides
        overrides.frameGenerationMode = DlssFrameGenerationMode.dynamic.rawValue
        overrides.frameGenerationMultiplier = multiplier
        raiseUnsetFrameGenerationModel(&overrides)
        saveDlssOverrides(overrides)
    }

    func setDlssFrameGenerationModel(_ model: Int) {
        guard dlssMembershipState.entitlements.frameGeneration.isEntitled else { return }
        var overrides = dlssOverrides
        overrides.frameGenerationModel = model
        guard model == 0 else {
            saveDlssOverrides(overrides)
            return
        }
        overrides.frameGenerationMode = DlssFrameGenerationMode.inGame.rawValue
        overrides.frameGenerationMultiplier = 0
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
            applyInGameModels(to: &overrides, entitlements: entitlements)
        case .recommended:
            applyRecommendedModels(to: &overrides, entitlements: entitlements)
        case .custom:
            break
        }
        saveDlssOverrides(overrides)
    }

    func resetDlssOverrides() {
        saveDlssOverrides(.useGameSettings)
    }

    private func applyInGameModels(to overrides: inout DlssOverrides, entitlements: DlssEntitlements) {
        if entitlements.superResolution.isEntitled {
            overrides.superResolutionModel = 0
            overrides.superResolutionMode = DlssSuperResolutionMode.inGame.rawValue
            overrides.superResolutionScale = DlssSuperResolutionMode.inGame.fixedInputScale ?? 100
        }
        if entitlements.frameGeneration.isEntitled {
            overrides.frameGenerationModel = 0
            overrides.frameGenerationMode = DlssFrameGenerationMode.inGame.rawValue
            overrides.frameGenerationMultiplier = 0
        }
        if entitlements.rayReconstruction.isEntitled { overrides.rayReconstructionModel = 0 }
    }

    private func applyRecommendedModels(to overrides: inout DlssOverrides, entitlements: DlssEntitlements) {
        if entitlements.superResolution.isEntitled { overrides.superResolutionModel = 1 }
        if entitlements.frameGeneration.isEntitled { overrides.frameGenerationModel = 1 }
        if entitlements.rayReconstruction.isEntitled { overrides.rayReconstructionModel = 1 }
    }

    /// Naming a mode or a model is naming an override, so a model left to the game is raised with it.
    private func raiseUnsetSuperResolutionModel(_ overrides: inout DlssOverrides) {
        guard overrides.superResolutionModel == 0 else { return }
        overrides.superResolutionModel = 1
    }

    private func raiseUnsetFrameGenerationModel(_ overrides: inout DlssOverrides) {
        guard overrides.frameGenerationModel == 0 else { return }
        overrides.frameGenerationModel = 1
    }

    private func saveDlssOverrides(_ overrides: DlssOverrides) {
        OPNStreamPreferences.saveDlssOverrides(overrides)
        dlssOverrides = overrides
    }

    // MARK: - Compatibility

    /// Starts (or joins) the lookup for the game whose details are open. The UI's bounded wait is the
    /// first 1.5 seconds; a slow download finishes in the background and replaces the result once.
    func beginDlssCompatibilityLookup(for game: OPNCatalogGameObject) {
        let key = game.catalogIdentity
        guard !isDlssLookupActive || dlssCompatibilityGameKey != key else { return }
        dlssLookupTask?.cancel()
        isDlssLookupActive = true
        dlssAnnouncer.beginCycle()
        startDlssCycleForChangedGame(key: key)
        isDlssCompatibilityWaiting = true
        let title = game.title
        dlssLookupTask = Task { [weak self] in
            guard let self else { return }
            await self.runDlssLookup(forTitle: title, key: key)
        }
    }

    /// The details surface closed, the page changed, or the app went to the background: timers stop
    /// and queued announcements are dropped, so a late result updates the section silently.
    func endDlssCompatibilityLookup() {
        dlssLookupTask?.cancel()
        dlssLookupTask = nil
        isDlssLookupActive = false
        isDlssCompatibilityWaiting = false
        dlssAnnouncer.endCycle()
    }

    /// The app lost focus. Timers stop; a result that lands afterwards is applied without an
    /// announcement because the cycle is over.
    func suspendDlssAnnouncements() {
        dlssAnnouncer.endCycle()
    }

    /// The compact chip the detail panel may wear for this game. Nil until the lookup has answered for
    /// this exact game, so an unknown or loading title gets no empty placeholder pill.
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

    private func startDlssCycleForChangedGame(key: String) {
        guard dlssCompatibilityGameKey != key else { return }
        dlssCompatibilityGameKey = key
        lastDlssSnapshot = nil
        dlssCompatibility = .checking
        dlssAnnouncer.handle(.initialLookupStarted)
    }

    private func runDlssLookup(forTitle title: String, key: String) async {
        let service = dlssCompatibilityService
        _ = await service.index(waitingUpTo: DlssCompatibilityLimits.presentationWait)
        guard !Task.isCancelled, dlssCompatibilityGameKey == key else { return }
        let snapshot = await service.currentSnapshot(forTitle: title)
        applyDlssSnapshot(snapshot, key: key)
        isDlssCompatibilityWaiting = false
        guard !snapshot.hasSavedData else { return }
        // No usable data yet: wait for the background attempt so a slow first download still lands,
        // and so a failure can replace the loading state.
        await service.awaitPendingRefresh()
        guard !Task.isCancelled, dlssCompatibilityGameKey == key else { return }
        applyDlssSnapshot(await service.currentSnapshot(forTitle: title), key: key)
    }

    private func applyDlssSnapshot(_ snapshot: OPNDlssCompatibilityService.Snapshot, key: String) {
        guard dlssCompatibilityGameKey == key else { return }
        let previous = lastDlssSnapshot
        lastDlssSnapshot = snapshot
        dlssCompatibility = DlssCompatibilityPresentation.make(snapshot)
        // A re-read that returns exactly what was already shown is not a transition: that is what
        // keeps re-renders and timestamp-only refreshes silent.
        guard previous != snapshot else { return }
        announceDlssTransition(from: previous, to: snapshot)
    }

    /// Only real transitions are announced. An outcome whose text repeats what was already said is
    /// dropped by the announcer itself.
    private func announceDlssTransition(from previous: OPNDlssCompatibilityService.Snapshot?, to current: OPNDlssCompatibilityService.Snapshot) {
        guard current.listState != .loading else { return }
        guard let previous else {
            announceFirstSnapshot(current)
            return
        }
        let isRefreshStarting = previous.listState != .refreshing && current.listState == .refreshing
        guard !isRefreshStarting else {
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
            dlssAnnouncer.handle(outcomeAnnouncement(isMatched: current.outcome.isMatched, hadSavedData: false))
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
            // A refresh landing on the same result is a timestamp-only update: the footer moves,
            // nothing is spoken. A first answer, a changed result and a recovery all are outcomes.
            let isFirstAnswer = !previous.hasSavedData && current.hasSavedData
            let isResultChanged = previous.outcome.isMatched != current.outcome.isMatched
            let isRecovery = previous.listState == .refreshFailed || previous.listState == .unavailable
            guard isFirstAnswer || isResultChanged || isRecovery else { return }
            dlssAnnouncer.handle(outcomeAnnouncement(isMatched: current.outcome.isMatched, hadSavedData: previous.hasSavedData))
        }
    }

    private func outcomeAnnouncement(isMatched: Bool, hadSavedData: Bool) -> DlssCompatibilityTransition {
        guard hadSavedData else { return isMatched ? .initialLookupSucceeded : .initialLookupUnknown }
        return isMatched ? .refreshSucceeded : .refreshSucceededUnknown
    }
}
