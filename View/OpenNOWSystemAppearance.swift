import AppKit
import Combine
import SwiftUI

/// What macOS itself is set to, for Match System to follow.
///
/// Deliberately not `@Environment(\.colorScheme)`: the app forces a window appearance whenever the
/// reader picks Dark or Light, and that forced value is what the environment then reports. Leaving
/// Light for Match System would read "light" as the system setting and resolve straight back to it.
/// `NSApplication.effectiveAppearance` stays the OS's answer, because a window's override is its
/// own.
@MainActor
final class OpenNOWSystemAppearance: ObservableObject {
    @Published private(set) var isDark = OpenNOWSystemAppearance.isSystemDark()

    private var observation: NSKeyValueObservation?

    init() {
        observation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.isDark = OpenNOWSystemAppearance.isSystemDark()
            }
        }
    }

    var colorScheme: ColorScheme { isDark ? .dark : .light }

    static func isSystemDark() -> Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
