import AppKit
import CryptoKit
import SwiftUI

struct InterfaceSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @AppStorage(OPNSessionReadyAction.modeKey) private var sessionReadyActionRawValue = OPNSessionReadyAction.Mode.notification.rawValue
    @AppStorage(OPNWindowClosePreferences.behaviorKey) private var windowCloseBehaviorRawValue = OPNWindowClosePreferences.defaultBehavior.rawValue
    @AppStorage(OPNMenuBarPreferences.showsStatusItemKey) private var showsMenuBarItem = OPNMenuBarPreferences.defaultShowsStatusItem
    @AppStorage(OPNLaunchPreferences.startupPresentationKey) private var startupPresentationRawValue = OPNLaunchPreferences.defaultStartupPresentation.rawValue
    @State private var launchesAtLogin = OPNLoginItemController.isEnabled
    @State private var isSessionInsightsEnabled = OPNSessionInsightsPreferences.isEnabled

    /// Menu-bar-only mode hides the Dock icon, so without the status item it has nothing to be
    /// reached by. It is offered as unavailable and the row says why rather than silently
    /// disagreeing with it.
    private var windowCloseSubtitle: String {
        let base = "What the close button does with the last window. Quit on Close ends the app with its window. Close, Keep Dock Icon leaves OpenNOW running with its Dock icon and no window, so the Dock brings it back. Close, Menu Bar Only hides the Dock icon and leaves only the menu bar item. Either way the window is hidden, not torn down, so a queue or stream in flight keeps running."
        guard !showsMenuBarItem else { return base }
        return base + " Menu Bar Only needs the menu bar item, so it stays unavailable while that is off."
    }

    private var selectedWindowCloseBehaviorIndex: Int {
        // Resolved, not raw: a menu-bar-only choice the menu bar item switch has withheld must show as
        // the fallback that actually applies, not as a selected chip that cannot run.
        let behavior = OPNWindowClosePreferences.resolvedBehavior(storedRawValue: windowCloseBehaviorRawValue)
        return OPNWindowCloseBehavior.allCases.firstIndex(of: behavior) ?? 0
    }

    private var selectedSessionReadyActionIndex: Int {
        let mode = OPNSessionReadyAction.Mode(rawValue: sessionReadyActionRawValue) ?? .notification
        return OPNSessionReadyAction.Mode.allCases.firstIndex(of: mode) ?? 0
    }

    private var selectedStartupPresentationIndex: Int {
        // Resolved, not raw: a menu-bar-only choice the menu bar item switch or the close behavior
        // has withheld must show as the presentation that actually applies, not as a selected chip
        // that cannot run.
        let presentation = OPNLaunchPreferences.resolvedStartupPresentation(
            storedRawValue: startupPresentationRawValue,
            canReachMenuBar: canLaunchMenuBarOnly
        )
        return OPNStartupPresentation.allCases.firstIndex(of: presentation) ?? 0
    }

    /// A menu-bar-only launch suppresses the window, so it needs the status item to be the way back.
    /// That needs both the menu bar item and a close behavior that keeps the app running.
    private var canLaunchMenuBarOnly: Bool {
        guard showsMenuBarItem else { return false }
        let behavior = OPNWindowClosePreferences.resolvedBehavior(storedRawValue: windowCloseBehaviorRawValue)
        return behavior.keepsApplicationRunning
    }

    private var startupSubtitle: String {
        let base = "Open the main window, or start with only the menu bar item and no window. Opening the window later is always one click away in the menu bar."
        guard !canLaunchMenuBarOnly else { return base }
        return base + " Menu Bar Only starts with no window, so it needs the menu bar item and a close behavior that keeps OpenNOW running; it stays unavailable while either is off."
    }

    private var launchAtLoginSubtitle: String {
        let base = "Start OpenNOW automatically when you log in to this Mac. macOS lists it under Login Items in System Settings."
        guard OPNLoginItemController.requiresApproval else { return base }
        return base + " macOS is waiting for you to approve it there."
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
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(
                    title: "Session Insights",
                    subtitle: "Show a summary of what a stream measured about itself — how long it ran, its shape, and any dropped frames, decode errors or recoveries — when the stream ends. The summary carries a Don't show this again option.",
                    isOn: isSessionInsightsEnabled,
                    isNew: OPNNewSettings.isNew(.sessionInsights),
                    uiScale: uiScale
                ) { newValue in
                    OPNNewSettings.acknowledge(.sessionInsights)
                    isSessionInsightsEnabled = newValue
                    OPNSessionInsightsPreferences.isEnabled = newValue
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
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(
                    title: "Launch at Login",
                    subtitle: launchAtLoginSubtitle,
                    isOn: launchesAtLogin,
                    isNew: OPNNewSettings.isNew(.launchAtLogin),
                    uiScale: uiScale
                ) { newValue in
                    OPNNewSettings.acknowledge(.launchAtLogin)
                    launchesAtLogin = OPNLoginItemController.setEnabled(newValue)
                    OPNLaunchPreferences.launchesAtLogin = launchesAtLogin
                }
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(
                    title: "At Launch, Show",
                    subtitle: startupSubtitle,
                    options: OPNStartupPresentation.allCases.map(\.label),
                    selectedIndex: selectedStartupPresentationIndex,
                    enabled: OPNStartupPresentation.allCases.map { $0 != .menuBarOnly || canLaunchMenuBarOnly },
                    isNew: OPNNewSettings.isNew(.startupPresentation),
                    uiScale: uiScale
                ) { index in
                    OPNNewSettings.acknowledge(.startupPresentation)
                    guard OPNStartupPresentation.allCases.indices.contains(index) else { return }
                    startupPresentationRawValue = OPNStartupPresentation.allCases[index].rawValue
                }
            }
            .settingsSection("window-closing")
        }
        .onAppear {
            launchesAtLogin = OPNLoginItemController.isEnabled
            isSessionInsightsEnabled = OPNSessionInsightsPreferences.isEnabled
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
