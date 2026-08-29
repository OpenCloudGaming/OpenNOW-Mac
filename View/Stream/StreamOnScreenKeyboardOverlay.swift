//
//  StreamOnScreenKeyboardOverlay.swift
//  OpenNOW
//

import Combine
import SwiftUI

/// Steam Deck-style on-screen keyboard: opened with Steam + X, dual trackpads each
/// aim a cursor on their half of the grid, pad click or L2/R2 types the aimed key,
/// d-pad/stick + A navigate and confirm for pads without trackpads. Transport
/// agnostic — the active stream host turns `StreamOSKOutput`s into input events.
@MainActor
final class StreamOnScreenKeyboardController: ObservableObject {
    @Published private(set) var state = StreamOSKState()

    var onOutput: ((StreamOSKOutput) -> Void)?
    var onDismiss: (() -> Void)?

    private var navigator = StreamOSKGamepadNavigator()
    private var padClickHeld: [InputDeviceID: (left: Bool, right: Bool)] = [:]
    private var triggerHeld: [InputDeviceID: (left: Bool, right: Bool)] = [:]

    private static let triggerThreshold: Float = 0.5

    func reset() {
        state.reset()
        navigator.reset()
        padClickHeld.removeAll()
        triggerHeld.removeAll()
    }

    /// Raw Steam Controller/Deck report, delivered by the gamepad monitor while the
    /// keyboard captures the device. Buttons are already chord-stripped (no
    /// quickAccess, no chord-consumed X).
    func handleSteamSnapshot(deviceID: InputDeviceID, snapshot: SteamControllerInputSnapshot) {
        if snapshot.leftPad.touched {
            state.updatePadCursor(.left, x: snapshot.leftPad.x, y: snapshot.leftPad.y)
        } else {
            state.clearPadCursor(.left)
        }
        if snapshot.rightPad.touched {
            state.updatePadCursor(.right, x: snapshot.rightPad.x, y: snapshot.rightPad.y)
        } else {
            state.clearPadCursor(.right)
        }

        var clicks = padClickHeld[deviceID] ?? (left: false, right: false)
        if snapshot.leftPad.pressed, !clicks.left { apply(state.activatePadCursor(.left)) }
        if snapshot.rightPad.pressed, !clicks.right { apply(state.activatePadCursor(.right)) }
        clicks = (left: snapshot.leftPad.pressed, right: snapshot.rightPad.pressed)
        padClickHeld[deviceID] = clicks

        var triggers = triggerHeld[deviceID] ?? (left: false, right: false)
        let leftTrigger = snapshot.leftTrigger > Self.triggerThreshold
        let rightTrigger = snapshot.rightTrigger > Self.triggerThreshold
        if leftTrigger, !triggers.left { apply(state.activatePadCursor(.left)) }
        if rightTrigger, !triggers.right { apply(state.activatePadCursor(.right)) }
        triggers = (left: leftTrigger, right: rightTrigger)
        triggerHeld[deviceID] = triggers

        if let action = navigator.action(deviceID: deviceID, buttons: snapshot.buttons, leftStickX: snapshot.leftStickX, leftStickY: snapshot.leftStickY) {
            handleNavigationAction(action)
        }
    }

    /// Regular gamepad state path for controllers without trackpads.
    func handleGamepadState(_ gamepadState: GamepadState) {
        guard let action = navigator.action(deviceID: gamepadState.deviceID, buttons: gamepadState.buttons, leftStickX: gamepadState.leftStickX, leftStickY: gamepadState.leftStickY) else { return }
        handleNavigationAction(action)
    }

    func activateGridKey(row: Int, column: Int) {
        apply(state.activateGridKey(row: row, column: column))
    }

    func activateBarItem(_ index: Int) {
        apply(state.activateBarItem(index))
    }

