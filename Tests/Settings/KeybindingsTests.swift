import Foundation
import Testing
@testable import OpenNOW

// The rebindable shortcut store: defaults, per-section resolution, and the conflict the page warns
// about. Every test owns a private defaults suite so parallel runs cannot stomp one another.

private func makeKeybindings() -> OPNKeybindings {
    let suiteName = "OpenNOWTests.Keybindings.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("could not create a defaults suite named \(suiteName)")
        return OPNKeybindings(storage: .standard)
    }
    return OPNKeybindings(storage: OPNAppPreferenceStorage(defaults: defaults, defaultsDomain: suiteName))
}

@Test func itShipsEveryShortcutAtItsDefaultChord() {
    let bindings = makeKeybindings()
    for action in KeybindingAction.allCases {
        #expect(bindings.combo(for: action) == action.defaultCombo, "\(action.rawValue) did not start at its default")
        #expect(!bindings.hasCustomBinding(for: action), "\(action.rawValue) started customised")
    }
}

@Test func itReadsBackARebindUntilItIsReset() {
    let bindings = makeKeybindings()
    let custom = OPNKeyCombo(keyCode: 3, modifiers: [.control, .shift])

    bindings.assign(custom, to: .toggleMicrophone)
    #expect(bindings.combo(for: .toggleMicrophone) == custom)
    #expect(bindings.hasCustomBinding(for: .toggleMicrophone))
    #expect(bindings.hasCustomBindings)

    bindings.reset(.toggleMicrophone)
    #expect(bindings.combo(for: .toggleMicrophone) == KeybindingAction.toggleMicrophone.defaultCombo)
    #expect(!bindings.hasCustomBinding(for: .toggleMicrophone))
    #expect(!bindings.hasCustomBindings)
}

@Test func itResolvesAChordOnlyWithinItsSection() {
    let bindings = makeKeybindings()
    let custom = OPNKeyCombo(keyCode: 3, modifiers: .command)
    bindings.assign(custom, to: .toggleMicrophone)

    #expect(bindings.resolvedAction(keyCode: 3, modifierFlags: .command, in: .stream) == .toggleMicrophone)
    #expect(bindings.resolvedAction(keyCode: 3, modifierFlags: .command, in: .catalog) == nil)
}

@Test func itIgnoresModifierFlagsThatAreNotPartOfAChord() {
    let bindings = makeKeybindings()
    #expect(bindings.resolvedAction(keyCode: 46, modifierFlags: [.command, .capsLock, .numericPad], in: .stream) == .toggleMicrophone)
    #expect(bindings.resolvedAction(keyCode: 46, modifierFlags: [.command, .shift], in: .stream) == nil)
}

@Test func itReportsTwoActionsInOneSectionSharingAChord() {
    let bindings = makeKeybindings()
    let shared = OPNKeyCombo(keyCode: 3, modifiers: .command)
    bindings.assign(shared, to: .toggleMicrophone)
    bindings.assign(shared, to: .toggleRecording)

    #expect(bindings.conflictingActions(for: .toggleRecording) == [.toggleMicrophone])
}

@Test func itDoesNotTreatTheCommandKSharedAcrossSectionsAsAConflict() {
    let bindings = makeKeybindings()
    // Anti-AFK and catalog search both ship on Command-K; they act on different surfaces, so neither
    // should be flagged, and whichever surface is active decides which one fires.
    #expect(bindings.combo(for: .toggleAntiAFK) == bindings.combo(for: .openSearch))
    #expect(bindings.conflictingActions(for: .toggleAntiAFK).isEmpty)
    #expect(bindings.conflictingActions(for: .openSearch).isEmpty)
}

@Test func itRejectsABareModifierAsAChord() {
    #expect(!OPNKeyCombo.isBindableKeyCode(55))
    #expect(!OPNKeyCombo.isBindableKeyCode(56))
    #expect(OPNKeyCombo.isBindableKeyCode(35))
}

@Test func itLabelsThePointerReleaseShortcutTheWayTheInputCopyReadsIt() {
    let combo = OPNKeybindings.standard.combo(for: .togglePointerCapture)
    #expect(combo.label == "⌘P")
    #expect(combo.spokenLabel == "Command-P")
}
