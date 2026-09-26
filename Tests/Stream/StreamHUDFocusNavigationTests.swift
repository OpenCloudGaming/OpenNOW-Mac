import Foundation
import Testing
@testable import OpenNOW

/// Pad navigation over the HUD's grids: left/right read in visual order, up/down keep the column.
@MainActor
struct StreamHUDFocusNavigationTests {
    private func entry(_ id: String, group: String = "", columns: Int = 1, disabled: Bool = false) -> StreamHUDFocusEntry {
        StreamHUDFocusEntry(id: id, isDisabled: disabled, group: group, columns: columns, action: {})
    }

    /// CONTROLS (4 wide), INPUT (4 wide), a slider, then two full-width video rows.
    private var hud: [StreamHUDFocusEntry] {
        [
            entry("mic", group: "controls", columns: 4), entry("audio", group: "controls", columns: 4),
            entry("rec", group: "controls", columns: 4), entry("stats", group: "controls", columns: 4),
            entry("pointer", group: "input", columns: 4), entry("afk", group: "input", columns: 4),
            entry("mapping", group: "input", columns: 4), entry("quit", group: "input", columns: 4),
            entry("sensitivity"),
            entry("tier"), entry("clarity"),
        ]
    }

    @Test func rowsFollowGroupsAndColumns() {
        let rows = StreamHUDFocusEntry.rows(of: hud)
        #expect(rows == [[0, 1, 2, 3], [4, 5, 6, 7], [8], [9], [10]])
        // A group wider than its column count wraps onto a second row.
        let wide = (0..<6).map { entry("t\($0)", group: "g", columns: 4) }
        #expect(StreamHUDFocusEntry.rows(of: wide) == [[0, 1, 2, 3], [4, 5]])
    }

    @Test func aFifthTileWrapsOntoItsOwnRowAndStaysInTheColumn() {
        let entries = [
            entry("mic", group: "controls", columns: 4), entry("audio", group: "controls", columns: 4),
            entry("rec", group: "controls", columns: 4), entry("stats", group: "controls", columns: 4),
            entry("full-screen", group: "controls", columns: 4),
            entry("pointer", group: "input", columns: 4), entry("quit", group: "input", columns: 4),
        ]
        #expect(StreamHUDFocusEntry.rows(of: entries) == [[0, 1, 2, 3], [4], [5, 6]])
        #expect(StreamHUDFocusEntry.focusID(from: "mic", direction: .down, in: entries) == "full-screen")
        #expect(StreamHUDFocusEntry.focusID(from: "full-screen", direction: .down, in: entries) == "pointer")
        #expect(StreamHUDFocusEntry.focusID(from: "stats", direction: .right, in: entries) == "full-screen")
    }

    @Test func downKeepsTheColumn() {
        #expect(StreamHUDFocusEntry.focusID(from: "mic", direction: .down, in: hud) == "pointer")
        #expect(StreamHUDFocusEntry.focusID(from: "stats", direction: .down, in: hud) == "quit")
        #expect(StreamHUDFocusEntry.focusID(from: "quit", direction: .up, in: hud) == "stats")
        // A full-width row is column 0; going up from it lands on the nearest tile, the first.
        #expect(StreamHUDFocusEntry.focusID(from: "quit", direction: .down, in: hud) == "sensitivity")
        #expect(StreamHUDFocusEntry.focusID(from: "sensitivity", direction: .up, in: hud) == "pointer")
    }

    @Test func rightAndLeftReadInVisualOrderAndWrap() {
        #expect(StreamHUDFocusEntry.focusID(from: "stats", direction: .right, in: hud) == "pointer")
        #expect(StreamHUDFocusEntry.focusID(from: "mic", direction: .left, in: hud) == "clarity")
    }

    @Test func verticalMovementSkipsRowsWithNothingEnabled() {
        var entries = hud
        entries[4] = entry("pointer", group: "input", columns: 4, disabled: true)
        entries[5] = entry("afk", group: "input", columns: 4, disabled: true)
        entries[6] = entry("mapping", group: "input", columns: 4, disabled: true)
        entries[7] = entry("quit", group: "input", columns: 4, disabled: true)
        #expect(StreamHUDFocusEntry.focusID(from: "mic", direction: .down, in: entries) == "sensitivity")
        #expect(StreamHUDFocusEntry.focusID(from: "clarity", direction: .down, in: entries) == "mic")
    }

    @Test func downLandsOnTheNearestEnabledColumn() {
        var entries = hud
        entries[7] = entry("quit", group: "input", columns: 4, disabled: true)
        #expect(StreamHUDFocusEntry.focusID(from: "stats", direction: .down, in: entries) == "mapping")
    }

