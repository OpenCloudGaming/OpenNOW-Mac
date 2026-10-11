import Testing
@testable import OpenNOW

@MainActor
@Suite struct DetachedSessionModelTests {
    private func candidate(_ email: String, id: String?, hasSession: Bool = true) -> DetachedAccountCandidate {
        DetachedAccountCandidate(
            email: email,
            displayName: email,
            membershipTier: "Free",
            accountID: id.flatMap { OPNAccountID(rawValue: $0) },
            hasSavedSession: hasSession
        )
    }

    private let accountA = OPNAccountID(providerIdpId: "idp", vendorSubject: "user-a", localFallbackSubject: "a@example.com")
    private let accountB = OPNAccountID(providerIdpId: "idp", vendorSubject: "user-b", localFallbackSubject: "b@example.com")

    @Test func anAccountThatOwnsAGameIsBusyAndOneWithoutASessionNeedsSignIn() throws {
        let idA = try #require(accountA)
        let idB = try #require(accountB)
        let rows = DetachedSessionModel.rows(
            candidates: [
                candidate("a@example.com", id: idA.rawValue),
                candidate("b@example.com", id: idB.rawValue),
                candidate("c@example.com", id: idB.rawValue, hasSession: false),
                candidate("d@example.com", id: nil),
            ],
            ownedAccountIDs: [idA]
        )
        #expect(rows.map(\.availability) == [.runningGame, .available, .signInRequired, .signInRequired])
        #expect(rows.map(\.availability.isSelectable) == [false, true, false, false])
    }

    @Test func theControllerChoiceBecomesThePresetAndTheKeptPads() {
        let selection = DetachedSessionModel.selection(disabled: ["pad-a"], takesPadsFromOtherStreams: true)
        #expect(selection.disabled == ["pad-a"])
        #expect(selection.takesPadsFromOtherStreams)
        #expect(DetachedSessionModel.keptControllers(connected: ["pad-a", "pad-b"], disabled: ["pad-a"]) == ["pad-b"])
    }

    @Test func confirmingStoresTheSelectionUnderTheAccountAndMovesToTheCatalog() throws {
        let idB = try #require(accountB)
        let preset = OPNStreamControllerPreset()
        let viewModel = DetachedSessionViewModel(preset: preset, hasOtherStreams: true)
        viewModel.setController("pad-a", enabled: false)
        let row = DetachedAccountRow(email: "b@example.com", displayName: "B", membershipTier: "Free", availability: .available)

        viewModel.confirm(row: row, accountID: idB)

        #expect(viewModel.phase == .catalog(email: "b@example.com"))
        #expect(preset.peek(forAccount: idB.rawValue) == OPNStreamControllerSelection(disabled: ["pad-a"], takesPadsFromOtherStreams: true))
    }

    @Test func aBusyAccountCannotBeConfirmed() throws {
        let idA = try #require(accountA)
        let preset = OPNStreamControllerPreset()
        let viewModel = DetachedSessionViewModel(preset: preset, hasOtherStreams: false)
        let row = DetachedAccountRow(email: "a@example.com", displayName: "A", membershipTier: "Free", availability: .runningGame)

        viewModel.confirm(row: row, accountID: idA)

        #expect(viewModel.phase == .setup)
        #expect(preset.peek(forAccount: idA.rawValue) == OPNStreamControllerSelection())
    }

    @Test func goingBackDropsTheSelectionForAStreamThatNeverStarted() throws {
        let idB = try #require(accountB)
        let preset = OPNStreamControllerPreset()
        let viewModel = DetachedSessionViewModel(preset: preset, hasOtherStreams: false)
        viewModel.setController("pad-a", enabled: false)
        let row = DetachedAccountRow(email: "b@example.com", displayName: "B", membershipTier: "Free", availability: .available)
        viewModel.confirm(row: row, accountID: idB)

        viewModel.backToSetup(accountID: idB)

        #expect(viewModel.phase == .setup)
        #expect(preset.peek(forAccount: idB.rawValue) == OPNStreamControllerSelection())
    }

    @Test func theHandOffToggleStartsOnOnlyWhenAnotherStreamIsRunning() {
        #expect(DetachedSessionViewModel(preset: OPNStreamControllerPreset(), hasOtherStreams: true).takesPadsFromOtherStreams)
        #expect(!DetachedSessionViewModel(preset: OPNStreamControllerPreset(), hasOtherStreams: false).takesPadsFromOtherStreams)
    }

    @Test func theCouchCoopFlagIsRegisteredAndOffByDefault() {
        #expect(OPNLabs.flags.contains(OPNLabs.couchCoop))
        #expect(OPNLabs.couchCoop.id == "couchCoop")
        #expect(OPNLabs.couchCoop.storageKey == "OpenNOW.Labs.couchCoop")
        #expect(!OPNLabs.isEnabled(id: "a-flag-that-was-removed"))
    }
}
