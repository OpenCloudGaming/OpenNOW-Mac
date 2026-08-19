import AppKit
import CryptoKit
import SwiftUI

private enum SettingsVendorLayout {
    static let surface = Color(red: 18 / 255, green: 19 / 255, blue: 18 / 255)
    static let sidebar = Color(red: 31 / 255, green: 32 / 255, blue: 31 / 255)
    static let card = Color(red: 26 / 255, green: 27 / 255, blue: 26 / 255)
    static let cardRaised = Color(red: 34 / 255, green: 35 / 255, blue: 34 / 255)
    static let row = Color.white.opacity(0.045)
}

private extension Font {
    static func settingsNvidia(size: CGFloat, weight: MacForceNowNVIDIAFont.Weight = .regular) -> Font {
        MacForceNowNVIDIAFont.font(size: size, weight: weight)
    }
}

private extension Color {
    init(settingsHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let packed = digits.count == 6 ? UInt64(digits, radix: 16) ?? 0 : 0
        self.init(red: Double((packed >> 16) & 0xFF) / 255, green: Double((packed >> 8) & 0xFF) / 255, blue: Double(packed & 0xFF) / 255)
    }

    var settingsHexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .black
        // Converting a wide-gamut pick (the P3 wheel) into sRGB is colorimetric and
        // can land outside 0...1. Unclamped, that formats to more than six hex digits
        // and the stored value is rejected back to black.
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(color.redComponent), channel(color.greenComponent), channel(color.blueComponent))
    }
}

private struct SettingsAccountSnapshot: Sendable {
    let displayName: String
    let membershipTier: String
    let providerName: String
    let userId: String
    let authorizationState: String
    let authStatus: String
    let rememberSession: Bool

    @MainActor init(viewModel: CatalogViewModel) {
        displayName = viewModel.account.displayName.isEmpty ? "Signed in" : viewModel.account.displayName
        membershipTier = Self.membershipTier(viewModel: viewModel)
        providerName = Self.providerName(viewModel.account.providerName)
        userId = viewModel.session.userId.isEmpty ? viewModel.account.userId : viewModel.session.userId
        authorizationState = SettingsFormat.normalizedState(viewModel.account.authorizationState)
        authStatus = SettingsFormat.normalizedState(viewModel.account.authStatus)
        rememberSession = viewModel.account.rememberSession
    }

    var isAuthorized: Bool {
        authorizationState.caseInsensitiveCompare("Authorized") == .orderedSame
    }

    var isLoggedIn: Bool {
        authStatus.caseInsensitiveCompare("Logged In") == .orderedSame
    }

    @MainActor private static func membershipTier(viewModel: CatalogViewModel) -> String {
        if viewModel.subscriptionStatus.isAvailable { return viewModel.subscriptionStatus.membershipTier }
        if !viewModel.account.membershipTier.isEmpty { return viewModel.account.membershipTier }
        return viewModel.subscriptionStatus.membershipTier
    }

    private static func providerName(_ value: String) -> String {
        if value.isEmpty || value == "OPN" { return "Nvidia" }
        return value
    }
}

private struct SettingsRouteSnapshot {
    let displayValue: String
    let copyValue: String
    let summary: String

    init(regionUrl: String, revealSensitive: Bool) {
        if regionUrl.isEmpty {
            displayValue = "Automatic"
            copyValue = "Automatic"
            summary = "Automatic"
        } else {
            let host = SettingsFormat.endpointHost(regionUrl)
            displayValue = revealSensitive ? regionUrl : host
            copyValue = regionUrl
            summary = host
        }
    }
}

private enum SettingsAppMetadata {
    static var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? "MacForce Now Mac"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static var versionWithBuild: String {
        "\(version) (\(build))"
    }
}

private enum SettingsFormat {
    static func normalizedState(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "Unknown" : normalized.capitalized
    }

    static func maskedIdentifier(_ value: String) -> String {
        guard value.count > 10 else { return value.isEmpty ? "Unavailable" : "****" }
        return "\(value.prefix(6))****\(value.suffix(4))"
    }

    static func maskedEmail(_ value: String) -> String {
        guard let atIndex = value.firstIndex(of: "@") else { return value.isEmpty ? "Unavailable" : "****" }
        let name = String(value[..<atIndex])
        let domain = String(value[value.index(after: atIndex)...])
        return "\(name.prefix(2))****@\(domain)"
    }

    static func endpointHost(_ value: String) -> String {
        URL(string: value)?.host ?? value
    }
}

struct SettingsView: View {
    @Bindable var viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $viewModel.selectedSettingsGroup, uiScale: uiScale)
            SettingsContent(viewModel: viewModel, uiScale: uiScale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SettingsSurfaceBackground: View {
    var body: some View {
        ZStack {
            SettingsVendorLayout.surface
            LinearGradient(colors: [Color.openNowGreen.opacity(0.035), .clear], startPoint: .topLeading, endPoint: .center)
            LinearGradient(colors: [.black.opacity(0.22), .clear, .black.opacity(0.18)], startPoint: .leading, endPoint: .trailing)
        }
    }
}

private struct SettingsTabBar: View {
    @Binding var selection: CatalogSettingsGroup
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8 * uiScale) {
                    ForEach(CatalogSettingsGroup.allCases) { group in
                        SettingsTabItem(
                            title: group.title,
                            icon: group.icon,
                            isSelected: selection == group,
                            uiScale: uiScale
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selection = group
                            }
                        }
                    }
                }
                .padding(.horizontal, 16 * uiScale)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 52 * uiScale)
        .background(SettingsVendorLayout.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }
}

private struct SettingsTabItem: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let uiScale: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10 * uiScale) {
                Image(systemName: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(isSelected ? Color.openNowGreen : .white.opacity(0.52))
                    .frame(width: 18 * uiScale, height: 18 * uiScale)
                Text(title)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.58))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12 * uiScale)
            .padding(.vertical, 10 * uiScale)
            .frame(width: 150 * uiScale, height: 44 * uiScale)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? Color.openNowGreen : .clear)
                    .frame(width: 150 * uiScale, height: 3 * uiScale)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsContent: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22 * uiScale) {
                SettingsHeader(
                    title: viewModel.selectedSettingsGroup.title,
                    subtitle: viewModel.selectedSettingsGroup.subtitle,
                    uiScale: uiScale
                )
                if !viewModel.errorMessage.isEmpty {
                    SettingsMessageView(message: viewModel.errorMessage, systemImage: "exclamationmark.triangle.fill", uiScale: uiScale)
                }
                if !viewModel.actionMessage.isEmpty {
                    SettingsMessageView(message: viewModel.actionMessage, systemImage: "checkmark.circle.fill", uiScale: uiScale)
                }
                page
            }
            .padding(.horizontal, 28 * uiScale)
            .padding(.top, 28 * uiScale)
            .padding(.bottom, 48 * uiScale)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsSurfaceBackground())
    }

    @ViewBuilder private var page: some View {
        switch viewModel.selectedSettingsGroup {
        case .account:
            AccountSettingsPage(viewModel: viewModel)
        case .streaming:
            StreamingSettingsGroup(viewModel: viewModel)
        case .connections:
            ConnectionsSettingsGroup(viewModel: viewModel)
        case .general:
            GeneralSettingsGroup(viewModel: viewModel)
        case .about:
            AboutSettingsPage(viewModel: viewModel, uiScale: uiScale)
        }
    }
}

private struct SettingsHeader: View {
    let title: String
    let subtitle: String
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            HStack(alignment: .bottom, spacing: 18 * uiScale) {
                VStack(alignment: .leading, spacing: 8 * uiScale) {
                    Text(title.uppercased())
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                        .foregroundStyle(Color.openNowGreen)
                        .tracking(1.5)
                    Text(title)
                        .font(.settingsNvidia(size: 34 * uiScale, weight: .bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.settingsNvidia(size: 14 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
                Spacer(minLength: 24 * uiScale)
            }
        }
    }
}

private struct StreamingSettingsGroup: View {
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

private struct ConnectionsSettingsGroup: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            ConnectionsSettingsPage(viewModel: viewModel, uiScale: uiScale)
            DiscordSettingsPage(uiScale: uiScale)
        }
    }
}

private struct DiscordSettingsPage: View {
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
                    DiscordRichPresence.shared.isEnabled = newValue
                }
            }
        }
        .onAppear { richPresenceEnabled = DiscordRichPresence.shared.isEnabled }
    }
}

private struct GeneralSettingsGroup: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            InterfaceSettingsPage(viewModel: viewModel, uiScale: uiScale)
            SystemSettingsPage(viewModel: viewModel, uiScale: uiScale)
            ExperimentalFeaturesSettingsPage(viewModel: viewModel, uiScale: uiScale)
        }
    }
}