    /// Drives the keyboard from an already-abstract navigation command. The stream hosts feed raw
    /// device reports because they also aim the trackpad cursors; the controller-mode catalog gets
    /// its input as high-level moves from `ControllerInputRouter` and has no cursor to aim.
    func handleNavigationAction(_ action: StreamOSKNavAction) {
        switch action {
        case .move(let dx, let dy): state.moveGridCursor(dx: dx, dy: dy)
        case .activate: apply(state.activateGridCursor())
        case .backspace: apply(state.activateKey(.backspace))
        case .space: apply(state.activateKey(.space))
        case .shift: apply(state.activateKey(.shift))
        case .enter: apply(state.activateKey(.enter))
        case .dismiss: apply(state.activateKey(.dismiss))
        }
    }

    private func apply(_ effect: StreamOSKEffect) {
        switch effect {
        case .output(let output): onOutput?(output)
        case .dismiss: onDismiss?()
        case .none: break
        }
    }
}

struct StreamOnScreenKeyboardOverlay: View {
    @ObservedObject var controller: StreamOnScreenKeyboardController

    private let keyWidth: CGFloat = 46
    private let keyHeight: CGFloat = 40
    private let keySpacing: CGFloat = 4

    var body: some View {
        let atTop = controller.state.position == .top
        VStack(spacing: 0) {
            headerStrip
            Rectangle().fill(WebRTCMediaStreamTheme.divider).frame(height: 1)
            VStack(spacing: keySpacing) {
                ForEach(0..<StreamOSKLayout.rowCount, id: \.self) { row in
                    keyRow(row)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            bottomBar
            hintFooter
        }
        .background(WebRTCMediaStreamTheme.panel.opacity(0.985))
        .overlay(alignment: .top) { Rectangle().fill(WebRTCMediaStreamTheme.accent).frame(height: 2) }
        .overlay(Rectangle().stroke(WebRTCMediaStreamTheme.divider, lineWidth: 1))
        .shadow(color: .black.opacity(0.58), radius: 28, y: atTop ? -14 : 14)
        .padding(atTop ? .top : .bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: atTop ? .top : .bottom)
    }

    private var headerStrip: some View {
        HStack(spacing: 10) {
            Text("KEYBOARD")
                .font(.streamNvidia(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            Rectangle().fill(WebRTCMediaStreamTheme.divider).frame(width: 1, height: 14)
            Text(controller.state.echo.isEmpty ? " " : controller.state.echo)
                .font(.streamNvidia(size: 12, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Recently typed text")
            if controller.state.shiftLatched {
                statusBadge("SHIFT")
            }
            if controller.state.layer == .symbols {
                statusBadge("123")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(WebRTCMediaStreamTheme.appBar)
    }

    private func statusBadge(_ title: String) -> some View {
        Text(title)
            .font(.streamNvidia(size: 9, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(.black.opacity(0.86))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(WebRTCMediaStreamTheme.accent)
    }

    private func keyRow(_ row: Int) -> some View {
        HStack(spacing: keySpacing) {
            ForEach(0..<StreamOSKLayout.columnCount, id: \.self) { column in
                keyButton(row: row, column: column)
            }
        }
    }

    private func keyButton(row: Int, column: Int) -> some View {
        let state = controller.state
        let key = StreamOSKLayout.key(row: row, column: column, layer: state.layer)
        let isGridCursor = !state.gridCursorInBar && state.gridCursor.row == row && state.gridCursor.column == column
        let isLeftPadCursor = state.leftPadCursor?.row == row && state.leftPadCursor?.column == column
        let isRightPadCursor = state.rightPadCursor?.row == row && state.rightPadCursor?.column == column
        return keyCell(
            key: key,
            isGridCursor: isGridCursor,
            isLeftPadCursor: isLeftPadCursor,
            isRightPadCursor: isRightPadCursor,
            width: keyWidth
        ) {
            controller.activateGridKey(row: row, column: column)
        }
        .disabled(key == nil)
        .opacity(key == nil ? 0 : 1)
    }

    private var bottomBar: some View {
        HStack(spacing: keySpacing) {
            ForEach(0..<StreamOSKLayout.barItems.count, id: \.self) { index in
                let isGridCursor = controller.state.gridCursorInBar && controller.state.barIndex == index
                keyCell(
                    key: StreamOSKLayout.barItems[index],
                    isGridCursor: isGridCursor,
                    isLeftPadCursor: false,
                    isRightPadCursor: false,
                    width: barItemWidth(index)
                ) {
                    controller.activateBarItem(index)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, keySpacing)
        .padding(.bottom, 10)
    }

    private func barItemWidth(_ index: Int) -> CGFloat {
        let columnCount = CGFloat(StreamOSKLayout.columnCount)
        let totalWidth = columnCount * keyWidth + (columnCount - 1) * keySpacing
        let items = StreamOSKLayout.barItems
        let nonSpaceCount = CGFloat(items.filter { if case .space = $0 { false } else { true } }.count)
        let spaceWidth = totalWidth - nonSpaceCount * (keyWidth * 2 + keySpacing) - CGFloat(items.count - 1) * keySpacing
        switch items[index] {
        case .space: return max(40, spaceWidth)
        default: return keyWidth * 2 + keySpacing
        }
    }

    private func keyCell(key: StreamOSKKey?, isGridCursor: Bool, isLeftPadCursor: Bool, isRightPadCursor: Bool, width: CGFloat, action: @escaping () -> Void) -> some View {
        let state = controller.state
        let isLatchedModifier = key == .shift && state.shiftLatched
        let isActiveLayer = key == .symbols && state.layer == .symbols
        return Button(action: action) {
            Group {
                if let key, StreamOSKLayout.labelIsSymbol(key) {
                    Image(systemName: StreamOSKLayout.label(for: key, shiftLatched: state.shiftLatched, layer: state.layer))
                        .font(.system(size: 13, weight: .bold))
                } else {
                    Text(key.map { StreamOSKLayout.label(for: $0, shiftLatched: state.shiftLatched, layer: state.layer) } ?? " ")
                        .font(.streamNvidia(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(foregroundColor(isLatchedModifier: isLatchedModifier || isActiveLayer, isPadCursor: isLeftPadCursor || isRightPadCursor))
            .frame(width: width, height: keyHeight)
            .background(backgroundColor(isLatchedModifier: isLatchedModifier || isActiveLayer, isLeftPadCursor: isLeftPadCursor, isRightPadCursor: isRightPadCursor))
            .overlay {
                Rectangle()
                    .stroke(strokeColor(isGridCursor: isGridCursor, isLeftPadCursor: isLeftPadCursor, isRightPadCursor: isRightPadCursor), lineWidth: isGridCursor ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func foregroundColor(isLatchedModifier: Bool, isPadCursor: Bool) -> Color {
        if isLatchedModifier { return .black.opacity(0.86) }
        return WebRTCMediaStreamTheme.textPrimary
    }

    private func backgroundColor(isLatchedModifier: Bool, isLeftPadCursor: Bool, isRightPadCursor: Bool) -> Color {
        if isLatchedModifier { return WebRTCMediaStreamTheme.accent }
        if isLeftPadCursor { return WebRTCMediaStreamTheme.accentSoft.opacity(0.28) }
        if isRightPadCursor { return WebRTCMediaStreamTheme.accent.opacity(0.28) }
        return Color.white.opacity(0.075)
    }

    private func strokeColor(isGridCursor: Bool, isLeftPadCursor: Bool, isRightPadCursor: Bool) -> Color {
        if isGridCursor { return WebRTCMediaStreamTheme.textPrimary }
        if isLeftPadCursor { return WebRTCMediaStreamTheme.accentSoft }
        if isRightPadCursor { return WebRTCMediaStreamTheme.accent }
        return WebRTCMediaStreamTheme.divider
    }

    private var hintFooter: some View {
        Text("A TYPE   B ⌫   X SPACE   Y SHIFT   ⏎ ENTER   PADS AIM · CLICK / L2·R2 TYPE   STEAM+X CLOSE")
            .font(.streamNvidia(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
    }
}
