import SwiftUI

/// What each destination in the sidebar actually renders. A group is composition only: it names the
/// pages a tab is made of and the order they appear in, so a setting can move between tabs without
/// its rows being rewritten.

struct AccountSettingsGroup: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    static let sections: [SettingsSection] = [
        SettingsSection("membership", "Membership"),
        SettingsSection("playtime", "Playtime"),
        SettingsSection("profile", "Profile"),
        SettingsSection("session", "Session"),
        SettingsSection("stores", "Stores"),
    ]

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            AccountSettingsPage(viewModel: viewModel)
            ConnectionsSettingsPage(viewModel: viewModel, uiScale: uiScale)
                .settingsSection("stores")
        }
    }
}

struct VideoSettingsGroup: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    static let sections: [SettingsSection] = VideoSettingsPage.sections + ResolutionUpscalingSettingsPage.sections

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            VideoSettingsPage(viewModel: viewModel, uiScale: uiScale)
            ResolutionUpscalingSettingsPage(viewModel: viewModel, uiScale: uiScale)
        }
    }
}

struct InputSettingsGroup: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    static let sections: [SettingsSection] = InputSettingsPage.sections + [SettingsSection("steam-controller", "Steam Controller")]

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            InputSettingsPage(viewModel: viewModel, uiScale: uiScale)
            SteamControllerSettingsPage(uiScale: uiScale)
                .settingsSection("steam-controller")
        }
    }
}

struct NetworkSettingsGroup: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    static let sections: [SettingsSection] =
        [SettingsSection("server-location", "Server Location")]
        + NetworkTransportSettingsPage.sections
        + [SettingsSection("proxy", "Session Proxy")]

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            ServerLocationSettingsPage(viewModel: viewModel, uiScale: uiScale)
                .settingsSection("server-location")
            NetworkTransportSettingsPage(viewModel: viewModel, uiScale: uiScale)
            SessionProxySettingsPage(viewModel: viewModel)
                .settingsSection("proxy")
        }
    }
}

/// Everything that is neither a stream setting nor an account one: how the app presents itself, who
/// it tells what, and what it can report about this Mac.
struct GeneralSettingsGroup: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    static let sections: [SettingsSection] =
        InterfaceSettingsPage.sections
        + [
            SettingsSection("game-launch", "Game Launch"),
            SettingsSection("discord", "Discord"),
        ]
        + PrivacySettingsPage.sections
        + CacheSettingsPage.sections
        + DiagnosticsSettingsPage.sections
        + ReportIssueSettingsPage.sections

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            InterfaceSettingsPage(viewModel: viewModel, uiScale: uiScale)
            GameLaunchSettingsPage(viewModel: viewModel, uiScale: uiScale)
                .settingsSection("game-launch")
            DiscordSettingsPage(uiScale: uiScale)
                .settingsSection("discord")
            PrivacySettingsPage(uiScale: uiScale)
            CacheSettingsPage(viewModel: viewModel, uiScale: uiScale)
            DiagnosticsSettingsPage(viewModel: viewModel, uiScale: uiScale)
            ReportIssueSettingsPage(viewModel: viewModel, uiScale: uiScale)
        }
    }
}

/// Identity, updates, and machine facts: what OpenNOW is, what it is running, what changed, and what
/// this Mac can do. The updater lives here with the release history it produces.
struct SystemSettingsGroup: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    static let sections: [SettingsSection] =
        ProductSettingsPage.sections
        + RuntimeSettingsPage.sections
        + SystemSettingsPage.sections
        + UpdatesSettingsPage.sections
        + [SettingsSection("whats-new", "What's New")]

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            ProductSettingsPage(viewModel: viewModel, uiScale: uiScale)
            RuntimeSettingsPage(uiScale: uiScale)
            SystemSettingsPage(viewModel: viewModel, uiScale: uiScale)
            UpdatesSettingsPage(uiScale: uiScale)
            WhatsNewCard(uiScale: uiScale)
                .settingsSection("whats-new")
        }
    }
}

struct GameLaunchSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        SettingsCard(title: "Game Launch", uiScale: uiScale) {
            SettingsToggleRow(
                title: "Steam Big Picture Mode",
                subtitle: "Request gamepad-friendly launchers such as Steam Big Picture. Applies to new GeForce NOW sessions only.",
                isOn: viewModel.streamProfile.steamBigPictureMode,
                isNew: OPNNewSettings.isNew(.steamBigPictureMode),
                uiScale: uiScale
            ) { newValue in
                OPNNewSettings.acknowledge(.steamBigPictureMode)
                viewModel.setSteamBigPictureMode(newValue)
            }
            SettingsDivider(uiScale: uiScale)
            SettingsToggleRow(
                title: "In-Game Settings Persistence",
                subtitle: "Save graphics options changed inside games during a stream. Sent when your membership includes NVIDIA's in-game settings persistence.",
                isOn: viewModel.streamProfile.enablePersistingInGameSettings,
                isNew: OPNNewSettings.isNew(.inGameSettingsPersistence),
                uiScale: uiScale
            ) { newValue in
                OPNNewSettings.acknowledge(.inGameSettingsPersistence)
                viewModel.setPersistInGameSettings(newValue)
            }
        }
    }
}

struct DiscordSettingsPage: View {
    let discordPresence: any DiscordPresenceServing = DiscordRichPresence.shared
    let uiScale: CGFloat
    @State private var richPresenceEnabled = true

    var body: some View {
        SettingsCard(title: "Discord", uiScale: uiScale) {
            SettingsToggleRow(
                title: "Rich Presence",
                subtitle: "Show the game you're streaming on your Discord profile, with its artwork and elapsed time.",
                isOn: richPresenceEnabled,
                uiScale: uiScale
            ) { newValue in
                richPresenceEnabled = newValue
                discordPresence.isEnabled = newValue
            }
        }
        .onAppear { richPresenceEnabled = discordPresence.isEnabled }
    }
}