private struct AccountSettingsPage: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale
    @State private var revealSensitive = false
    @State private var copiedKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Membership", uiScale: uiScale) {
                HStack(alignment: .top, spacing: 20 * uiScale) {
                    ZStack {
                        SettingsVendorLayout.cardRaised
                            .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.42), lineWidth: 1) }
                        SettingsAccountAvatar(email: viewModel.account.email, size: 58 * uiScale)
                    }
                    .frame(width: 92 * uiScale, height: 92 * uiScale)

                    VStack(alignment: .leading, spacing: 12 * uiScale) {
                        HStack(alignment: .firstTextBaseline, spacing: 10 * uiScale) {
                            Text(account.displayName)
                                .font(.settingsNvidia(size: 25 * uiScale, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(account.membershipTier.uppercased())
                                .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                                .foregroundStyle(.black)
                                .tracking(0.8)
                                .padding(.horizontal, 8 * uiScale)
                                .frame(height: 20 * uiScale)
                                .background(Color.openNowGreen)
                        }
                        Text(accountSummaryText)
                            .font(.settingsNvidia(size: 13 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.66))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8 * uiScale) {
                            AboutStatusPill(title: "Provider", value: account.providerName, uiScale: uiScale)
                            AboutStatusPill(title: "Playtime", value: viewModel.subscriptionStatus.remainingPlaytimeText, uiScale: uiScale)
                            AboutStatusPill(title: "Region", value: route.summary, uiScale: uiScale)
                        }
                    }
                    Spacer(minLength: 0)
                    AccountHealthBadge(title: accountHealthTitle, subtitle: accountHealthSubtitle, positive: accountHealthPositive, uiScale: uiScale)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16 * uiScale) {
                    profilePrivacyCard
                    sessionCard
                }
                VStack(alignment: .leading, spacing: 16 * uiScale) {
                    profilePrivacyCard
                    sessionCard
                }
            }

            SettingsCard(title: "Playtime Statistics", uiScale: uiScale) {
                if viewModel.playtimeStatistics.sessionCount == 0 {
                    AccountEmptyState(title: "No completed streams recorded yet.", subtitle: "MacForce Now will track local playtime after your next MacForce Now session ends.", uiScale: uiScale)
                } else {
                    SettingsFlowLayout(spacing: 10 * uiScale) {
                        SettingsStatisticTile(label: "Total Playtime", value: durationText(viewModel.playtimeStatistics.totalSeconds), emphasized: true, uiScale: uiScale)
                        SettingsStatisticTile(label: "Sessions", value: "\(viewModel.playtimeStatistics.sessionCount)", uiScale: uiScale)
                        SettingsStatisticTile(label: "Last Session", value: durationText(viewModel.playtimeStatistics.lastSessionSeconds), uiScale: uiScale)
                        SettingsStatisticTile(label: "Average Session", value: durationText(viewModel.playtimeStatistics.averageSessionSeconds), uiScale: uiScale)
                        SettingsStatisticTile(label: "Longest Session", value: durationText(viewModel.playtimeStatistics.longestSessionSeconds), uiScale: uiScale)
                        SettingsStatisticTile(label: "Last Played", value: lastPlayedText, uiScale: uiScale)
                    }
                    if !viewModel.playtimeStatistics.lastPlayedTitle.isEmpty {
                        SettingsDivider(uiScale: uiScale)
                        AboutDetailRow(label: "Most Recent Game", value: viewModel.playtimeStatistics.lastPlayedTitle, copyValue: viewModel.playtimeStatistics.lastPlayedTitle, copiedKey: $copiedKey, uiScale: uiScale)
                    }
                }
            }
        }
    }

    private var profilePrivacyCard: some View {
        SettingsCard(title: "Profile & Privacy", uiScale: uiScale) {
            HStack(alignment: .center, spacing: 12 * uiScale) {
                VStack(alignment: .leading, spacing: 4 * uiScale) {
                    Text("Personal account details are masked by default.")
                        .font(.settingsNvidia(size: 14 * uiScale, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Reveal only when validating account state on your own machine.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                }
                Spacer()
                SettingsRevealButton(revealed: revealSensitive, uiScale: uiScale) { revealSensitive.toggle() }
            }
            SettingsDivider(uiScale: uiScale)
            AboutDetailRow(label: "Display Name", value: account.displayName, copyValue: account.displayName, copiedKey: $copiedKey, uiScale: uiScale)
            SettingsDivider(uiScale: uiScale)
            AboutDetailRow(label: "Email", value: displayedEmail, copyValue: viewModel.account.email, copiedKey: $copiedKey, copyDisabled: viewModel.account.email.isEmpty, uiScale: uiScale)
            SettingsDivider(uiScale: uiScale)
            AboutDetailRow(label: "User ID", value: displayedUserId, copyValue: account.userId, copiedKey: $copiedKey, copyDisabled: account.userId.isEmpty, uiScale: uiScale)
        }
    }

    private var sessionCard: some View {
        SettingsCard(title: "Session", uiScale: uiScale) {
            SettingsFlowLayout(spacing: 10 * uiScale) {
                AccountStatusTile(label: "Provider", value: account.providerName, positive: true, uiScale: uiScale)
                AccountStatusTile(label: "Authorization", value: account.authorizationState, positive: account.isAuthorized, uiScale: uiScale)
                AccountStatusTile(label: "Status", value: account.authStatus, positive: account.isLoggedIn, uiScale: uiScale)
                AccountStatusTile(label: "Remember", value: account.rememberSession ? "Enabled" : "Off", positive: account.rememberSession, uiScale: uiScale)
            }
            SettingsDivider(uiScale: uiScale)
            AboutDetailRow(label: "Preferred Region", value: route.displayValue, copyValue: route.copyValue, copiedKey: $copiedKey, uiScale: uiScale)
            SettingsDivider(uiScale: uiScale)
            AboutDetailRow(label: "Membership Usage", value: viewModel.subscriptionStatus.usageText, copyValue: viewModel.subscriptionStatus.usageText, copiedKey: $copiedKey, uiScale: uiScale)
            SettingsDivider(uiScale: uiScale)
            AboutDetailRow(label: "Last Login", value: dateText(viewModel.account.lastLoginAt), copyValue: dateText(viewModel.account.lastLoginAt), copiedKey: $copiedKey, uiScale: uiScale)
        }
    }

    private var account: SettingsAccountSnapshot {
        SettingsAccountSnapshot(viewModel: viewModel)
    }

    private var route: SettingsRouteSnapshot {
        SettingsRouteSnapshot(regionUrl: viewModel.selectedSettingsRegionUrl, revealSensitive: revealSensitive)
    }

    private var displayedUserId: String {
        revealSensitive ? account.userId : SettingsFormat.maskedIdentifier(account.userId)
    }

    private var displayedEmail: String {
        revealSensitive ? viewModel.account.email : SettingsFormat.maskedEmail(viewModel.account.email)
    }

    private var accountHealthPositive: Bool {
        account.isAuthorized && account.isLoggedIn
    }

    private var accountHealthTitle: String {
        accountHealthPositive ? "ACTIVE" : "ATTENTION"
    }

    private var accountHealthSubtitle: String {
        accountHealthPositive ? "Session authorized" : "Re-auth may be required"
    }

    private var accountSummaryText: String {
        let availability = viewModel.subscriptionStatus.isAvailable ? viewModel.subscriptionStatus.usageText : "subscription details are still refreshing"
        return "\(account.providerName) account on \(account.membershipTier) membership. \(availability)."
    }

    private var lastPlayedText: String {
        guard let date = viewModel.playtimeStatistics.lastPlayedAt else { return "-" }
        return dateText(date)
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func durationText(_ seconds: Double) -> String {
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0, minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }
}

private struct AccountHealthBadge: View {
    let title: String
    let subtitle: String
    let positive: Bool
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * uiScale) {
            HStack(spacing: 7 * uiScale) {
                Circle()
                    .fill(positive ? Color.openNowGreen : Color.orange)
                    .frame(width: 7 * uiScale, height: 7 * uiScale)
                Text(title)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                    .foregroundStyle(positive ? Color.openNowGreen : .white.opacity(0.88))
                    .tracking(1.1)
            }
            Text(subtitle)
                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(2)
        }
        .padding(.horizontal, 14 * uiScale)
        .frame(width: 172 * uiScale, height: 64 * uiScale, alignment: .leading)
        .background(SettingsVendorLayout.cardRaised)
        .overlay(alignment: .leading) { Rectangle().fill(positive ? Color.openNowGreen : Color.orange).frame(width: 3 * uiScale) }
        .overlay { Rectangle().stroke(positive ? Color.openNowGreen.opacity(0.35) : Color.orange.opacity(0.30), lineWidth: 1) }
    }
}

private struct SettingsRevealButton: View {
    let revealed: Bool
    let uiScale: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(revealed ? "HIDE DETAILS" : "REVEAL DETAILS")
                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(revealed ? .black : .white.opacity(isHovering ? 0.94 : 0.82))
                .tracking(0.8)
                .padding(.horizontal, 13 * uiScale)
                .frame(height: 32 * uiScale)
                .background(revealed ? Color.openNowGreen.opacity(isHovering ? 0.90 : 1) : Color.white.opacity(isHovering ? 0.10 : 0.065))
                .overlay { Rectangle().stroke(revealed ? Color.openNowGreen : Color.white.opacity(isHovering ? 0.20 : 0.13), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct SettingsAccountAvatar: View {
    let email: String
    let size: CGFloat

    private var gravatarURL: URL? {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty else { return nil }
        let digest = Insecure.MD5.hash(data: Data(normalizedEmail.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=\(Int(size * 3))&d=404")
    }

    var body: some View {
        Group {
            if let gravatarURL {
                AsyncImage(url: gravatarURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallbackAvatar
                    }
                }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
    }

    private var fallbackAvatar: some View {
        VendorResourceImage(name: "avatar_generic_118", fileExtension: "svg")
            .scaledToFill()
    }
}

private struct AccountStatusTile: View {
    let label: String
    let value: String
    let positive: Bool
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.44))
            Text(value.isEmpty ? "Unknown" : value)
                .font(.settingsNvidia(size: 16 * uiScale, weight: .bold))
                .foregroundStyle(positive ? Color.openNowGreen : .white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 14 * uiScale)
        .padding(.vertical, 12 * uiScale)
        .frame(width: 188 * uiScale, height: 74 * uiScale, alignment: .leading)
        .background(Color.white.opacity(positive ? 0.065 : 0.045))
        .overlay { Rectangle().stroke(positive ? Color.openNowGreen.opacity(0.32) : Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct AccountEmptyState: View {
    let title: String
    let subtitle: String
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 12 * uiScale) {
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 4 * uiScale, height: 44 * uiScale)
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text(title)
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                Text(subtitle)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer(minLength: 0)
        }
        .padding(12 * uiScale)
        .background(Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct SettingsStatisticTile: View {
    let label: String
    let value: String
    var emphasized = false
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.44))
            Text(value.isEmpty ? "-" : value)
                .font(.settingsNvidia(size: (emphasized ? 24 : 19) * uiScale, weight: .bold))
                .foregroundStyle(emphasized ? Color.openNowGreen : .white.opacity(0.90))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 14 * uiScale)
        .padding(.vertical, 12 * uiScale)
        .frame(width: (emphasized ? 206 : 164) * uiScale, height: 78 * uiScale, alignment: .leading)
        .background(Color.white.opacity(emphasized ? 0.075 : 0.052))
        .overlay { Rectangle().stroke(emphasized ? Color.openNowGreen.opacity(0.36) : Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct InterfaceSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @AppStorage(MacForceNowInterfacePreferences.controllerModeEnabledKey) private var controllerModeEnabled = false
    @AppStorage(MacForceNowInterfacePreferences.uiScaleKey) private var uiScaleStorage = MacForceNowInterfacePreferences.defaultUIScale
    @StateObject private var inputRouter = ControllerInputRouter()
    @StateObject private var steamNavigator = GamepadUINavigator()

    private var isAnyControllerConnected: Bool {
        inputRouter.isControllerConnected || steamNavigator.isSteamControllerConnected
    }

    private var activeGlyphs: ControllerInputGlyphSet {
        inputRouter.isControllerConnected ? inputRouter.glyphs : steamNavigator.glyphs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Mode", uiScale: uiScale) {
                HStack(alignment: .center, spacing: 18 * uiScale) {
                    Rectangle()
                        .fill(controllerModeEnabled ? Color.openNowGreen : Color.white.opacity(0.18))
                        .frame(width: 4 * uiScale, height: 58 * uiScale)
                    VStack(alignment: .leading, spacing: 6 * uiScale) {
                        Text(controllerModeEnabled ? "Controller mode is active" : "Desktop catalog mode is active")
                            .font(.settingsNvidia(size: 18 * uiScale, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Controller mode replaces the catalog with a TV-style interface built for gamepads, while keeping keyboard and pointer fallback available.")
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12 * uiScale)
                    SettingsStatusPill(title: "INPUT", value: activeGlyphs.deviceName, positive: isAnyControllerConnected, uiScale: uiScale)
                }
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Controller Mode", subtitle: "Use a clean Netflix-style catalog with large focus targets, controller shortcuts, and dynamic input glyphs.", isOn: controllerModeEnabled, uiScale: uiScale) { enabled in
                    controllerModeEnabled = enabled
                }
            }

            SettingsCard(title: "Display", uiScale: uiScale) {
                SettingsSliderRow(title: "Interface Scale", valueText: "\(Int((uiScaleStorage * 100).rounded()))%", value: uiScaleStorage, range: MacForceNowInterfacePreferences.uiScaleRange, step: 0.05, uiScale: uiScale) { scale in
                    uiScaleStorage = scale
                }
                SettingsDivider(uiScale: uiScale)
                Text("Scales the catalog, settings, and in-stream HUD. Increase it on high-resolution displays (for example 5K) when the interface feels too small.")
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(title: "Controls", uiScale: uiScale) {
                SettingsFlowLayout(spacing: 10 * uiScale) {
                    InterfaceInputLegend(title: "Move", glyphs: [activeGlyphs.left, activeGlyphs.up, activeGlyphs.down, activeGlyphs.right], uiScale: uiScale)
                    InterfaceInputLegend(title: "Select", glyphs: [activeGlyphs.confirm], uiScale: uiScale)
                    InterfaceInputLegend(title: "Back", glyphs: [activeGlyphs.back], uiScale: uiScale)
                    InterfaceInputLegend(title: "Search", glyphs: [activeGlyphs.search], uiScale: uiScale)
                    InterfaceInputLegend(title: "Actions", glyphs: [activeGlyphs.actions], uiScale: uiScale)
                    InterfaceInputLegend(title: "Rail", glyphs: [activeGlyphs.pageLeft, activeGlyphs.pageRight], uiScale: uiScale)
                }
                SettingsDivider(uiScale: uiScale)
                HStack(alignment: .center, spacing: 12 * uiScale) {
                    Image(systemName: isAnyControllerConnected ? "gamecontroller.fill" : "keyboard")
                        .font(.settingsNvidia(size: 18 * uiScale, weight: .bold))
                        .foregroundStyle(Color.openNowGreen)
                        .frame(width: 34 * uiScale, height: 34 * uiScale)
                        .background(Color.openNowGreen.opacity(0.12))
                        .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.30), lineWidth: 1) }
                    VStack(alignment: .leading, spacing: 4 * uiScale) {
                        Text(isAnyControllerConnected ? "Controller glyphs are live" : "Keyboard fallback is active")
                            .font(.settingsNvidia(size: 14 * uiScale, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                        Text(isAnyControllerConnected ? "Hints use symbols exposed by the connected game controller whenever the system provides them." : "Connect a controller to switch hints from keyboard keys to controller button glyphs automatically.")
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear { steamNavigator.start() }
        .onDisappear { steamNavigator.stop() }
    }
}

private struct InterfaceInputLegend: View {
    let title: String
    let glyphs: [ControllerInputGlyph]
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 9 * uiScale) {
            Text(title.uppercased())
                .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.44))
            HStack(spacing: 6 * uiScale) {
                ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                    InterfaceGlyphPill(glyph: glyph, uiScale: uiScale)
                }
            }
        }
        .padding(.horizontal, 12 * uiScale)
        .padding(.vertical, 11 * uiScale)
        .frame(minWidth: 132 * uiScale, minHeight: 70 * uiScale, alignment: .leading)
        .background(Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct InterfaceGlyphPill: View {
    let glyph: ControllerInputGlyph
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 6 * uiScale) {
            if !glyph.symbolName.isEmpty {
                Image(systemName: glyph.symbolName)
                    .font(.settingsNvidia(size: 13 * uiScale, weight: .bold))
            }
            Text(glyph.fallbackText)
                .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.openNowGreen)
        .padding(.horizontal, 8 * uiScale)
        .frame(height: 28 * uiScale)
        .background(Color.openNowGreen.opacity(0.12))
        .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.28), lineWidth: 1) }
        .accessibilityLabel(glyph.accessibilityLabel)
    }
}

private struct ConnectionsSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        let stores = connectionStores
        SettingsCard(title: "Store Connections", uiScale: uiScale) {
            if stores.isEmpty {
                AccountEmptyState(title: "No store providers available.", subtitle: "MacForce Now did not return any account providers for this session.", uiScale: uiScale)
            } else {
                StoreConnectionsOverview(connectedCount: connectedStoreCount(in: stores), totalCount: stores.count, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                VStack(spacing: 8 * uiScale) {
                    ForEach(stores, id: \.self) { store in
                        StoreConnectionRow(viewModel: viewModel, store: store, uiScale: uiScale)
                    }
                }
            }
        }
    }

    private var connectionStores: [String] {
        var seen = Set<String>()
        var stores: [String] = []
        for store in viewModel.storeDefinitions.map(\.store) + viewModel.accountStores.map(\.store) where !store.isEmpty {
            let key = store.lowercased()
            guard !seen.contains(key), !isHiddenConnectionStore(store) else { continue }
            seen.insert(key)
            stores.append(store)
        }
        return stores.sorted { lhs, rhs in
            let lhsConnected = viewModel.accountStatus(forStore: lhs) != nil
            let rhsConnected = viewModel.accountStatus(forStore: rhs) != nil
            if lhsConnected != rhsConnected { return lhsConnected }
            return viewModel.displayName(forStore: lhs).localizedStandardCompare(viewModel.displayName(forStore: rhs)) == .orderedAscending
        }
    }

    private func connectedStoreCount(in stores: [String]) -> Int {
        stores.filter { viewModel.accountStatus(forStore: $0) != nil }.count
    }

    private func isHiddenConnectionStore(_ store: String) -> Bool {
        let rawKey = normalizedStoreKey(store)
        let displayKey = normalizedStoreKey(viewModel.displayName(forStore: store))
        return Self.hiddenConnectionStoreKeys.contains(rawKey) || Self.hiddenConnectionStoreKeys.contains(displayKey)
    }

    private func normalizedStoreKey(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static let hiddenConnectionStoreKeys: Set<String> = [
        "ea",
        "eaapp",
        "electronicarts",
        "gog",
        "gogcom",
        "none",
        "nvidia",
        "origin",
        "stove",
        "unknown"
    ]
}


private struct StoreConnectionsOverview: View {
    let connectedCount: Int
    let totalCount: Int
    let uiScale: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 14 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text("Library ownership sync")
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white)
                Text("Connected stores can sync library ownership before launch.")
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer(minLength: 0)
            SettingsStatusPill(title: "CONNECTED", value: "\(connectedCount)/\(totalCount)", positive: connectedCount > 0, uiScale: uiScale)
        }
    }
}

