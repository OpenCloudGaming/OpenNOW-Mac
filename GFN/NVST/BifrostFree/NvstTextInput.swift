import Foundation

/// Turns a string into the key presses that would type it, in the Windows virtual keys the
/// `0x206` keyboard command carries.
///
/// This is a fallback, not the protocol's own answer. The stream view routes IME composition,
/// Option-modified characters, non-ASCII text and **paste** through `UserInputEvent.text`, and the
/// encoding NVIDIA uses for that is not recovered — so without this, pasting a password into a
/// login screen silently does nothing.
///
/// The codes are Windows virtual keys, matching what a capture of the vendored client shows on the
/// wire (letters 0x41-0x5A, digits 0x30-0x39, OEM punctuation 0xBA-0xDF). Shift is not a separate
/// key here — it is carried in the packet's modifier field, the same field that makes held-shift
/// produce capitals.
public enum NvstTextInput {
    public struct Keystroke: Equatable, Sendable {
        public let virtualKey: UInt16
        public let needsShift: Bool
    }

    static let unshifted: [Character: UInt16] = {
        var map: [Character: UInt16] = [
            " ": 0x20, "\t": 0x09, "\n": 0x0d, "\r": 0x0d,
            "-": 0xbd, "=": 0xbb, "[": 0xdb, "]": 0xdd, "\\": 0xdc,
            ";": 0xba, "'": 0xde, ",": 0xbc, ".": 0xbe, "/": 0xbf, "`": 0xc0,
        ]
        for (index, character) in "0123456789".enumerated() { map[character] = UInt16(0x30 + index) }
        for (index, character) in "abcdefghijklmnopqrstuvwxyz".enumerated() { map[character] = UInt16(0x41 + index) }
        return map
    }()

    static let shifted: [Character: UInt16] = {
        var map: [Character: UInt16] = [:]
        let pairs: [(Character, Character)] = [
            ("!", "1"), ("@", "2"), ("#", "3"), ("$", "4"), ("%", "5"),
            ("^", "6"), ("&", "7"), ("*", "8"), ("(", "9"), (")", "0"),
            ("_", "-"), ("+", "="), ("{", "["), ("}", "]"), ("|", "\\"),
            (":", ";"), ("\"", "'"), ("<", ","), (">", "."), ("?", "/"), ("~", "`"),
        ]
        for (shiftedCharacter, base) in pairs {
            if let key = unshifted[base] { map[shiftedCharacter] = key }
        }
        for (index, character) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { map[character] = UInt16(0x41 + index) }
        return map
    }()

    public static func keystrokes(for text: String) -> (strokes: [Keystroke], unmappable: [Character]) {
        var strokes: [Keystroke] = []
        var unmappable: [Character] = []
        for character in text {
            if let key = unshifted[character] {
                strokes.append(Keystroke(virtualKey: key, needsShift: false))
            } else if let key = shifted[character] {
                strokes.append(Keystroke(virtualKey: key, needsShift: true))
            } else {
                unmappable.append(character)
            }
        }
        return (strokes, unmappable)
    }
}