    @Test func unknownFocusStartsAtTheFirstEnabledEntry() {
        #expect(StreamHUDFocusEntry.focusID(from: nil, direction: .down, in: hud) == "mic")
        #expect(StreamHUDFocusEntry.focusID(from: "gone", direction: .up, in: hud) == "mic")
    }

    /// A sectioned list leads with each header, and a collapsed section contributes only its header
    /// so it stays reachable to reopen.
    @Test func collapsedSectionsKeepTheirHeaderOnly() {
        let sections: [StreamHUDFocusEntry.Section] = [
            .init(section: .audio, action: {}, content: [entry("mic", group: "audio", columns: 4), entry("audio", group: "audio", columns: 4)]),
            .init(section: .capture, action: {}, content: [entry("rec", group: "capture", columns: 4)]),
        ]
        let expanded = StreamHUDFocusEntry.sectioned(sections, collapsed: [])
        #expect(expanded.map(\.id) == [OPNStreamHUDSection.audio.focusID, "mic", "audio", OPNStreamHUDSection.capture.focusID, "rec"])
        let collapsed = StreamHUDFocusEntry.sectioned(sections, collapsed: [.audio])
        #expect(collapsed.map(\.id) == [OPNStreamHUDSection.audio.focusID, OPNStreamHUDSection.capture.focusID, "rec"])
        #expect(collapsed.first?.kind == .sectionHeader)
    }

    /// Down from a header reaches its first control when open, and the next section's header when
    /// folded — the folded content is gone from the list, so navigation cannot land in it.
    @Test func downFollowsTheFoldedState() {
        let sections: [StreamHUDFocusEntry.Section] = [
            .init(section: .audio, action: {}, content: [entry("mic", group: "audio", columns: 4)]),
            .init(section: .capture, action: {}, content: [entry("rec", group: "capture", columns: 4)]),
        ]
        let expanded = StreamHUDFocusEntry.sectioned(sections, collapsed: [])
        #expect(StreamHUDFocusEntry.focusID(from: OPNStreamHUDSection.audio.focusID, direction: .down, in: expanded) == "mic")
        let collapsed = StreamHUDFocusEntry.sectioned(sections, collapsed: [.audio])
        #expect(StreamHUDFocusEntry.focusID(from: OPNStreamHUDSection.audio.focusID, direction: .down, in: collapsed) == OPNStreamHUDSection.capture.focusID)
    }

    // MARK: - Pad-driven dropdowns

    /// A dropdown's entry is a full-width row of its own — the shape `StreamHUDFocusEntry` documents
    /// for a slider, a dropdown or a participant row — so it sits between the grids rather than
    /// inside one, and up/down step through it in the order the HUD draws it.
    @Test func aDropdownEntryIsAFullWidthRowBetweenTheGrids() {
        let entries = [
            entry("mic", group: "audio", columns: 4), entry("audio", group: "audio", columns: 4),
            entry("microphone-device"),
            entry("pointer", group: "input", columns: 4), entry("afk", group: "input", columns: 4),
        ]
        #expect(StreamHUDFocusEntry.rows(of: entries) == [[0, 1], [2], [3, 4]])
        #expect(StreamHUDFocusEntry.focusID(from: "mic", direction: .down, in: entries) == "microphone-device")
        #expect(StreamHUDFocusEntry.focusID(from: "microphone-device", direction: .down, in: entries) == "pointer")
        #expect(StreamHUDFocusEntry.focusID(from: "pointer", direction: .up, in: entries) == "microphone-device")
    }

    /// The whole pad sequence on a real HUD model: confirm opens the list on the row in use, up/down
    /// walk it and wrap, confirm runs that row and closes, and HUD focus is back on the trigger —
    /// which it never left, because the panel is drawn from the same entry rather than as a new one.
    @Test func aDropdownOpensWalksCommitsAndLeavesFocusOnItsTrigger() {
        let (_, model) = makeHUDSurface()
        let id = NativeNVSTHostViewModel.microphoneDeviceDropdownID
        model.microphoneDeviceOptions = [
            OPNStreamMicrophoneDeviceOption(label: "Default Device", uniqueId: "", automatic: true),
            OPNStreamMicrophoneDeviceOption(label: "MacBook Microphone", uniqueId: "built-in"),
            OPNStreamMicrophoneDeviceOption(label: "USB Mic", uniqueId: "usb"),
        ]
        model.microphoneDeviceID = "built-in"
        model.hudFocusID = id

        model.togglePadDropdown(id)
        #expect(model.openHUDDropdownID == id)
        #expect(model.hudDropdownHighlightedItemID == "built-in", "the list opens on the row in use")

        model.moveHUDDropdownHighlight(step: 1)
        #expect(model.hudDropdownHighlightedItemID == "usb")
        model.moveHUDDropdownHighlight(step: 1)
        #expect(model.hudDropdownHighlightedItemID == "", "the walk wraps")
        model.moveHUDDropdownHighlight(step: -1)
        #expect(model.hudDropdownHighlightedItemID == "usb")

        model.commitHUDDropdownHighlight()
        #expect(model.openHUDDropdownID == nil)
        #expect(model.hudDropdownHighlightedItemID == nil)
        #expect(model.hudFocusID == id, "the pad is back on the trigger, so the next press reopens the list")
        // A device change with no session running is refused rather than saved: the preference only
        // moves once the transport has taken it.
        #expect(model.microphoneDeviceID == "built-in")
    }