private struct StoreConnectionRow: View {
    let viewModel: CatalogViewModel
    let store: String
    let uiScale: CGFloat

    var body: some View {
        let account = viewModel.accountStatus(forStore: store)
        let definition = viewModel.storeDefinitions.first { $0.store.caseInsensitiveCompare(store) == .orderedSame }
        let displayName = viewModel.displayName(forStore: store)
        let iconAsset = StoreIconAsset.resolve(store: store, displayName: displayName)
        let iconURL = definition?.smallImageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let isConnected = account != nil
        let supportsLinking = definition?.isAccountLinkingSupported == true || account?.hasAccountLinkingData == true
        HStack(alignment: .center, spacing: 16 * uiScale) {
            Rectangle()
                .fill(isConnected ? Color.openNowGreen : Color.white.opacity(0.18))
                .frame(width: 4 * uiScale, height: 46 * uiScale)
            StoreIcon(asset: iconAsset, imageURL: iconURL, connected: isConnected, uiScale: uiScale)
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text(displayName)
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(isConnected ? .white : .white.opacity(0.86))
                Text(statusText(account))
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(isConnected ? .white.opacity(0.62) : .white.opacity(0.44))
            }
            Spacer(minLength: 12 * uiScale)
            SettingsStatusPill(title: isConnected ? "LINKED" : "AVAILABLE", value: isConnected ? connectionDetail(account) : "Not linked", positive: isConnected, uiScale: uiScale)
            if account?.hasAccountSyncingData == true {
                SettingsActionButton(title: "SYNC", tone: .secondary, minimumWidth: 86 * uiScale, uiScale: uiScale) { viewModel.syncStoreAccount(store) }
            }
            if supportsLinking {
                SettingsActionButton(title: account == nil ? "CONNECT" : "MANAGE", minimumWidth: 96 * uiScale, uiScale: uiScale) { viewModel.linkStoreAccount(store) }
            }
        }
        .padding(12 * uiScale)
        .background(isConnected ? Color.openNowGreen.opacity(0.095) : SettingsVendorLayout.row)
        .overlay { Rectangle().stroke(isConnected ? Color.openNowGreen.opacity(0.34) : Color.white.opacity(0.08), lineWidth: 1) }
    }

    private func statusText(_ account: CatalogStoreAccount?) -> String {
        guard let account else { return "Not connected" }
        if !account.userDisplayName.isEmpty { return "Connected as \(account.userDisplayName)" }
        if !account.userIdentifier.isEmpty { return "Connected as \(account.userIdentifier)" }
        if account.totalSyncedGames > 0 { return "\(account.totalSyncedGames) synced games" }
        if !account.syncState.isEmpty { return account.syncState.replacingOccurrences(of: "_", with: " ").capitalized }
        return "Connected"
    }

    private func connectionDetail(_ account: CatalogStoreAccount?) -> String {
        guard let account else { return "Not linked" }
        if account.totalSyncedGames > 0 { return "\(account.totalSyncedGames) games" }
        if !account.syncDate.isEmpty { return "Synced" }
        return "Ready"
    }
}

private struct StoreIcon: View {
    let asset: StoreIconAsset?
    let imageURL: String?
    let connected: Bool
    let uiScale: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(connected ? Color.openNowGreen.opacity(0.18) : Color.white.opacity(0.075))
            if let url = resolvedImageURL {
                StoreRemoteIconImage(url: url, asset: asset, connected: connected)
            } else {
                StoreLocalIconImage(asset: asset, connected: connected)
            }
        }
        .frame(width: 42 * uiScale, height: 42 * uiScale)
        .overlay { Rectangle().stroke(connected ? Color.openNowGreen.opacity(0.42) : Color.white.opacity(0.12), lineWidth: 1) }
        .accessibilityHidden(true)
    }

    private var resolvedImageURL: URL? {
        guard let imageURL, !imageURL.isEmpty else { return nil }
        return URL(string: imageURL)
    }
}

private struct StoreRemoteIconImage: View {
    let url: URL
    let asset: StoreIconAsset?
    let connected: Bool

    @State private var image: NSImage?
    @State private var hasFailed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
                    .saturation(connected ? 1 : 0.65)
                    .opacity(connected ? 1 : 0.68)
            } else if hasFailed {
                StoreLocalIconImage(asset: asset, connected: connected)
            } else {
                StoreLocalIconImage(asset: asset, connected: connected)
                    .opacity(0.42)
            }
        }
        .task(id: url) { await loadImage() }
    }

    @MainActor
    private func loadImage() async {
        image = nil
        hasFailed = false
        guard let cached = await CatalogImageCache.shared.image(for: url), !Task.isCancelled else {
            hasFailed = !Task.isCancelled
            return
        }
        image = cached.image
        hasFailed = false
    }
}

private struct StoreLocalIconImage: View {
    let asset: StoreIconAsset?
    let connected: Bool

    var body: some View {
        if let asset, let image = StoreIconImage.loadImage(named: asset.assetName) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(asset.padding)
                .saturation(connected ? 1 : 0.65)
                .opacity(connected ? 1 : 0.68)
        } else {
            Image(systemName: "link")
                .font(.settingsNvidia(size: 17, weight: .bold))
                .foregroundStyle(connected ? Color.openNowGreen : .white.opacity(0.56))
        }
    }
}

private enum StoreIconImage {
    @MainActor static func loadImage(named name: String) -> NSImage? {
        let cacheKey = name as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "StoreIcons") ?? Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Resources/StoreIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    @MainActor private static let cache = NSCache<NSString, NSImage>()
}

private enum StoreIconAsset: CaseIterable {
    case battlenet
    case epicGames
    case steam
    case ubisoftConnect
    case xbox
    case gaijin

    var assetName: String {
        switch self {
        case .battlenet: return "store-battlenet"
        case .epicGames: return "store-epic-games"
        case .steam: return "store-steam"
        case .ubisoftConnect: return "store-ubisoft-connect"
        case .xbox: return "store-xbox"
        case .gaijin: return "store-gaijin"
        }
    }

    var padding: CGFloat {
        switch self {
        case .epicGames: return 5
        case .steam, .xbox: return 4
        default: return 6
        }
    }

    static func resolve(store: String, displayName: String) -> StoreIconAsset? {
        let key = normalized(store)
        let displayKey = normalized(displayName)
        let combined = key + displayKey
        if combined.contains("battlenet") || combined.contains("battle") || combined.contains("blizzard") { return .battlenet }
        if combined.contains("epic") { return .epicGames }
        if combined.contains("steam") { return .steam }
        if combined.contains("ubisoft") || combined.contains("uplay") { return .ubisoftConnect }
        if combined.contains("xbox") || combined.contains("microsoft") { return .xbox }
        if combined.contains("gaijin") { return .gaijin }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

private struct ExperimentalFeaturesSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @ObservedObject private var hidMonitor = SteamControllerHIDMonitor.shared
    @AppStorage(RecordingEditorBetaPreference.key) private var recordingEditorEarlyBetaEnabled = false
    @AppStorage(SteamControllerPreference.key) private var steamControllerSupportEnabled = false
    @ObservedObject private var mappingStore = SteamControllerMappingStore.shared
    @State private var showingControllerTest = false
    @State private var showingControllerMapping = false
    @State private var permissionResetInFlight = false
    @State private var permissionResetError: String?
    @State private var accessibilityPermissionGranted = SteamControllerLocalCursorInjector.hasAccessibilityPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Alpha Access", uiScale: uiScale) {
                SettingsToggleRow(
                    title: "Remote Co-Op Alpha",
                    subtitle: viewModel.remoteCoOpPreferences.isAlphaOptedIn ? "Remote Co-Op settings are available from Gameplay settings." : "Opt in before Remote Co-Op settings, preferences, and stream HUD controls appear.",
                    isOn: viewModel.remoteCoOpPreferences.isAlphaOptedIn,
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpAlphaOptedIn
                )
            }

            SettingsCard(title: "Stream Transport", uiScale: uiScale) {
                SettingsToggleRow(
                    title: "Native/NVST Transport",
                    subtitle: "Off uses the default WebRTC session path. On requests native NVST secure RTSP transport with matching CloudMatch headers.",
                    isOn: viewModel.streamProfile.transportMode.value == "nvst",
                    uiScale: uiScale,
                    action: viewModel.setNVSTTransportEnabled
                )
            }

            SettingsCard(title: "Recording", uiScale: uiScale) {
                SettingsToggleRow(
                    title: "Recording Editor Early Beta",
                    subtitle: recordingEditorEarlyBetaEnabled ? "Trim, arrange, crop, audio, and export tools are unlocked in Recordings." : "Opt in before recording editor controls appear in Recordings.",
                    isOn: recordingEditorEarlyBetaEnabled,
                    uiScale: uiScale,
                    action: setRecordingEditorEarlyBetaEnabled
                )
            }

