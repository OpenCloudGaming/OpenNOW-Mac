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
