import Foundation
import Testing
@testable import OpenNOW

private let guideDevice: InputDeviceID = "guide-test"
private let guideStamp = MediaTimestamp(nanoseconds: 7)
private let guideClock = ContinuousClock()

@MainActor
@Suite struct ControllerGuideBindingTests {
    private func makeStore() throws -> ControllerMappingStore {
        let suiteName = "ControllerGuideBindingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return ControllerMappingStore(defaults: defaults)
    }

    @Test func guideDefaultsToTheUnifiedHUDForAProfileThatNeverMentionsIt() {
        let profile = ControllerMappingProfile(name: "Legacy")
        #expect(profile.binding(for: .guide) == .streamCommand(.toggleUnifiedHUD))
        #expect(profile.binding(for: .faceA) == .passthroughButton)
    }

    @Test func anExplicitGuideBindingOverridesTheDefault() {
        let profile = ControllerMappingProfile(name: "Custom", bindings: [.guide: .passthroughButton])
        #expect(profile.binding(for: .guide) == .passthroughButton)
    }

    @Test func bindingActionsAreTheStreamSectionAllowlist() {
        let actions = KeybindingAction.controllerBindingActions
        #expect(actions == KeybindingAction.allCases.filter { $0.section == .stream })
        #expect(actions.contains(.toggleUnifiedHUD))
        #expect(actions.contains(.takeScreenshot))
        #expect(!actions.contains(.openSearch))
    }