            SettingsCard(title: "Input", uiScale: uiScale) {
                HStack(alignment: .center, spacing: 18 * uiScale) {
                    VStack(alignment: .leading, spacing: 5 * uiScale) {
                        Text("Steam Controller Support")
                            .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                            .foregroundStyle(.white.opacity(1))
                        Text(steamControllerSupportEnabled ? "Valve Steam Controller input is forwarded to streams. Requires the Input Monitoring permission and the Steam client to be closed." : "Opt in to recognize Valve Steam Controllers (original and 2026 models) over USB, dongle, or Puck during streams.")
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { steamControllerSupportEnabled }, set: { setSteamControllerSupportEnabled($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if steamControllerSupportEnabled {
                    SettingsDivider(uiScale: uiScale)
                    HStack(spacing: 12 * uiScale) {
                        Image(systemName: hidMonitor.inputMonitoringPermissionGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 14 * uiScale))
                            .foregroundStyle(hidMonitor.inputMonitoringPermissionGranted ? Color.openNowGreen : .orange)

                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text(hidMonitor.inputMonitoringPermissionGranted ? "Input Monitoring Permission Granted" : "Input Monitoring Permission Required")
                                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.88))
                            Text(hidMonitor.inputMonitoringPermissionGranted ? "Steam Controller HID access is enabled" : "Grant permission in System Settings → Privacy & Security → Input Monitoring")
                                .font(.settingsNvidia(size: 11 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                        }

                        Spacer()

                        if !hidMonitor.inputMonitoringPermissionGranted {
                            HStack(spacing: 8 * uiScale) {
                                Button("Grant Permission") {
                                    hidMonitor.requestInputMonitoringPermission()
                                }
                                .buttonStyle(MacForceNowCompactButtonStyle(uiScale: uiScale))

                                Button(permissionResetInFlight ? "Resetting…" : "Reset Permission") {
                                    resetInputMonitoringPermission()
                                }
                                .buttonStyle(MacForceNowCompactButtonStyle(role: .destructive, uiScale: uiScale))
                                .disabled(permissionResetInFlight)
                                .help("Clears the stale Input Monitoring entry for this app via tccutil, then quits and relaunches MacForce Now.")
                            }
                        } else {
                            Button(permissionResetInFlight ? "Resetting…" : "Reset Permission") {
                                resetInputMonitoringPermission()
                            }
                            .buttonStyle(MacForceNowCompactButtonStyle(role: .destructive, uiScale: uiScale))
                            .disabled(permissionResetInFlight)
                            .help("Clears the stale Input Monitoring entry for this app via tccutil, then quits and relaunches MacForce Now.")
                        }
                    }

                    SettingsDivider(uiScale: uiScale)
                    HStack(spacing: 16 * uiScale) {
                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text("Monitor Status")
                                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.58))
                            HStack(spacing: 6 * uiScale) {
                                Circle()
                                    .fill(hidMonitor.isMonitorActive ? Color.openNowGreen : .red)
                                    .frame(width: 8 * uiScale, height: 8 * uiScale)
                                Text(hidMonitor.isMonitorActive ? "Active" : "Inactive")
                                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.88))
                            }
                        }

                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text("Devices Matched")
                                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.58))
                            Text("\(hidMonitor.matchedDeviceCount)")
                                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.88))
                        }

                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text("Controllers Connected")
                                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.58))
                            Text("\(SteamControllerHIDMonitor.connectedControllerCount)")
                                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.88))
                        }

                        Spacer()
                    }

                    SettingsDivider(uiScale: uiScale)
                    HStack {
                        VStack(alignment: .leading, spacing: 5 * uiScale) {
                            Text("Test Controller")
                                .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(1))
                            Text("Open a visual tester to verify button presses, stick positions, and trigger values.")
                                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        Spacer()
                        Button("Open Tester") {
                            showingControllerTest = true
                        }
                        .buttonStyle(MacForceNowCompactButtonStyle(uiScale: uiScale))
                    }

                    SettingsDivider(uiScale: uiScale)
                    HStack {
                        VStack(alignment: .leading, spacing: 5 * uiScale) {
                            Text("Controller Mapping")
                                .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(1))
                            Text(mappingStore.activeProfile.map { "Profile \"\($0.name)\" is applied to streams." } ?? "Bind every button, pad, and stick to a keyboard key, mouse action, or gamepad combo.")
                                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        Spacer()
                        Button("Open Mapping") {
                            showingControllerMapping = true
                        }
                        .buttonStyle(MacForceNowCompactButtonStyle(uiScale: uiScale))
                    }
                    .sheet(isPresented: $showingControllerMapping) {
                        SteamControllerMappingView()
                    }

                    SettingsDivider(uiScale: uiScale)
                    HStack(spacing: 12 * uiScale) {
                        Image(systemName: accessibilityPermissionGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 14 * uiScale))
                            .foregroundStyle(accessibilityPermissionGranted ? Color.openNowGreen : .orange)

                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text(accessibilityPermissionGranted ? "Accessibility Permission Granted" : "Accessibility Permission Required")
                                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                                .foregroundStyle(.white.opacity(0.88))
                            Text(accessibilityPermissionGranted ? "Holding the Steam button lets the right pad move the real macOS cursor mid-stream." : "Without it, holding the Steam button and moving a pad does nothing during a stream. Grant permission in System Settings → Privacy & Security → Accessibility.")
                                .font(.settingsNvidia(size: 11 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                        }

                        Spacer()

                        if !accessibilityPermissionGranted {
                            Button("Grant Permission") {
                                SteamControllerLocalCursorInjector.requestAccessibilityPermission()
                            }
                            .buttonStyle(MacForceNowCompactButtonStyle(uiScale: uiScale))
                        }
                    }
                    .onAppear { accessibilityPermissionGranted = SteamControllerLocalCursorInjector.hasAccessibilityPermission }
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        accessibilityPermissionGranted = SteamControllerLocalCursorInjector.hasAccessibilityPermission
                    }
                }
            }
        }
        .sheet(isPresented: $showingControllerTest) {
            SteamControllerTestView()
        }
        .alert(
            "Reset Failed",
            isPresented: Binding(
                get: { permissionResetError != nil },
                set: { presented in if !presented { permissionResetError = nil } }
            )
        ) {
            Button("OK") { permissionResetError = nil }
        } message: {
            Text(permissionResetError ?? "")
        }
    }

    private func setRecordingEditorEarlyBetaEnabled(_ enabled: Bool) {
        recordingEditorEarlyBetaEnabled = enabled
    }

    private func setSteamControllerSupportEnabled(_ enabled: Bool) {
        steamControllerSupportEnabled = enabled
        SteamControllerHIDMonitor.shared.setEnabled(enabled)
    }

    private func resetInputMonitoringPermission() {
        guard !permissionResetInFlight else { return }
        permissionResetInFlight = true
        Task.detached {
            do {
                try SteamControllerHIDMonitor.resetInputMonitoringPermissionViaTccUtil(thenRelaunch: true)
            } catch {
                await MainActor.run {
                    permissionResetInFlight = false
                    permissionResetError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}

private struct GameplaySettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        let qualityLocked = !viewModel.streamingQualityProfileAllowsCustomization
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Streaming Profile", uiScale: uiScale) {
                GameplayProfileOverview(
                    mode: streamingProfileMode,
                    resolution: viewModel.streamProfile.resolution.label,
                    frameRate: "\(viewModel.streamProfile.fps) FPS",
                    codec: viewModel.streamProfile.codec.label,
                    bitrate: "\(viewModel.streamProfile.maxBitrateMbps) Mbps",
                    colorPrecision: viewModel.streamProfile.colorQuality.label,
                    dataUsage: estimatedDataUsage,
                    uiScale: uiScale
                )
            }

            SettingsCard(title: "Streaming Quality", uiScale: uiScale) {
                SettingsOptionRow(title: "Aspect Ratio", subtitle: qualityLocked ? lockedProfileSubtitle : "Controls the available resolution list.", options: OPNStreamPreferences.aspectOptions.map(\.label), selectedIndex: viewModel.streamProfile.aspectIndex, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setAspectIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Resolution", subtitle: qualityLocked ? lockedProfileSubtitle : "Current target: \(viewModel.streamProfile.resolution.label).", options: OPNStreamPreferences.resolutionOptions(forAspect: viewModel.streamProfile.aspectIndex).map(\.label), selectedIndex: viewModel.streamProfile.resolutionIndex, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setResolutionIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Frame Rate", subtitle: qualityLocked ? lockedProfileSubtitle : "Limited by the active display refresh rate.", options: OPNStreamPreferences.fpsOptions.map { "\($0) FPS" }, selectedIndex: viewModel.streamProfile.fpsIndex, enabled: OPNStreamPreferences.fpsOptions.map { OPNStreamPreferences.fpsSupported($0, capabilities: viewModel.streamCapabilities) }, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setFpsIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Codec", subtitle: qualityLocked ? lockedProfileSubtitle : "Unavailable hardware codecs are disabled.", options: OPNStreamPreferences.codecOptions.map(\.label), selectedIndex: viewModel.streamProfile.codecIndex, enabled: OPNStreamPreferences.codecOptions.map { OPNStreamPreferences.codecSupported($0, capabilities: viewModel.streamCapabilities) }, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setCodecIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Maximum Bitrate", subtitle: qualityLocked ? lockedProfileSubtitle : "Higher bitrate improves clarity on stable connections.", options: OPNStreamPreferences.bitrateOptions.map(\.label), selectedIndex: viewModel.streamProfile.bitrateIndex, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setBitrateIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Color Precision", subtitle: qualityLocked ? lockedProfileSubtitle : "10-bit modes require HEVC, AV1, or Auto support.", options: OPNStreamPreferences.colorQualityOptions.map(\.label), selectedIndex: viewModel.streamProfile.colorQualityIndex, enabled: OPNStreamPreferences.colorQualityOptions.map { OPNStreamPreferences.colorQualitySupported($0, codec: viewModel.streamProfile.codec, capabilities: viewModel.streamCapabilities) }, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setColorQualityIndex)
            }

            SettingsCard(title: "Stream Transport", uiScale: uiScale) {
                SettingsOptionRow(title: "Quality Profile", subtitle: "Maps to the vendor streaming profile sent with the session request.", options: OPNStreamPreferences.streamingQualityProfileOptions.map(\.label), selectedIndex: viewModel.streamProfile.streamingQualityProfileIndex, uiScale: uiScale, action: viewModel.setStreamingQualityProfileIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Cloud G-Sync", subtitle: qualityLocked ? lockedProfileSubtitle : "Request cloud-side G-Sync when the server and stream mode support it.", isOn: viewModel.streamProfile.enableCloudGsync, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setCloudGsyncEnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Logical Resolution Fallback", subtitle: qualityLocked ? lockedProfileSubtitle : "Allow the stream request to fall back to logical display resolution.", isOn: viewModel.streamProfile.fallbackToLogicalResolution, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setFallbackToLogicalResolution)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "HUD Stream", subtitle: qualityLocked ? lockedProfileSubtitle : "Controls vendor HUD streaming metadata mode.", options: OPNStreamPreferences.hudStreamingModeOptions.map(\.label), selectedIndex: viewModel.streamProfile.hudStreamingModeIndex, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setHudStreamingModeIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "SDR Color Space", subtitle: qualityLocked ? lockedProfileSubtitle : "Requested SDR color-space metadata.", options: OPNStreamPreferences.colorSpaceOptions.map(\.label), selectedIndex: viewModel.streamProfile.sdrColorSpaceIndex, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setSDRColorSpaceIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "HDR Color Space", subtitle: qualityLocked ? lockedProfileSubtitle : "Requested HDR color-space metadata.", options: OPNStreamPreferences.colorSpaceOptions.map(\.label), selectedIndex: viewModel.streamProfile.hdrColorSpaceIndex, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setHDRColorSpaceIndex)
            }

            SettingsCard(title: "Gameplay", uiScale: uiScale) {
                SettingsToggleRow(title: "L4S", subtitle: qualityLocked ? lockedProfileSubtitle : "Use low-latency scalable throughput when available.", isOn: viewModel.streamProfile.enableL4S, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setL4SEnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "HDR", subtitle: qualityLocked ? lockedProfileSubtitle : "Requires a compatible display and stream capability.", isOn: viewModel.streamProfile.enableHdr, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setHDREnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Power Saver", subtitle: qualityLocked ? lockedProfileSubtitle : "Reduce resource use when possible.", isOn: viewModel.streamProfile.enablePowerSaver, isLocked: qualityLocked, uiScale: uiScale, action: viewModel.setPowerSaverEnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Prevent Display Sleep", subtitle: "Keeps the monitor awake while a stream is active.", isOn: viewModel.streamProfile.preventDisplaySleepWhileStreaming, uiScale: uiScale, action: viewModel.setPreventDisplaySleepWhileStreaming)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Direct Mouse Input", subtitle: "Send mouse input directly to the stream.", isOn: viewModel.streamProfile.directMouseInput, uiScale: uiScale, action: viewModel.setDirectMouseInputEnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Anti-AFK Mouse Movement", subtitle: "Moves the stream mouse every 60 seconds while a stream is active. Cmd-K toggles it in-stream.", isOn: viewModel.streamProfile.antiAFKMouseMovementEnabled, uiScale: uiScale, action: viewModel.setAntiAFKMouseMovementEnabled)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Suppress Input When Inactive", subtitle: "Avoid sending input while MacForce Now is not focused.", isOn: viewModel.streamProfile.suppressInputWhenInactive, uiScale: uiScale, action: viewModel.setSuppressInputWhenInactive)
            }

            if viewModel.remoteCoOpPreferences.isAlphaOptedIn {
                SettingsCard(title: "Remote Co-Op", uiScale: uiScale) {
                    SettingsToggleRow(title: "Enable Remote Co-Op", subtitle: "Allows the stream HUD to generate an invite code for a remote player. Changes apply to newly launched streams.", isOn: viewModel.remoteCoOpPreferences.isEnabled, uiScale: uiScale, action: viewModel.setRemoteCoOpEnabled)
                    SettingsDivider(uiScale: uiScale)
                    SettingsOptionRow(title: "Reserved Controllers", subtitle: "Advertises remote gamepad slots to GeForce NOW before launch. Player 2 requires at least one reserved slot.", options: ["None", "1 Guest", "2 Guests", "3 Guests"], selectedIndex: viewModel.remoteCoOpPreferences.reservedGuestSlots, uiScale: uiScale, action: viewModel.setRemoteCoOpReservedGuestSlots)
                    SettingsDivider(uiScale: uiScale)
                    SettingsOptionRow(title: "Transport", subtitle: viewModel.remoteCoOpPreferences.transportMode.description, options: OPNRemoteCoOpTransportMode.allCases.map(\.label), selectedIndex: selectedRemoteCoOpTransportModeIndex, uiScale: uiScale, action: viewModel.setRemoteCoOpTransportModeIndex)
                    SettingsDivider(uiScale: uiScale)
                    SettingsOptionRow(title: "Guest Quality", subtitle: "Caps the outbound Remote Co-Op stream sent to guests.", options: OPNRemoteCoOpQualityPreset.allCases.map(\.label), selectedIndex: selectedRemoteCoOpQualityPresetIndex, uiScale: uiScale, action: viewModel.setRemoteCoOpQualityPresetIndex)
                    SettingsDivider(uiScale: uiScale)
                    SettingsOptionRow(title: "Latency Mode", subtitle: viewModel.remoteCoOpPreferences.latencyMode.description, options: OPNRemoteCoOpLatencyMode.allCases.map(\.label), selectedIndex: selectedRemoteCoOpLatencyModeIndex, uiScale: uiScale, action: viewModel.setRemoteCoOpLatencyModeIndex)
                    SettingsDivider(uiScale: uiScale)
                    SettingsToggleRow(title: "Require Host Approval", subtitle: "Guests can join the room, but input remains disabled until the host approves them.", isOn: viewModel.remoteCoOpPreferences.requireHostApproval, uiScale: uiScale, action: viewModel.setRemoteCoOpRequireHostApproval)
                    SettingsDivider(uiScale: uiScale)
                    SettingsToggleRow(title: "Hide Guest Invite Details", subtitle: "Share opaque invites that do not reveal the game title or app ID to guests.", isOn: viewModel.remoteCoOpPreferences.hideGuestInviteDetails, uiScale: uiScale, action: viewModel.setRemoteCoOpHideGuestInviteDetails)
                }
            }

            SettingsCard(title: "Recording", uiScale: uiScale) {
                SettingsSliderRow(title: "Video Bitrate", valueText: recordingVideoBitrateText, value: Double(viewModel.streamProfile.recordingVideoBitrateMbps), range: 0...200, step: 1, uiScale: uiScale, action: viewModel.setRecordingVideoBitrateMbps)
                SettingsDivider(uiScale: uiScale)
                SettingsSliderRow(title: "Audio Bitrate", valueText: "\(viewModel.streamProfile.recordingAudioBitrateKbps) Kbps", value: Double(viewModel.streamProfile.recordingAudioBitrateKbps), range: 64...320, step: 16, uiScale: uiScale, action: viewModel.setRecordingAudioBitrateKbps)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Record Enhanced Video", subtitle: "Capture the enhanced/upscaled stream frame when available, with native decoded frames as fallback.", isOn: viewModel.streamProfile.recordingEnhancedVideoEnabled, uiScale: uiScale, action: viewModel.setRecordingEnhancedVideoEnabled)
            }

            SettingsCard(title: "Audio", uiScale: uiScale) {
                SettingsSliderRow(title: "Game Volume", valueText: percentText(viewModel.streamProfile.gameVolume), value: viewModel.streamProfile.gameVolume, range: 0...1, step: 0.01, uiScale: uiScale, action: viewModel.setGameVolume)
                SettingsDivider(uiScale: uiScale)
                SettingsSliderRow(title: "Microphone Volume", valueText: percentText(viewModel.streamProfile.microphoneVolume), value: viewModel.streamProfile.microphoneVolume, range: 0...1, step: 0.01, uiScale: uiScale, action: viewModel.setMicrophoneVolume)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Microphone Mode", subtitle: "Controls how voice input is sent to the stream.", options: OPNStreamPreferences.microphoneModeOptions.map(\.label), selectedIndex: selectedMicrophoneModeIndex, uiScale: uiScale, action: { viewModel.setMicrophoneMode(OPNStreamPreferences.microphoneModeOptions[$0].value) })
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Microphone Device", subtitle: "Current input device for MacForce Now streams.", options: viewModel.microphoneDeviceOptions.map(\.label), selectedIndex: selectedMicrophoneDeviceIndex, uiScale: uiScale, action: { viewModel.setMicrophoneDeviceId(viewModel.microphoneDeviceOptions[$0].uniqueId) })
            }

            SettingsCard(title: "Profile Maintenance", uiScale: uiScale) {
                HStack(alignment: .center, spacing: 16 * uiScale) {
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 4 * uiScale, height: 48 * uiScale)
                    VStack(alignment: .leading, spacing: 5 * uiScale) {
                        Text("Restore default streaming settings")
                            .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Resets resolution, FPS, codec, bitrate, color precision, latency, HDR, L4S, input, audio, and enhancement options.")
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.56))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12 * uiScale)
                    SettingsActionButton(title: "RESTORE DEFAULTS", minimumWidth: 150 * uiScale, uiScale: uiScale) { viewModel.restoreStreamingProfileDefaults() }
                }
                .padding(12 * uiScale)
                .background(SettingsVendorLayout.row)
                .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
            }
        }
    }

    private var selectedMicrophoneModeIndex: Int {
        OPNStreamPreferences.microphoneModeOptions.firstIndex { $0.value == viewModel.streamProfile.microphoneMode } ?? 0
    }

    private var selectedMicrophoneDeviceIndex: Int {
        viewModel.microphoneDeviceOptions.firstIndex { $0.uniqueId == viewModel.streamProfile.microphoneDeviceId } ?? 0
    }

    private var selectedRemoteCoOpTransportModeIndex: Int {
        OPNRemoteCoOpTransportMode.allCases.firstIndex(of: viewModel.remoteCoOpPreferences.transportMode) ?? 0
    }

    private var selectedRemoteCoOpQualityPresetIndex: Int {
        OPNRemoteCoOpQualityPreset.allCases.firstIndex(of: viewModel.remoteCoOpPreferences.qualityPreset) ?? 0
    }

    private var selectedRemoteCoOpLatencyModeIndex: Int {
        OPNRemoteCoOpLatencyMode.allCases.firstIndex(of: viewModel.remoteCoOpPreferences.latencyMode) ?? 0
    }

    private var streamingProfileMode: String {
        viewModel.streamProfile.allowsStreamingCustomization ? "Custom" : "\(viewModel.streamProfile.streamingQualityProfileOption.label) preset"
    }

    private var lockedProfileSubtitle: String {
        "Managed by the \(viewModel.streamProfile.streamingQualityProfileOption.label) quality profile. Select Custom to edit."
    }

    private var estimatedDataUsage: String {
        let gbPerHour = Double(viewModel.streamProfile.maxBitrateMbps) * 0.45
        return String(format: "Up to %.1f GB per hour at %d Mbps", gbPerHour, viewModel.streamProfile.maxBitrateMbps)
    }

    private var recordingVideoBitrateText: String {
        viewModel.streamProfile.recordingVideoBitrateMbps == 0 ? "Auto" : "\(viewModel.streamProfile.recordingVideoBitrateMbps) Mbps"
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct GameplayProfileOverview: View {
    let mode: String
    let resolution: String
    let frameRate: String
    let codec: String
    let bitrate: String
    let colorPrecision: String
    let dataUsage: String
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * uiScale) {
            HStack(alignment: .center, spacing: 14 * uiScale) {
                VStack(alignment: .leading, spacing: 6 * uiScale) {
                    Text("Active streaming profile")
                        .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                        .foregroundStyle(.white)
                    Text("These values are sent to MacForce Now when a new stream starts.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer(minLength: 0)
                SettingsStatusPill(title: "MODE", value: mode, positive: mode != "Balanced defaults", uiScale: uiScale)
            }

            SettingsFlowLayout(spacing: 10 * uiScale) {
                GameplayProfileMetricTile(label: "Resolution", value: resolution, emphasized: true, uiScale: uiScale)
                GameplayProfileMetricTile(label: "Frame Rate", value: frameRate, emphasized: true, uiScale: uiScale)
                GameplayProfileMetricTile(label: "Codec", value: codec, uiScale: uiScale)
                GameplayProfileMetricTile(label: "Bitrate", value: bitrate, uiScale: uiScale)
                GameplayProfileMetricTile(label: "Color", value: colorPrecision, uiScale: uiScale)
                GameplayProfileMetricTile(label: "Data Usage", value: dataUsage, width: 260 * uiScale, uiScale: uiScale)
            }
        }
    }
}

private struct GameplayProfileMetricTile: View {
    let label: String
    let value: String
    var emphasized = false
    var width: CGFloat?
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 7 * uiScale) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 9 * uiScale, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.44))
            Text(value.isEmpty ? "-" : value)
                .font(.settingsNvidia(size: (emphasized ? 16 : 14) * uiScale, weight: .bold))
                .foregroundStyle(emphasized ? Color.openNowGreen : .white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 13 * uiScale)
        .padding(.vertical, 11 * uiScale)
        .frame(width: width ?? ((emphasized ? 180 : 154) * uiScale), height: 72 * uiScale, alignment: .leading)
        .background(Color.white.opacity(emphasized ? 0.065 : 0.045))
        .overlay { Rectangle().stroke(emphasized ? Color.openNowGreen.opacity(0.32) : Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct ServerLocationSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    private let regionColumns = [GridItem(.adaptive(minimum: 138, maximum: 220), spacing: 10)]

    var body: some View {
        let selectedOption = viewModel.settingsRegionOptions.first { $0.url == viewModel.selectedSettingsRegionUrl }
        SettingsCard(title: "Server Location", uiScale: uiScale) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5 * uiScale) {
                    Text("Cloudmatch Region")
                        .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Automatic chooses the best measured MacForce Now route.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer(minLength: 12 * uiScale)
                SettingsStatusPill(title: "ACTIVE", value: selectedRegionTitle(selectedOption), positive: true, uiScale: uiScale)
                SettingsActionButton(title: viewModel.isRefreshingSettingsRegions ? "PINGING" : "REFRESH", minimumWidth: 104 * uiScale, uiScale: uiScale) { viewModel.refreshSettingsRegions() }
                    .disabled(viewModel.isRefreshingSettingsRegions)
            }
            SettingsDivider(uiScale: uiScale)
            if !viewModel.unavailableSettingsRegionUrl.isEmpty {
                UnavailableRegionPrompt(regionUrl: viewModel.unavailableSettingsRegionUrl, keepAction: viewModel.keepUnavailableSettingsRegion, automaticAction: viewModel.switchUnavailableSettingsRegionToAutomatic, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
            }
            LazyVGrid(columns: regionColumns, alignment: .leading, spacing: 10 * uiScale) {
                ForEach(viewModel.settingsRegionOptions, id: \.url) { option in
                    SettingsRegionRow(option: option, selected: option.url == viewModel.selectedSettingsRegionUrl, uiScale: uiScale) {
                        viewModel.selectSettingsRegion(option.url)
                    }
                }
            }
        }
    }

    private func selectedRegionTitle(_ option: OPNStreamRegionOption?) -> String {
        guard let option else { return "Automatic" }
        return SettingsRegionName.shortName(for: option)
    }
}

