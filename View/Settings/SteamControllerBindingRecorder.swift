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
                        .font(.system(size: 10, weight: .bold))
                    Text("Press a key… (Esc to cancel)")
                } else {
                    Text(currentLabel)
                }
            }
            .font(MacForceNowNVIDIAFont.font(size: 11, weight: .bold))
            .foregroundStyle(isRecording ? Color.openNowGreen : .white.opacity(0.85))
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(isRecording ? Color.openNowGreen.opacity(0.12) : Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isRecording ? Color.openNowGreen.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
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

    private static func baseLabel(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 22: "6"
        case 23: "5"
        case 24: "="
        case 25: "9"
        case 26: "7"
        case 27: "-"
        case 28: "8"
        case 29: "0"
        case 30: "]"
        case 31: "O"
        case 32: "U"
        case 33: "["
        case 34: "I"
        case 35: "P"
        case 36: "Return"
        case 37: "L"
        case 38: "J"
        case 39: "'"
        case 40: "K"
        case 41: ";"
        case 42: "\\"
        case 43: ","
        case 44: "/"
        case 45: "N"
        case 46: "M"
        case 47: "."
        case 48: "Tab"
        case 49: "Space"
        case 50: "`"
        case 51: "Delete"
        case 53: "Escape"
        case 76: "Enter"
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 99: "F3"
        case 100: "F8"
        case 101: "F9"
        case 103: "F11"
        case 109: "F10"
        case 111: "F12"
        case 118: "F4"
        case 120: "F2"
        case 122: "F1"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: "Key \(keyCode)"
        }
    }
}
