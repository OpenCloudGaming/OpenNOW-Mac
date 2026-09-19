import AppKit
import CryptoKit
import SwiftUI

struct InterfaceSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @AppStorage(OPNSessionReadyAction.modeKey) private var sessionReadyActionRawValue = OPNSessionReadyAction.Mode.notification.rawValue
    @AppStorage(OPNWindowClosePreferences.behaviorKey) private var windowCloseBehaviorRawValue = OPNWindowClosePreferences.defaultBehavior.rawValue
    @AppStorage(OPNMenuBarPreferences.showsStatusItemKey) private var showsMenuBarItem = OPNMenuBarPreferences.defaultShowsStatusItem

    /// The windowless choice has nothing to be reached by without the status item, so it is offered
    /// as unavailable and the row says why rather than silently disagreeing with it.
    private var windowCloseSubtitle: String {
        let base = "What the close button does with the last window. Minimizing drops the window into the Dock and keeps a session running; keeping running with no window leaves only the menu bar, and reopening builds the window again. Quit OpenNOW closes the app with its window."
        guard !showsMenuBarItem else { return base }
        return base + " Keeping running with no window needs the menu bar item, so it stays unavailable while that is off."
    }

    private var selectedWindowCloseBehaviorIndex: Int {
        let behavior = OPNWindowCloseBehavior(rawValue: windowCloseBehaviorRawValue) ?? OPNWindowClosePreferences.defaultBehavior
        return OPNWindowCloseBehavior.allCases.firstIndex(of: behavior) ?? 0
    }

    private var selectedSessionReadyActionIndex: Int {
        let mode = OPNSessionReadyAction.Mode(rawValue: sessionReadyActionRawValue) ?? .notification
        return OPNSessionReadyAction.Mode.allCases.firstIndex(of: mode) ?? 0
    }

    static let sections: [SettingsSection] = [
        SettingsSection("session-ready", "Session Ready"),
        SettingsSection("window-closing", "Window & Menu Bar"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Session Ready", uiScale: uiScale) {
                SettingsOptionRow(title: "When the Stream Is Ready", subtitle: "While OpenNOW is in the background and a queued or provisioning session becomes ready: post a system notification, bring OpenNOW to the front automatically, bring it forward and put the stream in full screen, or do nothing.", options: OPNSessionReadyAction.Mode.allCases.map(\.label), selectedIndex: selectedSessionReadyActionIndex, isNew: OPNNewSettings.isNew(.sessionReadyAction), uiScale: uiScale) { index in
                    OPNNewSettings.acknowledge(.sessionReadyAction)
                    let mode = OPNSessionReadyAction.Mode.allCases[index]
                    sessionReadyActionRawValue = mode.rawValue
                    if mode == .notification { OPNSessionReadyAction.prepareAuthorizationIfNeeded() }
                }
            }
            .settingsSection("session-ready")
            SettingsCard(title: "Window & Menu Bar", uiScale: uiScale) {
                SettingsToggleRow(
                    title: "Menu Bar Item",
                    subtitle: "Show the session in the menu bar. With this off OpenNOW puts nothing in the menu bar at all, even while a session is running, and the window is the only place to see or end one.",
                    isOn: showsMenuBarItem,
                    isNew: OPNNewSettings.isNew(.menuBar),
                    uiScale: uiScale
                ) { newValue in
                    OPNNewSettings.acknowledge(.menuBar)
                    OPNMenuBarPreferences.showsStatusItem = newValue
                }
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(
                    title: "When the Last Window Closes",
                    subtitle: windowCloseSubtitle,
                    options: OPNWindowCloseBehavior.allCases.map(\.label),
                    selectedIndex: selectedWindowCloseBehaviorIndex,
                    enabled: OPNWindowCloseBehavior.allCases.map { !$0.requiresStatusItem || showsMenuBarItem },
                    isNew: OPNNewSettings.isNew(.menuBar),
                    uiScale: uiScale
                ) { index in
                    OPNNewSettings.acknowledge(.menuBar)
                    guard OPNWindowCloseBehavior.allCases.indices.contains(index) else { return }
                    OPNWindowClosePreferences.behavior = OPNWindowCloseBehavior.allCases[index]
                }
            }
            .settingsSection("window-closing")
        }
    }
}

struct InterfaceInputLegend: View {
    let title: String
    let glyphs: [ControllerInputGlyph]
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 9 * uiScale) {
            Text(title.uppercased())
                .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(OPNDesign.Text.muted)
            HStack(spacing: 6 * uiScale) {
                ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                    InterfaceGlyphPill(glyph: glyph, uiScale: uiScale)
                }
            }
        }
        .padding(.horizontal, 12 * uiScale)
        .padding(.vertical, 11 * uiScale)
        .frame(minWidth: 132 * uiScale, minHeight: 70 * uiScale, alignment: .leading)
        .background(OPNDesign.Fill.neutral(0.045))
        .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
    }
}

struct InterfaceGlyphPill: View {
    let glyph: ControllerInputGlyph
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 6 * uiScale) {
            if !glyph.symbolName.isEmpty {
                Image(systemName: glyph.symbolName)
                    .font(.settingsFont(size: 13 * uiScale, weight: .bold))
            }
            Text(glyph.fallbackText)
                .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(OPNDesign.accentInk)
        .padding(.horizontal, 8 * uiScale)
        .frame(height: 28 * uiScale)
        .background(OPNDesign.accent.opacity(0.12))
        .overlay { Rectangle().stroke(OPNDesign.accent.opacity(0.28), lineWidth: 1) }
        .accessibilityLabel(glyph.accessibilityLabel)
    }
}