private struct UnavailableRegionPrompt: View {
    let regionUrl: String
    let keepAction: () -> Void
    let automaticAction: () -> Void
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * uiScale) {
            HStack(alignment: .top, spacing: 10 * uiScale) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 4 * uiScale) {
                    Text("Selected Region Unavailable")
                        .font(.settingsNvidia(size: 13 * uiScale, weight: .bold))
                        .foregroundStyle(.white)
                    Text("CloudMatch no longer advertises the selected route. Keep it for one more launch attempt, or switch to Automatic.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                    Text(regionUrl)
                        .font(.system(size: 11 * uiScale, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12 * uiScale)
            }
            HStack(spacing: 10 * uiScale) {
                SettingsActionButton(title: "KEEP", tone: .secondary, minimumWidth: 82 * uiScale, uiScale: uiScale, action: keepAction)
                SettingsActionButton(title: "AUTOMATIC", minimumWidth: 112 * uiScale, uiScale: uiScale, action: automaticAction)
            }
        }
        .padding(14 * uiScale)
        .background(Color.orange.opacity(0.08))
        .overlay { Rectangle().stroke(Color.orange.opacity(0.22), lineWidth: 1) }
    }
}

private struct ResolutionUpscalingSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "MetalFX Upscaling", uiScale: uiScale) {
                SettingsToggleRow(title: "MetalFX Upscaling", subtitle: "Optimized for Apple Silicon. Falls back automatically when MetalFX is unavailable.", isOn: viewModel.streamProfile.upscalingMode == 3, uiScale: uiScale) { enabled in viewModel.setUpscalingModeIndex(enabled ? 1 : 0) }
                SettingsDivider(uiScale: uiScale)
                SettingsInfoRow(label: "Target", value: "Display", uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                SettingsSliderRow(title: "Clarity", valueText: "\(viewModel.streamProfile.upscalingSharpness)", value: Double(viewModel.streamProfile.upscalingSharpness), range: 0...15, uiScale: uiScale, action: viewModel.setUpscalingSharpness)
                SettingsDivider(uiScale: uiScale)
                SettingsSliderRow(title: "Noise Reduction", valueText: "\(viewModel.streamProfile.upscalingDenoise)", value: Double(viewModel.streamProfile.upscalingDenoise), range: 0...20, uiScale: uiScale, action: viewModel.setUpscalingDenoise)
            }

