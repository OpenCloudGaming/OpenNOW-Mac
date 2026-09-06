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
            SettingsSection("discord", "Discord"),
            SettingsSection("about", "About"),
            SettingsSection("system", "This Mac"),
        ]

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            InterfaceSettingsPage(viewModel: viewModel, uiScale: uiScale)
            DiscordSettingsPage(uiScale: uiScale)
                .settingsSection("discord")
            AboutSettingsPage(viewModel: viewModel, uiScale: uiScale)
                .settingsSection("about")
            SystemSettingsPage(viewModel: viewModel, uiScale: uiScale)
                .settingsSection("system")
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