    @Test func streamCommandTargetRoundTripsThroughCoding() throws {
        let targets: [ControllerBindingTarget] = [
            .streamCommand(.toggleUnifiedHUD),
            .streamCommand(.saveReplay),
            .passthroughButton,
        ]
        for target in targets {
            let data = try JSONEncoder().encode(target)
            #expect(try JSONDecoder().decode(ControllerBindingTarget.self, from: data) == target)
        }
        // The persisted form is the stable raw string, not an ordinal.
        let encoded = try JSONEncoder().encode(ControllerBindingTarget.streamCommand(.saveReplay))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["streamCommand"] as? String == KeybindingAction.saveReplay.rawValue)
    }

    @Test func streamCommandBindingsSurviveAStoreReload() throws {
        let defaults = try #require(UserDefaults(suiteName: "ControllerGuideBindingTests.\(UUID().uuidString)"))
        let store = ControllerMappingStore(defaults: defaults)
        var profile = try #require(store.activeProfile)
        profile.bindings[.faceA] = .streamCommand(.takeScreenshot)
        profile.bindings[.guide] = .streamCommand(.saveReplay)
        store.updateProfile(profile)

        let reloaded = ControllerMappingStore(defaults: defaults)
        #expect(reloaded.activeProfile?.binding(for: .faceA) == .streamCommand(.takeScreenshot))
        #expect(reloaded.activeProfile?.binding(for: .guide) == .streamCommand(.saveReplay))
    }

    // MARK: - Engine

    @Test func engineFiresAStreamCommandOncePerPress() {
        var engine = ControllerBindingEngine()
        let profile = ControllerMappingProfile(name: "Actions", bindings: [.faceA: .streamCommand(.takeScreenshot)])
        let pressed = engine.apply(profile: profile, snapshot: ControllerInputSnapshot(buttons: [.south]),
                                   deviceID: guideDevice, playerIndex: 0, now: guideClock.now, timestamp: guideStamp)
        #expect(pressed.commands == [.takeScreenshot])
        // The press is consumed: it must not also reach the seat.
        let padState = pressed.events.compactMap { if case .gamepad(let state) = $0 { state } else { nil } }.last
        #expect(padState?.buttons.contains(.south) == false)

        let held = engine.apply(profile: profile, snapshot: ControllerInputSnapshot(buttons: [.south]),
                                deviceID: guideDevice, playerIndex: 0, now: guideClock.now, timestamp: guideStamp)
        #expect(held.commands.isEmpty)

        _ = engine.apply(profile: profile, snapshot: ControllerInputSnapshot(),
                         deviceID: guideDevice, playerIndex: 0, now: guideClock.now, timestamp: guideStamp)
        let again = engine.apply(profile: profile, snapshot: ControllerInputSnapshot(buttons: [.south]),
                                 deviceID: guideDevice, playerIndex: 0, now: guideClock.now, timestamp: guideStamp)
        #expect(again.commands == [.takeScreenshot])
    }

    @Test func engineLeavesTheGuideCommandToThePreEnginePath() {
        var engine = ControllerBindingEngine()
        let profile = ControllerMappingProfile(name: "Actions", bindings: [.guide: .streamCommand(.toggleUnifiedHUD)])
        let result = engine.apply(profile: profile, snapshot: ControllerInputSnapshot(buttons: [.mode]),
                                  deviceID: guideDevice, playerIndex: 0, now: guideClock.now, timestamp: guideStamp)
        #expect(result.commands.isEmpty)
    }

    // MARK: - Steam guide tap detection

    @Test func guideTapFiresOnRelease() {
        var tracker = SteamGuideTapTracker()
        func step(_ buttons: GamepadButtons) -> Bool {
            tracker.process(snapshot: ControllerInputSnapshot(buttons: buttons), deviceID: guideDevice)
        }
        #expect(!step([.mode]))
        #expect(step([]))
    }

    @Test func guideHoldWithAChordPartnerDoesNotFire() {
        var tracker = SteamGuideTapTracker()
        func step(_ buttons: GamepadButtons, pad: ControllerTrackpadState = ControllerTrackpadState()) -> Bool {
            tracker.process(snapshot: ControllerInputSnapshot(buttons: buttons, rightPad: pad), deviceID: guideDevice)
        }
        #expect(!step([.mode]))
        #expect(!step([.mode, .west]))
        #expect(!step([]))
    }

    @Test func guideHoldWithPadMotionDoesNotFire() {
        var tracker = SteamGuideTapTracker()
        func step(_ buttons: GamepadButtons, pad: ControllerTrackpadState) -> Bool {
            tracker.process(snapshot: ControllerInputSnapshot(buttons: buttons, rightPad: pad), deviceID: guideDevice)
        }
        #expect(!step([.mode], pad: ControllerTrackpadState(x: 0.1, y: 0.1, touched: true)))
        #expect(!step([.mode], pad: ControllerTrackpadState(x: 0.4, y: 0.1, touched: true)))
        #expect(!step([], pad: ControllerTrackpadState()))
    }

    @Test func restingThumbOnTheRightPadStillCountsAsATap() {
        var tracker = SteamGuideTapTracker()
        func step(_ buttons: GamepadButtons, pad: ControllerTrackpadState) -> Bool {
            tracker.process(snapshot: ControllerInputSnapshot(buttons: buttons, rightPad: pad), deviceID: guideDevice)
        }
        #expect(!step([.mode], pad: ControllerTrackpadState(x: 0.3, y: 0.2, touched: true)))
        #expect(!step([.mode], pad: ControllerTrackpadState(x: 0.3001, y: 0.2, touched: true)))
        #expect(step([], pad: ControllerTrackpadState()))
    }

    @Test func guideHoldWithAPadClickDoesNotFire() {
        var tracker = SteamGuideTapTracker()
        func step(_ buttons: GamepadButtons, pad: ControllerTrackpadState) -> Bool {
            tracker.process(snapshot: ControllerInputSnapshot(buttons: buttons, rightPad: pad), deviceID: guideDevice)
        }
        #expect(!step([.mode], pad: ControllerTrackpadState()))
        #expect(!step([.mode], pad: ControllerTrackpadState(pressed: true)))
        #expect(!step([], pad: ControllerTrackpadState()))
    }

    // MARK: - Monitor integration

    @Test func guideTogglesTheHUDOnTheSteamPathWithMappingsDisabled() throws {
        let monitor = NativeGamepadMonitor(mappingProvider: try makeStore())
        monitor.mappingsEnabled = false
        var commands: [KeybindingAction] = []
        monitor.onStreamCommand = { commands.append($0) }

        monitor.processSteamSnapshot(deviceID: guideDevice, playerIndex: 0,
                                     snapshot: ControllerInputSnapshot(buttons: [.mode]))
        #expect(commands.isEmpty)
        monitor.processSteamSnapshot(deviceID: guideDevice, playerIndex: 0, snapshot: ControllerInputSnapshot())
        #expect(commands == [.toggleUnifiedHUD])
    }

    @Test func ordinaryControlCommandsStayInertWithMappingsDisabled() throws {
        let store = try makeStore()
        let monitor = NativeGamepadMonitor(mappingProvider: store)
        var profile = try #require(store.activeProfile)
        profile.bindings[.faceA] = .streamCommand(.takeScreenshot)
        store.updateProfile(profile)
        monitor.mappingsEnabled = false
        var commands: [KeybindingAction] = []
        monitor.onStreamCommand = { commands.append($0) }

        monitor.applyBindingEngine(deviceID: guideDevice, playerIndex: 0,
                                   snapshot: ControllerInputSnapshot(buttons: [.south]), includePointerMotion: false)
        #expect(commands.isEmpty)
    }

    @Test func guideBoundToPassthroughReachesTheWireForANativePad() {
        var session = ControllerMappingSession(deviceID: guideDevice, playerIndex: 0, guideBinding: .passthroughButton)
        let press = session.process(ControllerInputSnapshot(buttons: [.mode]), now: guideClock.now, timestamp: guideStamp)
        #expect(press.commands.isEmpty)
        let padState = press.events.compactMap { if case .gamepad(let state) = $0 { state } else { nil } }.last
        #expect(padState?.buttons.contains(.mode) == true)
    }

    @Test func nativeGuideCommandFiresOncePerPressAndConsumesTheBit() {
        var session = ControllerMappingSession(deviceID: guideDevice, playerIndex: 0)
        let press = session.process(ControllerInputSnapshot(buttons: [.mode]), now: guideClock.now, timestamp: guideStamp)
        #expect(press.commands == [.toggleUnifiedHUD])
        let padState = press.events.compactMap { if case .gamepad(let state) = $0 { state } else { nil } }.last
        #expect(padState?.buttons.contains(.mode) == false)

        let held = session.process(ControllerInputSnapshot(buttons: [.mode]), now: guideClock.now, timestamp: guideStamp)
        #expect(held.commands.isEmpty)
        _ = session.process(ControllerInputSnapshot(), now: guideClock.now, timestamp: guideStamp)
        let again = session.process(ControllerInputSnapshot(buttons: [.mode]), now: guideClock.now, timestamp: guideStamp)
        #expect(again.commands == [.toggleUnifiedHUD])
    }

    @Test func nativeOrdinaryControlCommandFiresThroughTheEngine() {
        let profile = ControllerMappingProfile(name: "Actions", family: .generic,
                                               bindings: [.faceA: .streamCommand(.saveReplay)])
        var session = ControllerMappingSession(deviceID: guideDevice, playerIndex: 0, profile: profile,
                                               guideBinding: .passthroughButton)
        let press = session.process(ControllerInputSnapshot(buttons: [.south]), now: guideClock.now, timestamp: guideStamp)
        #expect(press.commands == [.saveReplay])
    }
}