            SettingsCard(title: "Pillarbox", uiScale: uiScale) {
                SettingsOptionRow(title: "Pillarbox Fill", subtitle: "Repaints the black bars GeForce NOW bakes into 16:9-only titles on wider displays.", options: OPNPillarboxFillMode.pickerCases.map(\.label), selectedIndex: OPNPillarboxFillMode.pickerCases.firstIndex(of: viewModel.streamProfile.pillarboxFillMode) ?? 0, uiScale: uiScale, action: { index in viewModel.setPillarboxFillModeIndex(OPNPillarboxFillMode.pickerCases[index].rawValue) })
                if viewModel.streamProfile.pillarboxFillMode.usesDim {
                    SettingsDivider(uiScale: uiScale)
                    SettingsSliderRow(title: "Edge Dimming", valueText: "\(viewModel.streamProfile.pillarboxFillDim)%", value: Double(viewModel.streamProfile.pillarboxFillDim), range: 0...100, uiScale: uiScale, action: viewModel.setPillarboxFillDim)
                }
            }

            SettingsCard(title: "Image Enhancement", uiScale: uiScale) {
                SettingsOptionRow(title: "Prefilter Mode", subtitle: "Applies GFN-style prefiltering before presentation.", options: OPNStreamPreferences.prefilterModeOptions.map(\.label), selectedIndex: viewModel.streamProfile.prefilterModeIndex, uiScale: uiScale, action: viewModel.setPrefilterModeIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsSliderRow(title: "Prefilter Sharpness", valueText: "\(viewModel.streamProfile.prefilterSharpness)", value: Double(viewModel.streamProfile.prefilterSharpness), range: 0...10, uiScale: uiScale, action: viewModel.setPrefilterSharpness)
                SettingsDivider(uiScale: uiScale)
                SettingsSliderRow(title: "Prefilter Denoise", valueText: "\(viewModel.streamProfile.prefilterDenoise)", value: Double(viewModel.streamProfile.prefilterDenoise), range: 0...10, uiScale: uiScale, action: viewModel.setPrefilterDenoise)
            }
        }
    }
}

private struct SystemSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @State private var revealSensitive = false
    @State private var copiedKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Readiness", uiScale: uiScale) {
                HStack(alignment: .top, spacing: 18 * uiScale) {
                    VStack(alignment: .leading, spacing: 10 * uiScale) {
                        Text(systemSummaryTitle)
                            .font(.settingsNvidia(size: 22 * uiScale, weight: .bold))
                            .foregroundStyle(.white)
                        Text(systemSummaryDetail)
                            .font(.settingsNvidia(size: 13 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8 * uiScale) {
                            AboutStatusPill(title: "Display", value: displaySummary, uiScale: uiScale)
                            AboutStatusPill(title: "Decode", value: preferredDecoder, uiScale: uiScale)
                            AboutStatusPill(title: "Route", value: route.summary, uiScale: uiScale)
                        }
                    }
                    Spacer(minLength: 0)
                    SystemHealthBadge(title: systemHealthTitle, subtitle: systemHealthSubtitle, positive: systemHealthPositive, uiScale: uiScale)
                }
            }

            SettingsCard(title: "Display", uiScale: uiScale) {
                SettingsFlowLayout(spacing: 10 * uiScale) {
                    SettingsStatisticTile(label: "Resolution", value: displaySummary, emphasized: true, uiScale: uiScale)
                    SettingsStatisticTile(label: "Refresh", value: refreshRateText, uiScale: uiScale)
                    SettingsStatisticTile(label: "DPI", value: dpiText, uiScale: uiScale)
                    SettingsStatisticTile(label: "HDR", value: viewModel.streamCapabilities.hdrDisplaySupported ? "Ready" : "Unavailable", uiScale: uiScale)
                }
            }

            SettingsCard(title: "Video Decode", uiScale: uiScale) {
                VStack(spacing: 10 * uiScale) {
                    SystemCapabilityRow(title: "H.264", subtitle: "Baseline stream compatibility", value: viewModel.streamCapabilities.h264HardwareDecodeSupported ? "Hardware" : "Software", positive: viewModel.streamCapabilities.h264HardwareDecodeSupported, uiScale: uiScale)
                    SystemCapabilityRow(title: "HEVC", subtitle: "Efficient high-quality streaming", value: viewModel.streamCapabilities.h265HardwareDecodeSupported ? "Supported" : "Unavailable", positive: viewModel.streamCapabilities.h265HardwareDecodeSupported, uiScale: uiScale)
                    SystemCapabilityRow(title: "AV1", subtitle: "Next-generation low-bitrate streaming", value: viewModel.streamCapabilities.av1HardwareDecodeSupported ? "Supported" : "Unavailable", positive: viewModel.streamCapabilities.av1HardwareDecodeSupported, uiScale: uiScale)
                }
            }

            SettingsCard(title: "Device & Route", uiScale: uiScale) {
                HStack(alignment: .center, spacing: 12 * uiScale) {
                    VStack(alignment: .leading, spacing: 4 * uiScale) {
                        Text("Identifiers and endpoint paths are masked by default.")
                            .font(.settingsNvidia(size: 14 * uiScale, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Reveal only when collecting support information locally.")
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                    Spacer()
                    SettingsRevealButton(revealed: revealSensitive, uiScale: uiScale) { revealSensitive.toggle() }
                }
                SettingsDivider(uiScale: uiScale)
                AboutDetailRow(label: "Device ID", value: displayedDeviceId, copyValue: viewModel.session.deviceId, copiedKey: $copiedKey, copyDisabled: viewModel.session.deviceId.isEmpty, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                AboutDetailRow(label: "Current Region", value: route.displayValue, copyValue: route.copyValue, copiedKey: $copiedKey, uiScale: uiScale)
            }
        }
    }

    private var displaySummary: String {
        guard viewModel.streamCapabilities.maxDisplayWidth > 0, viewModel.streamCapabilities.maxDisplayHeight > 0 else { return "Unknown" }
        return "\(viewModel.streamCapabilities.maxDisplayWidth) x \(viewModel.streamCapabilities.maxDisplayHeight)"
    }

    private var refreshRateText: String {
        viewModel.streamCapabilities.maxDisplayRefreshRate > 0 ? "\(viewModel.streamCapabilities.maxDisplayRefreshRate) Hz" : "Unknown"
    }

    private var dpiText: String {
        viewModel.streamCapabilities.displayDpi > 0 ? "\(viewModel.streamCapabilities.displayDpi)" : "Unknown"
    }

    private var preferredDecoder: String {
        if viewModel.streamCapabilities.av1HardwareDecodeSupported { return "AV1" }
        if viewModel.streamCapabilities.h265HardwareDecodeSupported { return "HEVC" }
        if viewModel.streamCapabilities.h264HardwareDecodeSupported { return "H.264" }
        return "Software"
    }

    private var hardwareDecodeCount: Int {
        [viewModel.streamCapabilities.h264HardwareDecodeSupported, viewModel.streamCapabilities.h265HardwareDecodeSupported, viewModel.streamCapabilities.av1HardwareDecodeSupported].filter { $0 }.count
    }

    private var systemHealthPositive: Bool {
        viewModel.streamCapabilities.h264HardwareDecodeSupported && displaySummary != "Unknown"
    }

    private var systemHealthTitle: String {
        systemHealthPositive ? "READY" : "LIMITED"
    }

    private var systemHealthSubtitle: String {
        systemHealthPositive ? "Hardware path available" : "Review decoder support"
    }

    private var systemSummaryTitle: String {
        systemHealthPositive ? "Streaming hardware looks ready" : "Streaming support is partially available"
    }

    private var systemSummaryDetail: String {
        "Detected \(displaySummary) at \(refreshRateText), \(hardwareDecodeCount) hardware decoder\(hardwareDecodeCount == 1 ? "" : "s"), and \(viewModel.streamCapabilities.hdrDisplaySupported ? "HDR-capable" : "SDR") presentation."
    }

    private var route: SettingsRouteSnapshot {
        SettingsRouteSnapshot(regionUrl: viewModel.selectedSettingsRegionUrl, revealSensitive: revealSensitive)
    }

    private var displayedDeviceId: String {
        revealSensitive ? viewModel.session.deviceId : SettingsFormat.maskedIdentifier(viewModel.session.deviceId)
    }
}

private struct SystemHealthBadge: View {
    let title: String
    let subtitle: String
    let positive: Bool
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * uiScale) {
            Text(title)
                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(positive ? .black : .white.opacity(0.88))
                .tracking(1.1)
            Text(subtitle)
                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(positive ? .black.opacity(0.74) : .white.opacity(0.54))
                .lineLimit(2)
        }
        .padding(.horizontal, 14 * uiScale)
        .frame(width: 172 * uiScale, height: 64 * uiScale, alignment: .leading)
        .background(positive ? Color.openNowGreen : Color.white.opacity(0.07))
        .overlay { Rectangle().stroke(positive ? Color.openNowGreen : Color.white.opacity(0.13), lineWidth: 1) }
    }
}

