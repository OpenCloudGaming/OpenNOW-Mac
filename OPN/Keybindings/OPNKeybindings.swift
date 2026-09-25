import AppKit
import Combine
import Foundation

/// The two groups the Keybindings settings page draws, and the surface each binding applies to.
enum KeybindingSection: String, CaseIterable, Identifiable, Sendable {
    case stream
    case catalog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stream: return "Stream"
        case .catalog: return "Catalog"
        }
    }

    var subtitle: String {
        switch self {
        case .stream: return "Shortcuts that act on an active session."
        case .catalog: return "Shortcuts for browsing your library."
        }
    }
}

/// Every shortcut the app owns and lets the reader rebind. The raw value is the UserDefaults key,
/// so renaming a case would silently reset that binding.
enum KeybindingAction: String, CaseIterable, Identifiable, Sendable {
    case toggleUnifiedHUD
    case toggleStatsHUD
    case toggleMicrophone
    case toggleRecording
    case saveReplay
    case takeScreenshot
    case toggleAntiAFK
    case togglePointerCapture
    case showQuitMenu
    case showShortcutsHelp
    case openSearch

    var id: String { rawValue }

    var section: KeybindingSection {
        switch self {
        case .toggleUnifiedHUD, .toggleStatsHUD, .toggleMicrophone, .toggleRecording, .saveReplay, .takeScreenshot, .toggleAntiAFK, .togglePointerCapture, .showQuitMenu, .showShortcutsHelp:
            return .stream
        case .openSearch:
            return .catalog
        }
    }

    var title: String {
        switch self {
        case .toggleUnifiedHUD: return "Toggle HUD"
        case .toggleStatsHUD: return "Toggle Stats"
        case .toggleMicrophone: return "Toggle Microphone"
        case .toggleRecording: return "Toggle Recording"
        case .saveReplay: return "Save Replay"
        case .takeScreenshot: return "Take Screenshot"
        case .toggleAntiAFK: return "Toggle Anti-AFK"
        case .togglePointerCapture: return "Release Pointer"
        case .showQuitMenu: return "Open Quit Menu"
        case .showShortcutsHelp: return "Show Shortcuts"
        case .openSearch: return "Search Games"
        }
    }

    var subtitle: String {
        switch self {
        case .toggleUnifiedHUD: return "Show or hide the unified in-stream HUD."
        case .toggleStatsHUD: return "Show or hide the stream statistics overlay."
        case .toggleMicrophone: return "Mute or unmute the stream microphone."
        case .toggleRecording: return "Start or stop recording the session."
        case .saveReplay: return "Save the last few minutes of the stream as a clip."
        case .takeScreenshot: return "Save the current stream frame as a screenshot."
        case .toggleAntiAFK: return "Toggle the anti-AFK mouse movement."
        case .togglePointerCapture: return "Give the pointer back to the Mac while a game holds it."
        case .showQuitMenu: return "Open the in-stream quit menu."
        case .showShortcutsHelp: return "Show the list of in-stream shortcuts."
        case .openSearch: return "Focus the search field in the games catalog."
        }
    }

    var defaultCombo: OPNKeyCombo {
        switch self {
        case .toggleUnifiedHUD: return OPNKeyCombo(keyCode: 5, modifiers: .command)
        case .toggleStatsHUD: return OPNKeyCombo(keyCode: 45, modifiers: .command)
        case .toggleMicrophone: return OPNKeyCombo(keyCode: 46, modifiers: .command)
        case .toggleRecording: return OPNKeyCombo(keyCode: 15, modifiers: .command)
        case .saveReplay: return OPNKeyCombo(keyCode: 15, modifiers: [.command, .shift])
        case .takeScreenshot: return OPNKeyCombo(keyCode: 1, modifiers: [.command, .shift])
        case .toggleAntiAFK: return OPNKeyCombo(keyCode: 40, modifiers: .command)
        case .togglePointerCapture: return OPNKeyCombo(keyCode: 35, modifiers: .command)
        case .showQuitMenu: return OPNKeyCombo(keyCode: 12, modifiers: .command)
        case .showShortcutsHelp: return OPNKeyCombo(keyCode: 44, modifiers: .command)
        case .openSearch: return OPNKeyCombo(keyCode: 40, modifiers: .command)
        }
    }

    var streamCommand: StreamCommand? {
        switch self {
        case .toggleUnifiedHUD: return .toggleUnifiedHUD
        case .toggleStatsHUD: return .toggleStatsHUD
        case .toggleMicrophone: return .toggleMicrophone
        case .toggleRecording: return .toggleRecording
        case .saveReplay: return .saveReplay
        case .takeScreenshot: return .takeScreenshot
        case .toggleAntiAFK: return .toggleAntiAFK
        case .togglePointerCapture: return .togglePointerCapture
        case .showQuitMenu: return .showQuitMenu
        case .showShortcutsHelp: return .showShortcutsHelp
        case .openSearch: return nil
        }
    }
}

/// A key plus its chord modifiers, stored as a virtual key code so it survives across layouts.
struct OPNKeyCombo: Equatable, Hashable, Sendable {
    let keyCode: UInt16
    let modifiers: KeyboardModifiers

    init(keyCode: UInt16, modifiers: KeyboardModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers.subtracting([.capsLock, .numericPad])
    }

    func matches(keyCode: UInt16, modifiers: KeyboardModifiers) -> Bool {
        self.keyCode == keyCode && self.modifiers == modifiers
    }

