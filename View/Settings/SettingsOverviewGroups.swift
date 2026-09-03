import AppKit
import CryptoKit
import SwiftUI

struct StreamingSettingsGroup: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            GameplaySettingsPage(viewModel: viewModel, uiScale: uiScale)
            ServerLocationSettingsPage(viewModel: viewModel, uiScale: uiScale)
            ResolutionUpscalingSettingsPage(viewModel: viewModel, uiScale: uiScale)
        }
    }
}

struct ConnectionsSettingsGroup: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            ConnectionsSettingsPage(viewModel: viewModel, uiScale: uiScale)
            DiscordSettingsPage(uiScale: uiScale)
        }
    }
}

struct NetworkSettingsGroup: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SessionProxySettingsPage(viewModel: viewModel)
        }
    }
}

struct DiscordSettingsPage: View {
    let discordPresence: any DiscordPresenceServing = DiscordRichPresence.shared
    let uiScale: CGFloat
    @State private var richPresenceEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
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
        }
        .onAppear { richPresenceEnabled = discordPresence.isEnabled }
    }
}

struct GeneralSettingsGroup: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            InterfaceSettingsPage(viewModel: viewModel, uiScale: uiScale)
        }
    }
}

struct AboutSettingsGroup: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            AboutSettingsPage(viewModel: viewModel, uiScale: uiScale)
            SystemSettingsPage(viewModel: viewModel, uiScale: uiScale)
        }
    }
}