private struct SystemCapabilityRow: View {
    let title: String
    let subtitle: String
    let value: String
    let positive: Bool
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 12 * uiScale) {
            Rectangle()
                .fill(positive ? Color.openNowGreen : Color.white.opacity(0.22))
                .frame(width: 4 * uiScale, height: 42 * uiScale)
            VStack(alignment: .leading, spacing: 4 * uiScale) {
                Text(title)
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.56))
            }
            Spacer(minLength: 0)
            Text(value.uppercased())
                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(positive ? Color.openNowGreen : .white.opacity(0.56))
                .tracking(0.8)
                .padding(.horizontal, 10 * uiScale)
                .frame(height: 28 * uiScale)
                .background(Color.white.opacity(positive ? 0.07 : 0.04))
                .overlay { Rectangle().stroke(positive ? Color.openNowGreen.opacity(0.38) : Color.white.opacity(0.08), lineWidth: 1) }
        }
        .padding(12 * uiScale)
        .background(Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct AboutSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @State private var copiedKey = ""
    @State private var diagnosticsState = AboutDiagnosticsState.ready
    @State private var showingDiagnosticsUploadConfirmation = false
    @AppStorage(MacForceNowUpdatePreferences.automaticUpdateChecksEnabledKey) private var automaticUpdateChecksEnabled = MacForceNowUpdatePreferences.defaultAutomaticUpdateChecksEnabled
    @State private var telemetryDisabled = OPNSentry.isTelemetryDisabled()

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Product", uiScale: uiScale) {
                HStack(alignment: .top, spacing: 22 * uiScale) {
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.22))
                            .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.72), lineWidth: 1) }
                        VendorResourceImage(name: "nv-gfn-logo_v3", fileExtension: "png")
                            .scaledToFit()
                            .padding(.horizontal, 14 * uiScale)
                    }
                    .frame(width: 180 * uiScale, height: 88 * uiScale)

                    VStack(alignment: .leading, spacing: 12 * uiScale) {
                        HStack(alignment: .firstTextBaseline, spacing: 10 * uiScale) {
                            Text(SettingsAppMetadata.displayName)
                                .font(.settingsNvidia(size: 25 * uiScale, weight: .bold))
                                .foregroundStyle(.white)
                            Text("UNOFFICIAL CLIENT SHELL")
                                .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                                .foregroundStyle(.black)
                                .tracking(0.8)
                                .padding(.horizontal, 8 * uiScale)
                                .frame(height: 20 * uiScale)
                                .background(Color.openNowGreen)
                        }
                        Text("A macOS runtime for launching and streaming MacForce Now sessions with local catalog, account, and diagnostics surfaces.")
                            .font(.settingsNvidia(size: 13 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.66))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8 * uiScale) {
                            AboutStatusPill(title: "Stream", value: "WebRTC", uiScale: uiScale)
                            AboutStatusPill(title: "Route", value: route.summary, uiScale: uiScale)
                            AboutStatusPill(title: "Telemetry", value: telemetryDisabled ? "Off" : "On", uiScale: uiScale)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            SettingsCard(title: "Runtime", uiScale: uiScale) {
                AboutDetailRow(label: "Version", value: SettingsAppMetadata.version, copyValue: SettingsAppMetadata.version, copiedKey: $copiedKey, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                AboutDetailRow(label: "Build", value: SettingsAppMetadata.build, copyValue: SettingsAppMetadata.build, copiedKey: $copiedKey, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                AboutDetailRow(label: "Bundle", value: bundleIdentifier, copyValue: bundleIdentifier, copiedKey: $copiedKey, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                AboutDetailRow(label: "macOS", value: operatingSystemVersion, copyValue: operatingSystemVersion, copiedKey: $copiedKey, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Automatic Update Checks", subtitle: automaticUpdateChecksSubtitle, isOn: automaticUpdateChecksEnabled, uiScale: uiScale) { enabled in
                    MacForceNowAppDelegate.setAutomaticApplicationUpdateChecksEnabled(enabled)
                }
                SettingsDivider(uiScale: uiScale)
                HStack(spacing: 10 * uiScale) {
                    SettingsActionButton(title: "CHECK FOR UPDATES", uiScale: uiScale) {
                        MacForceNowAppDelegate.requestApplicationUpdateCheck()
                    }
                    Text("Checks GitHub releases and installs a newer signed MacForce Now build when available.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                }
            }

            SettingsCard(title: "Cache", uiScale: uiScale) {
                AboutDetailRow(label: "Catalog Images", value: viewModel.catalogImageCacheSummary, copyValue: viewModel.catalogImageCacheSummary, copiedKey: $copiedKey, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                HStack(spacing: 10 * uiScale) {
                    SettingsActionButton(title: "CLEAR IMAGE CACHE", uiScale: uiScale) {
                        viewModel.clearCatalogImageCache()
                    }
                    Text("Removes cached catalog artwork from disk and memory. Images will download again as needed.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                }
            }

            SettingsCard(title: "Privacy", uiScale: uiScale) {
                SettingsToggleRow(title: "Disable Telemetry", subtitle: "Stops Sentry, trace headers, metrics, and automatic diagnostics logging.", isOn: telemetryDisabled, uiScale: uiScale, action: setTelemetryDisabled)
            }

            SettingsCard(title: "Support Diagnostics", uiScale: uiScale) {
                VStack(alignment: .leading, spacing: 10 * uiScale) {
                    HStack(spacing: 10 * uiScale) {
                        SettingsActionButton(title: diagnosticsButtonTitle, uiScale: uiScale) {
                            showingDiagnosticsUploadConfirmation = true
                        }
                        .disabled(diagnosticsState.isWorking)
                        Text("Uploads the recent sanitized current-run log, then copies diagnostics with the link.")
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.54))
                    }
                    Text(diagnosticsState.message)
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(diagnosticsState.isError ? Color(red: 1, green: 0.54, blue: 0.50) : .white.opacity(0.62))
                }
            }
        }
            .disabled(showingDiagnosticsUploadConfirmation)

            if showingDiagnosticsUploadConfirmation {
                DiagnosticsUploadConfirmationDialog(
                    cancel: { showingDiagnosticsUploadConfirmation = false },
                    upload: {
                        showingDiagnosticsUploadConfirmation = false
                        generateUploadedDiagnostics()
                    },
                    uiScale: uiScale
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.16), value: showingDiagnosticsUploadConfirmation)
        .onAppear {
            viewModel.refreshCatalogImageCacheSummary()
            telemetryDisabled = OPNSentry.isTelemetryDisabled()
        }
    }

    private var account: SettingsAccountSnapshot {
        SettingsAccountSnapshot(viewModel: viewModel)
    }

    private var route: SettingsRouteSnapshot {
        SettingsRouteSnapshot(regionUrl: viewModel.selectedSettingsRegionUrl, revealSensitive: false)
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "Unknown"
    }

    private var operatingSystemVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    private var automaticUpdateChecksSubtitle: String {
        if MacForceNowUpdatePreferences.updateChecksAreSuspendedForDebugging {
            return "Paused while running a debug build or attached debugger. Manual checks remain available."
        }
        if automaticUpdateChecksEnabled {
            return "Checks GitHub releases on launch and hourly while MacForce Now is running."
        }
        return "MacForce Now will not check for new releases automatically. Manual checks remain available."
    }

    private var diagnosticsText: String {
        diagnosticsText(logURL: nil, uploadError: "", inlineLog: "")
    }

    private func diagnosticsText(logURL: URL?, uploadError: String, inlineLog: String) -> String {
        var lines = [
            "MacForce Now Mac Diagnostics",
            "Version: \(SettingsAppMetadata.versionWithBuild)",
            "Bundle: \(bundleIdentifier)",
            "macOS: \(operatingSystemVersion)",
            "Account: \(account.displayName)",
            "Membership: \(account.membershipTier)",
            "User ID: \(SettingsFormat.maskedIdentifier(account.userId))",
            "Streaming: WebRTC",
            "Cloudmatch: \(route.summary)",
            "Logs: \(logURL?.absoluteString ?? "Not uploaded")"
        ]
        if !uploadError.isEmpty {
            lines.append("Upload Error: \(uploadError)")
        }
        if !inlineLog.isEmpty {
            lines.append(contentsOf: ["", "Inline Logs:", inlineLog])
        }
        return lines.joined(separator: "\n")
    }

    private var diagnosticsButtonTitle: String {
        switch diagnosticsState {
        case .ready, .failed: return "GENERATE DIAGNOSTICS"
        case .preparing, .readingLog, .uploading, .copying: return "WORKING"
        case .copied: return "COPIED"
        }
    }

    private func setTelemetryDisabled(_ disabled: Bool) {
        telemetryDisabled = disabled
        OPNSentry.setTelemetryDisabled(disabled)
    }

    private func generateUploadedDiagnostics() {
        guard !diagnosticsState.isWorking else { return }
        Task { @MainActor in
            diagnosticsState = .preparing
            OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "Diagnostics", message: "Preparing user-requested diagnostics upload"))
            diagnosticsState = .readingLog
            let logText = OPNSentry.diagnosticsLogForUpload()
            diagnosticsState = .uploading
            do {
                let logURL = try await OPNSentry.uploadDiagnosticsLog(logText)
                diagnosticsState = .copying
                copy(diagnosticsText(logURL: logURL, uploadError: "", inlineLog: ""), key: "diagnostics")
                diagnosticsState = .copied(logURL.absoluteString)
                OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "Diagnostics", message: "Uploaded sanitized diagnostics log url=\(logURL.absoluteString)"))
            } catch {
                let message = error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
                diagnosticsState = .copying
                copy(diagnosticsText(logURL: nil, uploadError: message, inlineLog: logText), key: "diagnostics")
                diagnosticsState = .failed(message)
                OPNSentry.logErrorMessage(OPNSentry.formattedLogMessage(level: "error", area: "Diagnostics", message: "Diagnostics upload failed; copied local diagnostics with inline logs error=\(message)"))
            }
        }
    }

    private func copy(_ value: String, key: String) {
        guard !value.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        copiedKey = key
    }

}

private struct DiagnosticsUploadConfirmationDialog: View {
    let cancel: () -> Void
    let upload: () -> Void
    let uiScale: CGFloat

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .onTapGesture(perform: cancel)

            VStack(alignment: .leading, spacing: 18 * uiScale) {
                HStack(alignment: .top, spacing: 14 * uiScale) {
                    ZStack {
                        Rectangle()
                            .fill(Color.openNowGreen.opacity(0.16))
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.settingsNvidia(size: 18 * uiScale, weight: .bold))
                            .foregroundStyle(Color.openNowGreen)
                    }
                    .frame(width: 44 * uiScale, height: 44 * uiScale)
                    .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.42), lineWidth: 1) }

                    VStack(alignment: .leading, spacing: 7 * uiScale) {
                        Text("Upload diagnostics logs?")
                            .font(.settingsNvidia(size: 19 * uiScale, weight: .bold))
                            .foregroundStyle(.white)
                        Text("MacForce Now will upload the recent sanitized current-run log to paste.c-net.org and copy a diagnostics summary with the public link.")
                            .font(.settingsNvidia(size: 13 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .top, spacing: 10 * uiScale) {
                    Rectangle()
                        .fill(Color.openNowGreen)
                        .frame(width: 4 * uiScale, height: 42 * uiScale)
                    Text("IP addresses and location fields are redacted before upload. Only generate this when preparing support diagnostics.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12 * uiScale)
                .background(Color.white.opacity(0.045))
                .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }

                HStack(spacing: 10 * uiScale) {
                    Spacer(minLength: 0)
                    SettingsDialogButton(title: "CANCEL", tone: .secondary, uiScale: uiScale, action: cancel)
                    SettingsDialogButton(title: "UPLOAD LOGS", tone: .primary, uiScale: uiScale, action: upload)
                }
            }
            .padding(22 * uiScale)
            .frame(width: 430 * uiScale, alignment: .leading)
            .background(Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255))
            .overlay { Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1) }
            .shadow(color: .black.opacity(0.62), radius: 34 * uiScale, x: 0, y: 18 * uiScale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SettingsDialogButton: View {
    enum Tone {
        case primary
        case secondary
    }

    let title: String
    let tone: Tone
    let uiScale: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(tone == .primary ? .black : .white.opacity(0.82))
                .tracking(0.8)
                .padding(.horizontal, 14 * uiScale)
                .frame(minWidth: 104 * uiScale)
                .frame(height: 34 * uiScale)
                .background(backgroundColor)
                .overlay { Rectangle().stroke(strokeColor, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        switch tone {
        case .primary: return Color.openNowGreen.opacity(isHovering ? 0.88 : 1)
        case .secondary: return Color.white.opacity(isHovering ? 0.10 : 0.06)
        }
    }

    private var strokeColor: Color {
        switch tone {
        case .primary: return Color.openNowGreen
        case .secondary: return Color.white.opacity(0.14)
        }
    }
}

private enum AboutDiagnosticsState: Equatable {
    case ready
    case preparing
    case readingLog
    case uploading
    case copying
    case copied(String)
    case failed(String)

    var message: String {
        switch self {
        case .ready: return "Ready to generate diagnostics. Confirmation is required before logs are uploaded."
        case .preparing: return "Preparing diagnostics metadata..."
        case .readingLog: return "Reading sanitized current-run log..."
        case .uploading: return "Uploading sanitized logs to paste.c-net.org..."
        case .copying: return "Copying diagnostics to clipboard..."
        case .copied(let url): return "Diagnostics copied. Uploaded log: \(url)"
        case .failed(let reason): return "Upload failed, but local diagnostics and inline logs were copied: \(reason)"
        }
    }

    var isWorking: Bool {
        switch self {
        case .preparing, .readingLog, .uploading, .copying: return true
        case .ready, .copied, .failed: return false
        }
    }

    var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}

private struct AboutStatusPill: View {
    let title: String
    let value: String
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 6 * uiScale) {
            Text(title.uppercased())
                .font(.settingsNvidia(size: 9 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.44))
                .tracking(0.8)
            Text(value.isEmpty ? "Unknown" : value)
                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
        }
        .padding(.horizontal, 10 * uiScale)
        .frame(height: 28 * uiScale)
        .background(Color.white.opacity(0.065))
        .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
    }
}