    /// A chord has to end on a key that can stand alone; a bare modifier is a chord in progress.
    static func isBindableKeyCode(_ keyCode: UInt16) -> Bool {
        ![55, 56, 57, 58, 59, 60, 61, 62].contains(keyCode)
    }

    /// The compact form a recorder button and an overlay guide show, e.g. `⌘P`.
    var label: String {
        OPNKeyComboFormatter.label(keyCode: Int(keyCode), modifiers: modifiers)
    }

    /// The spelled-out form copy sentences use, e.g. `Command-P`.
    var spokenLabel: String {
        OPNKeyComboFormatter.spokenLabel(keyCode: Int(keyCode), modifiers: modifiers)
    }
}

enum OPNKeyComboFormatter {
    static func label(keyCode: Int, modifiers: KeyboardModifiers) -> String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "⌃" }
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.command) { prefix += "⌘" }
        return prefix + OPNStreamPreferences.microphonePushToTalkKeyLabel(keyCode)
    }

    static func spokenLabel(keyCode: Int, modifiers: KeyboardModifiers) -> String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("Command") }
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        parts.append(OPNStreamPreferences.microphonePushToTalkKeyLabel(keyCode))
        return parts.joined(separator: "-")
    }
}

/// Rebindable shortcuts, persisted one UserDefaults dictionary per action so an absent key means
/// "still the default" and Reset is a removal rather than writing the default back.
struct OPNKeybindings: Sendable {
    static let standard = OPNKeybindings(storage: .standard)
    static let didChangeNotification = Notification.Name("OPNKeybindingsDidChange")

    /// Every binding is stored under this prefix, which the iCloud settings registry allows so the
    /// chords travel between Macs. Shared rather than duplicated so the two cannot drift.
    static let storageKeyPrefix = "OpenNOW.Keybindings."

    private let storage: OPNAppPreferenceStorage

    init(storage: OPNAppPreferenceStorage) {
        self.storage = storage
    }

    func combo(for action: KeybindingAction) -> OPNKeyCombo {
        guard let stored = storage.dictionary(forKey: Self.key(for: action)),
              let keyCode = stored["keyCode"] as? NSNumber else { return action.defaultCombo }
        let mask = (stored["modifiers"] as? NSNumber)?.uint16Value ?? 0
        return OPNKeyCombo(keyCode: keyCode.uint16Value, modifiers: KeyboardModifiers(rawValue: mask))
    }

    func hasCustomBinding(for action: KeybindingAction) -> Bool {
        storage.object(forKey: Self.key(for: action)) != nil
    }

    var hasCustomBindings: Bool {
        KeybindingAction.allCases.contains(where: hasCustomBinding(for:))
    }

    func assign(_ combo: OPNKeyCombo, to action: KeybindingAction) {
        storage.set(["keyCode": Int(combo.keyCode), "modifiers": combo.modifiers.rawValue], forKey: Self.key(for: action))
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func reset(_ action: KeybindingAction) {
        storage.removeObject(forKey: Self.key(for: action))
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func resetAll() {
        for action in KeybindingAction.allCases {
            storage.removeObject(forKey: Self.key(for: action))
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Actions in the same section that resolve to the same chord, so the page can say which one
    /// loses before the reader wonders why a key does nothing.
    func conflictingActions(for action: KeybindingAction) -> [KeybindingAction] {
        let binding = combo(for: action)
        return KeybindingAction.allCases.filter { candidate in
            candidate != action && candidate.section == action.section && combo(for: candidate) == binding
        }
    }

    func resolvedAction(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, in section: KeybindingSection) -> KeybindingAction? {
        let modifiers = Self.normalizedModifiers(modifierFlags)
        return KeybindingAction.allCases.first { action in
            action.section == section && combo(for: action).matches(keyCode: keyCode, modifiers: modifiers)
        }
    }

    private static func normalizedModifiers(_ flags: NSEvent.ModifierFlags) -> KeyboardModifiers {
        let filtered = flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        var modifiers: KeyboardModifiers = []
        if filtered.contains(.shift) { modifiers.insert(.shift) }
        if filtered.contains(.control) { modifiers.insert(.control) }
        if filtered.contains(.option) { modifiers.insert(.option) }
        if filtered.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    private static func key(for action: KeybindingAction) -> String {
        storageKeyPrefix + action.rawValue
    }
}

/// Republishes binding changes so menus and the settings page rebuild without polling. Long-lived on
/// purpose: it is the app-wide signal, so it lives in the service layer rather than in a view body.
/// Deliberately not `@MainActor`: a view's `@ObservedObject` default value is built in a nonisolated
/// initializer, and the class is only ever mutated from the main queue its observer is registered on.
final class OPNKeybindingsObserver: ObservableObject, @unchecked Sendable {
    static let shared = OPNKeybindingsObserver()

    @Published private(set) var revision = 0

    /// Reading through the observer ties a caller's view to `objectWillChange`, so a menu or row
    /// recomputes its chord when the binding moves.
    func combo(for action: KeybindingAction) -> OPNKeyCombo {
        OPNKeybindings.standard.combo(for: action)
    }

    func hasCustomBinding(for action: KeybindingAction) -> Bool {
        OPNKeybindings.standard.hasCustomBinding(for: action)
    }

    var hasCustomBindings: Bool {
        OPNKeybindings.standard.hasCustomBindings
    }

    func conflictingActions(for action: KeybindingAction) -> [KeybindingAction] {
        OPNKeybindings.standard.conflictingActions(for: action)
    }

    private var token: NSObjectProtocol?

    private init() {
        token = NotificationCenter.default.addObserver(
            forName: OPNKeybindings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.revision += 1
            }
        }
    }
}
