import AppKit
import SwiftUI

/// A button that captures the next key press as a `SteamControllerBindingTarget.keyboardKey`.
/// Click it, press a key (Escape cancels), release to commit — the same interaction as any
/// "click to record a shortcut" control, just with no existing precedent in this app to
/// build on top of.
struct SteamControllerBindingRecorder: View {
    let currentLabel: String
    let onRecord: (UInt16, KeyboardModifiers) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? cancel() : startRecording()
        } label: {
            HStack(spacing: 6) {
                if isRecording {
                    Image(systemName: "keyboard")
                        .font(.nvidiaSans(size: 10, weight: .bold))
                    Text("Press a key… (Esc to cancel)")
                } else {
                    Text(currentLabel)
                }
            }
            .font(OpenNOWNVIDIAFont.font(size: 11, weight: .bold))
            .foregroundStyle(isRecording ? OpenNOWDesign.accent : .white.opacity(0.85))
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(isRecording ? OpenNOWDesign.accent.opacity(0.12) : Color.white.opacity(0.05))
            .overlay(
                Rectangle()
                    .stroke(isRecording ? OpenNOWDesign.accent.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onDisappear { stopMonitoring() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { // Escape
                cancel()
                return nil
            }
            let modifiers = Self.modifiers(from: event.modifierFlags)
            onRecord(UInt16(event.keyCode), modifiers)
            stopRecording()
            return nil
        }
    }

    private func cancel() {
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        stopMonitoring()
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyboardModifiers {
        var modifiers: KeyboardModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}

/// Best-effort label for a captured macOS virtual key code — covers the keys a controller
/// binding would realistically use. Falls back to a numeric code for anything exotic.
enum SteamControllerKeyLabel {
    static func label(for keyCode: UInt16, modifiers: KeyboardModifiers) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(baseLabel(for: keyCode))
        return parts.joined()
    }

    /// Virtual key code to the label a user recognises. A table rather than a `switch`, because it
    /// is pure data: every entry is one key on a US layout.
    private static let baseLabels: [UInt16: String] = [
        0: "A",
        1: "S",
        2: "D",
        3: "F",
        4: "H",
        5: "G",
        6: "Z",
        7: "X",
        8: "C",
        9: "V",
        11: "B",
        12: "Q",
        13: "W",
        14: "E",
        15: "R",
        16: "Y",
        17: "T",
        18: "1",
        19: "2",
        20: "3",
        21: "4",
        22: "6",
        23: "5",
        24: "=",
        25: "9",
        26: "7",
        27: "-",
        28: "8",
        29: "0",
        30: "]",
        31: "O",
        32: "U",
        33: "[",
        34: "I",
        35: "P",
        36: "Return",
        37: "L",
        38: "J",
        39: "'",
        40: "K",
        41: ";",
        42: "\\",
        43: ",",
        44: "/",
        45: "N",
        46: "M",
        47: ".",
        48: "Tab",
        49: "Space",
        50: "`",
        51: "Delete",
        53: "Escape",
        76: "Enter",
        96: "F5",
        97: "F6",
        98: "F7",
        99: "F3",
        100: "F8",
        101: "F9",
        103: "F11",
        109: "F10",
        111: "F12",
        118: "F4",
        120: "F2",
        122: "F1",
        123: "←",
        124: "→",
        125: "↓",
        126: "↑"
    ]

    private static func baseLabel(for keyCode: UInt16) -> String {
        baseLabels[keyCode] ?? "Key \(keyCode)"
    }
}