private struct AboutDetailRow: View {
    let label: String
    let value: String
    let copyValue: String
    @Binding var copiedKey: String
    var copyDisabled = false
    let uiScale: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.44))
                .tracking(0.5)
                .frame(width: 150 * uiScale, alignment: .leading)
            Text(value.isEmpty ? "Unavailable" : value)
                .font(.settingsNvidia(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button { copy(copyValue) } label: {
                Text(copiedKey == label ? "COPIED" : "COPY")
                    .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                    .foregroundStyle(copyDisabled ? .white.opacity(0.28) : .white.opacity(0.74))
                    .tracking(0.7)
                    .padding(.horizontal, 10 * uiScale)
                    .frame(height: 26 * uiScale)
                    .background(Color.white.opacity(copyDisabled ? 0.03 : 0.06))
                    .overlay { Rectangle().stroke(Color.white.opacity(copyDisabled ? 0.05 : 0.12), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(copyDisabled)
        }
    }

    private func copy(_ value: String) {
        guard !value.isEmpty, !copyDisabled else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        copiedKey = label
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let uiScale: CGFloat
    private let content: Content

    init(title: String, uiScale: CGFloat, @ViewBuilder content: () -> Content) {
        self.title = title
        self.uiScale = uiScale
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10 * uiScale) {
                Rectangle()
                    .fill(Color.openNowGreen)
                    .frame(width: 4 * uiScale, height: 18 * uiScale)
                Text(title.uppercased())
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.68))
                    .tracking(1.1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18 * uiScale)
            .padding(.top, 17 * uiScale)
            .padding(.bottom, 12 * uiScale)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 20 * uiScale)
            .padding(.bottom, 20 * uiScale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topLeading) {
                SettingsVendorLayout.card
                LinearGradient(colors: [Color.white.opacity(0.035), .clear], startPoint: .top, endPoint: .center)
                Rectangle()
                    .fill(Color.openNowGreen.opacity(0.10))
                    .frame(width: 1)
            }
        )
        .overlay { Rectangle().stroke(Color.white.opacity(0.115), lineWidth: 1) }
        .shadow(color: .black.opacity(0.26), radius: 16 * uiScale, y: 8 * uiScale)
    }
}

private struct SettingsDivider: View {
    let uiScale: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.vertical, 14 * uiScale)
    }
}

private struct SettingsInfoRow: View {
    let label: String
    let value: String
    let uiScale: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16 * uiScale) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.44))
                .frame(width: 150 * uiScale, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .font(.settingsNvidia(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

private struct SettingsOptionRow: View {
    let title: String
    let subtitle: String
    let options: [String]
    let selectedIndex: Int
    var enabled: [Bool] = []
    var isLocked = false
    let uiScale: CGFloat
    let action: (Int) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text(title)
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white.opacity(isLocked ? 0.58 : 1))
                Text(subtitle)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(isLocked ? 0.38 : 0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250 * uiScale, alignment: .leading)
            SettingsFlowLayout(spacing: 8 * uiScale) {
                ForEach(options.indices, id: \.self) { index in
                    let optionEnabled = !isLocked && (enabled.indices.contains(index) ? enabled[index] : true)
                    Button { action(index) } label: {
                        Text(options[index])
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                            .foregroundStyle(index == selectedIndex && !isLocked ? .black : .white.opacity(optionEnabled ? 0.82 : 0.34))
                            .padding(.horizontal, 12 * uiScale)
                            .frame(height: 32 * uiScale)
                            .background(index == selectedIndex ? Color.openNowGreen.opacity(isLocked ? 0.32 : 1) : Color.white.opacity(optionEnabled ? 0.07 : 0.035))
                            .overlay { Rectangle().stroke(index == selectedIndex ? Color.openNowGreen.opacity(isLocked ? 0.42 : 1) : Color.white.opacity(0.12), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .disabled(!optionEnabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    let isOn: Bool
    var isLocked = false
    let uiScale: CGFloat
    let action: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text(title)
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white.opacity(isLocked ? 0.58 : 1))
                Text(subtitle)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(isLocked ? 0.38 : 0.58))
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { action($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(isLocked)
                .opacity(isLocked ? 0.45 : 1)
        }
    }
}

private struct SettingsTextFieldRow: View {
    let title: String
    let subtitle: String
    let text: String
    let placeholder: String
    let uiScale: CGFloat
    let action: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text(title)
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250 * uiScale, alignment: .leading)
            TextField(placeholder, text: Binding(get: { draft }, set: { updateDraft($0) }))
                .textFieldStyle(.plain)
                .font(.settingsNvidia(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12 * uiScale)
                .frame(height: 36 * uiScale)
                .background(Color.white.opacity(0.07))
                .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
                .onAppear { draft = text }
                .onChange(of: text) { _, value in
                    guard value != draft else { return }
                    draft = value
                }
        }
    }

    private func updateDraft(_ value: String) {
        draft = value
        action(value)
    }
}

private struct SettingsSecureTextFieldRow: View {
    let title: String
    let subtitle: String
    @Binding var text: String
    let placeholder: String
    let uiScale: CGFloat
    let action: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text(title)
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250 * uiScale, alignment: .leading)
            SecureField(placeholder, text: Binding(get: { draft }, set: { updateDraft($0) }))
                .textFieldStyle(.plain)
                .font(.settingsNvidia(size: 13 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12 * uiScale)
                .frame(height: 36 * uiScale)
                .background(Color.white.opacity(0.07))
                .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
                .onAppear { draft = text }
                .onChange(of: text) { _, value in
                    guard value != draft else { return }
                    draft = value
                }
        }
    }

    private func updateDraft(_ value: String) {
        draft = value
        action(value)
    }
}

private struct SettingsSliderRow: View {
    let title: String
    let valueText: String
    let value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    var isLocked = false
    let uiScale: CGFloat
    let action: @MainActor @Sendable (Double) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text(title)
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white.opacity(isLocked ? 0.58 : 1))
                Text(valueText)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                    .foregroundStyle(Color.openNowGreen.opacity(isLocked ? 0.48 : 1))
            }
            .frame(width: 250 * uiScale, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { action($0) }), in: range, step: step)
                .tint(Color.openNowGreen)
                .disabled(isLocked)
                .opacity(isLocked ? 0.45 : 1)
        }
    }
}

private struct SettingsColorRow: View {
    let title: String
    let subtitle: String
    let hex: String
    let uiScale: CGFloat
    let action: (String) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text(title)
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250 * uiScale, alignment: .leading)
            ColorPicker("", selection: Binding(get: { Color(settingsHex: hex) }, set: { action($0.settingsHexString) }), supportsOpacity: false)
                .labelsHidden()
            Text(hex)
                .font(.system(size: 11 * uiScale, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
            Spacer(minLength: 0)
        }
    }
}

private struct SettingsActionButton: View {
    enum Tone {
        case primary
        case secondary
    }

    let title: String
    var tone: Tone = .primary
    var minimumWidth: CGFloat = 0
    let uiScale: CGFloat
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(foregroundColor)
                .tracking(0.8)
                .padding(.horizontal, 14 * uiScale)
                .frame(minWidth: minimumWidth)
                .frame(height: 32 * uiScale)
                .background(backgroundColor)
                .overlay { Rectangle().stroke(strokeColor, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        guard isEnabled else { return Color.white.opacity(0.045) }
        switch tone {
        case .primary: return Color.openNowGreen.opacity(isHovering ? 0.88 : 1)
        case .secondary: return Color.openNowGreen.opacity(isHovering ? 0.22 : 0.14)
        }
    }

    private var foregroundColor: Color {
        guard isEnabled else { return .white.opacity(0.32) }
        switch tone {
        case .primary: return .black
        case .secondary: return Color.openNowGreen
        }
    }

    private var strokeColor: Color {
        guard isEnabled else { return Color.white.opacity(0.08) }
        return tone == .primary ? Color.openNowGreen : Color.openNowGreen.opacity(0.34)
    }
}

private struct SettingsStatusPill: View {
    let title: String
    let value: String
    let positive: Bool
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 3 * uiScale) {
            Text(title.uppercased())
                .font(.settingsNvidia(size: 9 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
                .tracking(0.8)
            Text(value.isEmpty ? "-" : value)
                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(positive ? Color.openNowGreen : .white.opacity(0.66))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 10 * uiScale)
        .frame(minWidth: 94 * uiScale, alignment: .trailing)
        .frame(height: 40 * uiScale)
        .background(Color.white.opacity(positive ? 0.055 : 0.035))
        .overlay { Rectangle().stroke(positive ? Color.openNowGreen.opacity(0.24) : Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct SettingsRegionRow: View {
    let option: OPNStreamRegionOption
    let selected: Bool
    let uiScale: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8 * uiScale) {
                HStack(alignment: .top, spacing: 8 * uiScale) {
                    Text(SettingsRegionName.shortName(for: option))
                        .font(.settingsNvidia(size: 13 * uiScale, weight: .bold))
                        .foregroundStyle(selected ? .white : .white.opacity(0.90))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer(minLength: 6 * uiScale)
                    Circle()
                        .fill(selected ? Color.openNowGreen : Color.white.opacity(isHovering ? 0.34 : 0.22))
                        .frame(width: 8 * uiScale, height: 8 * uiScale)
                        .padding(.top, 4 * uiScale)
                }
                RegionLatencyBadge(latencyMs: option.latencyMs, selected: selected, uiScale: uiScale)
            }
            .frame(maxWidth: .infinity, minHeight: 56 * uiScale, alignment: .leading)
            .padding(.horizontal, 11 * uiScale)
            .padding(.vertical, 9 * uiScale)
            .background(selected ? Color.openNowGreen.opacity(0.13) : Color.white.opacity(isHovering ? 0.065 : 0.045))
            .overlay { Rectangle().stroke(selected ? Color.openNowGreen.opacity(0.74) : Color.white.opacity(isHovering ? 0.16 : 0.08), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private enum SettingsRegionName {
    static func shortName(for option: OPNStreamRegionOption) -> String {
        guard !option.automatic else { return "Auto" }
        let withoutParenthetical = option.name.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        let withoutPrefixes = withoutParenthetical
            .replacingOccurrences(of: "GeForce NOW", with: "")
            .replacingOccurrences(of: "NVIDIA", with: "")
            .replacingOccurrences(of: "Cloudmatch", with: "")
        let cleaned = withoutPrefixes.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? option.name : cleaned
    }
}

private struct RegionLatencyBadge: View {
    let latencyMs: Int
    let selected: Bool
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 7 * uiScale) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 6 * uiScale, height: 6 * uiScale)
            Text(latencyText)
                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(selected ? Color.openNowGreen : .white.opacity(0.74))
                .lineLimit(1)
        }
        .padding(.horizontal, 8 * uiScale)
        .frame(height: 24 * uiScale)
        .background(selected ? Color.black.opacity(0.20) : Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(selected ? Color.openNowGreen.opacity(0.30) : Color.white.opacity(0.08), lineWidth: 1) }
    }

    private var latencyText: String {
        latencyMs >= 0 ? "\(latencyMs) ms" : "Measuring"
    }

    private var indicatorColor: Color {
        guard latencyMs >= 0 else { return .white.opacity(0.36) }
        if latencyMs <= 40 { return Color.openNowGreen }
        if latencyMs <= 65 { return Color(red: 1.0, green: 0.77, blue: 0.24) }
        return Color(red: 1.0, green: 0.32, blue: 0.26)
    }
}

private struct SettingsMessageView: View {
    let message: String
    let systemImage: String
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 10 * uiScale) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.openNowGreen)
            Text(message)
                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
            Spacer()
        }
        .padding(12 * uiScale)
        .background(Color.white.opacity(0.07))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }
}

private struct SettingsFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Must never return a non-finite size (see FlowLayout in CatalogView.swift):
        // an .infinity proposal would otherwise propagate NaN into the layout graph
        // and livelock the main thread.
        let proposedWidth = proposal.width
        let width: CGFloat = (proposedWidth?.isFinite == true && proposedWidth! > 0) ? proposedWidth! : 320
        var size = CGSize(width: width, height: 0)
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if lineWidth + subviewSize.width > width, lineWidth > 0 {
                size.height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += subviewSize.width + spacing
            lineHeight = max(lineHeight, subviewSize.height)
        }
        size.height += lineHeight
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if x + subviewSize.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(subviewSize))
            x += subviewSize.width + spacing
            lineHeight = max(lineHeight, subviewSize.height)
        }
    }
}