    /// Cancel closes the panel and selects nothing, and the trigger is still where the pad stands.
    @Test func cancellingADropdownSelectsNothingAndKeepsTheTriggerFocused() {
        let (_, model) = makeHUDSurface()
        let id = NativeNVSTHostViewModel.microphoneDeviceDropdownID
        model.microphoneDeviceOptions = [
            OPNStreamMicrophoneDeviceOption(label: "Default Device", uniqueId: "", automatic: true),
            OPNStreamMicrophoneDeviceOption(label: "USB Mic", uniqueId: "usb"),
        ]
        model.hudFocusID = id
        model.togglePadDropdown(id)
        model.moveHUDDropdownHighlight(step: 1)
        model.closeHUDDropdown()
        #expect(!model.isHUDDropdownOpen)
        #expect(model.hudFocusID == id)
        #expect(model.microphoneDeviceID == "", "a cancelled selection is not saved")
    }

    /// A dropdown the model does not own refuses to open rather than opening on an empty list, and an
    /// unknown id cannot leave the HUD stuck in "a panel is open".
    @Test func anUnknownDropdownDoesNotOpen() {
        let (_, model) = makeHUDSurface()
        model.togglePadDropdown("not-a-dropdown")
        #expect(!model.isHUDDropdownOpen)
    }

    /// The Remote Co-Op quality dropdown's entry sits on the participant's own focus row, ahead of
    /// approve and remove, exactly as the row draws them.
    @Test func theParticipantQualityDropdownLeadsItsRow() {
        withPreservedHUDSettings {
            let (_, model) = makeHUDSurface()
            model.remoteCoOpPreferences.isEnabled = true
            let participant = OPNRemoteCoOpParticipant(displayName: "Guest", role: .guest, connectionState: .connected)
            model.remoteCoOpSnapshot = OPNRemoteCoOpHostSnapshot(preferences: model.remoteCoOpPreferences, invite: nil, participants: [participant])
            let qualityID = NativeNVSTHostViewModel.remoteCoOpQualityDropdownPrefix + participant.id.uuidString
            let entries = model.hudFocusEntries.filter { $0.group == "coop-participant-\(participant.id.uuidString)" }
            #expect(entries.map(\.id) == [qualityID, "coop-remove-\(participant.id.uuidString)"])
            #expect(entries.allSatisfy { $0.columns == entries.count }, "one grid row, so up/down keeps the column")
            // The approval row grows by the approve button, and every column count follows it.
            let waiting = OPNRemoteCoOpParticipant(displayName: "Waiting", role: .guest, connectionState: .waitingForApproval)
            model.remoteCoOpSnapshot = OPNRemoteCoOpHostSnapshot(preferences: model.remoteCoOpPreferences, invite: nil, participants: [waiting])
            let waitingEntries = model.hudFocusEntries.filter { $0.group == "coop-participant-\(waiting.id.uuidString)" }
            #expect(waitingEntries.count == 3)
            #expect(waitingEntries.allSatisfy { $0.columns == 3 })
        }
    }

    @Test func trackerMapsDpadAndStickToDirections() {
        let tracker = StreamHUDGamepadTracker()
        let device = InputDeviceID("pad")
        func state(_ buttons: GamepadButtons, x: Float = 0, y: Float = 0) -> GamepadState {
            GamepadState(deviceID: device, playerIndex: 0, buttons: buttons, leftStickX: x, leftStickY: y, timestamp: MediaTimestamp(nanoseconds: 0))
        }
        #expect(tracker.navigationStep(state([])) == nil)
        #expect(tracker.navigationStep(state(.dpadDown)) == .move(.down))
        #expect(tracker.navigationStep(state([])) == nil)
        #expect(tracker.navigationStep(state(.dpadLeft)) == .move(.left))
        #expect(tracker.navigationStep(state([], y: -1)) == .move(.down))
        // Holding the stick is one step, not one per poll.
        #expect(tracker.navigationStep(state([], y: -1)) == nil)
        #expect(tracker.navigationStep(state([], x: 1)) == .move(.right))
        #expect(tracker.navigationStep(state(.south, x: 1)) == .activate)
        #expect(StreamHUDFocusDirection.up.linearStep == -1)
        #expect(StreamHUDFocusDirection.right.linearStep == 1)
    }
}
