import AppKit
import Common
import CryptoKit
import OpenNOWDesignSystem
import OpenNOWTelemetry
import OpenNOWTwitch
import SwiftUI

private enum SettingsVendorLayout {
    static let surface = Color(red: 18 / 255, green: 19 / 255, blue: 18 / 255)
    static let sidebar = Color(red: 31 / 255, green: 32 / 255, blue: 31 / 255)
    static let card = Color(red: 26 / 255, green: 27 / 255, blue: 26 / 255)
    static let cardRaised = Color(red: 34 / 255, green: 35 / 255, blue: 34 / 255)
    static let row = Color.white.opacity(0.045)
}

private extension Font {
    static func settingsNvidia(size: CGFloat, weight: OpenNOWNVIDIAFont.Weight = .regular) -> Font {
        OpenNOWNVIDIAFont.font(size: size, weight: weight)
    }
}

private struct SettingsAccountSnapshot {
    let displayName: String
    let membershipTier: String
    let providerName: String
    let userId: String
    let authorizationState: String
    let authStatus: String
    let rememberSession: Bool

    init(viewModel: CatalogViewModel) {
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

    private static func membershipTier(viewModel: CatalogViewModel) -> String {
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
        ?? "OpenNOW Mac"
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(viewModel: viewModel)
            SettingsContent(viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsSurfaceBackground())
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

private struct SettingsSidebar: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SETTINGS")
                    .font(.settingsNvidia(size: 11, weight: .bold))
                    .foregroundStyle(Color.openNowGreen)
                    .tracking(1.5)
                Text("OpenNOW")
                    .font(.settingsNvidia(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)

            ForEach(CatalogSettingsPage.allCases) { page in
                Button { viewModel.selectedSettingsPage = page } label: {
                    HStack(spacing: 12) {
                        Rectangle()
                            .fill(viewModel.selectedSettingsPage == page ? Color.openNowGreen : .clear)
                            .frame(width: 4, height: 34)
                        Image(systemName: icon(for: page))
                            .font(.settingsNvidia(size: 13, weight: .bold))
                            .foregroundStyle(viewModel.selectedSettingsPage == page ? Color.openNowGreen : .white.opacity(0.52))
                            .frame(width: 18)
                        Text(page.title)
                            .font(.settingsNvidia(size: 14, weight: viewModel.selectedSettingsPage == page ? .bold : .medium))
                            .foregroundStyle(viewModel.selectedSettingsPage == page ? .white : .white.opacity(0.68))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 48)
                    .background(viewModel.selectedSettingsPage == page ? Color.white.opacity(0.065) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
            Button { viewModel.showGames() } label: {
                Text("BACK TO GAMES")
                    .font(.settingsNvidia(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.86))
                    .tracking(0.9)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Color.white.opacity(0.055))
                    .overlay { Rectangle().stroke(Color.white.opacity(0.13), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .frame(width: 256)
        .background(SettingsVendorLayout.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.black.opacity(0.38)).frame(width: 1) }
    }

    private func icon(for page: CatalogSettingsPage) -> String {
        switch page {
        case .account: return "person.crop.circle.fill"
        case .interface: return "gamecontroller.fill"
        case .connections: return "link"
        case .twitch: return "dot.radiowaves.left.and.right"
        case .gameplay: return "slider.horizontal.3"
        case .serverLocation: return "network"
        case .resolutionUpscaling: return "sparkles.tv.fill"
        case .system: return "desktopcomputer"
        case .about: return "info.circle.fill"
        }
    }
}

private struct SettingsContent: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsHeader(title: viewModel.selectedSettingsPage.title, subtitle: subtitle)
                if !viewModel.errorMessage.isEmpty {
                    SettingsMessageView(message: viewModel.errorMessage, systemImage: "exclamationmark.triangle.fill")
                }
                if !viewModel.actionMessage.isEmpty {
                    SettingsMessageView(message: viewModel.actionMessage, systemImage: "checkmark.circle.fill")
                }
                page
            }
            .padding(.horizontal, 52)
            .padding(.top, 38)
            .padding(.bottom, 54)
            .frame(maxWidth: 1220, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsSurfaceBackground())
    }

    @ViewBuilder private var page: some View {
        switch viewModel.selectedSettingsPage {
        case .account:
            AccountSettingsPage(viewModel: viewModel)
        case .interface:
            InterfaceSettingsPage(viewModel: viewModel)
        case .connections:
            ConnectionsSettingsPage(viewModel: viewModel)
        case .twitch:
            TwitchSettingsPage(viewModel: viewModel)
        case .gameplay:
            GameplaySettingsPage(viewModel: viewModel)
        case .serverLocation:
            ServerLocationSettingsPage(viewModel: viewModel)
        case .resolutionUpscaling:
            ResolutionUpscalingSettingsPage(viewModel: viewModel)
        case .system:
            SystemSettingsPage(viewModel: viewModel)
        case .about:
            AboutSettingsPage(viewModel: viewModel)
        }
    }

    private var subtitle: String {
        switch viewModel.selectedSettingsPage {
        case .account: return "Membership, profile, and current NVIDIA session details."
        case .interface: return "Choose the desktop catalog or controller-first TV interface."
        case .connections: return "Manage store accounts used for library sync and ownership detection."
        case .twitch: return "Connect Twitch and configure live gameplay broadcasting controls."
        case .gameplay: return "Tune streaming quality, latency, input, audio, and microphone behavior."
        case .serverLocation: return "Select Automatic or a measured Cloudmatch region for launches."
        case .resolutionUpscaling: return "Control MetalFX presentation, clarity, and noise reduction for Apple Silicon."
        case .system: return "Review decoder, display, network, and device capability state."
        case .about: return "OpenNOW Mac runtime and service identifiers."
        }
    }
}

private struct SettingsHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title.uppercased())
                        .font(.settingsNvidia(size: 12, weight: .bold))
                        .foregroundStyle(Color.openNowGreen)
                        .tracking(1.5)
                    Text(title)
                        .font(.settingsNvidia(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.settingsNvidia(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
                Spacer(minLength: 24)
                Rectangle()
                    .fill(Color.openNowGreen.opacity(0.42))
                    .frame(width: 120, height: 2)
                    .padding(.bottom, 9)
            }
        }
    }
}

private struct AccountSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel
    @State private var revealSensitive = false
    @State private var copiedKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Membership") {
                HStack(alignment: .top, spacing: 20) {
                    ZStack {
                        SettingsVendorLayout.cardRaised
                            .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.42), lineWidth: 1) }
                        SettingsAccountAvatar(email: viewModel.account.email, size: 58)
                    }
                    .frame(width: 92, height: 92)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(account.displayName)
                                .font(.settingsNvidia(size: 25, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(account.membershipTier.uppercased())
                                .font(.settingsNvidia(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                                .tracking(0.8)
                                .padding(.horizontal, 8)
                                .frame(height: 20)
                                .background(Color.openNowGreen)
                        }
                        Text(accountSummaryText)
                            .font(.settingsNvidia(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.66))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            AboutStatusPill(title: "Provider", value: account.providerName)
                            AboutStatusPill(title: "Playtime", value: viewModel.subscriptionStatus.remainingPlaytimeText)
                            AboutStatusPill(title: "Region", value: route.summary)
                        }
                    }
                    Spacer(minLength: 0)
                    AccountHealthBadge(title: accountHealthTitle, subtitle: accountHealthSubtitle, positive: accountHealthPositive)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    profilePrivacyCard
                    sessionCard
                }
                VStack(alignment: .leading, spacing: 16) {
                    profilePrivacyCard
                    sessionCard
                }
            }

            SettingsCard(title: "Playtime Statistics") {
                if viewModel.playtimeStatistics.sessionCount == 0 {
                    AccountEmptyState(title: "No completed streams recorded yet.", subtitle: "OpenNOW will track local playtime after your next OpenNOW session ends.")
                } else {
                    SettingsFlowLayout(spacing: 10) {
                        SettingsStatisticTile(label: "Total Playtime", value: durationText(viewModel.playtimeStatistics.totalSeconds), emphasized: true)
                        SettingsStatisticTile(label: "Sessions", value: "\(viewModel.playtimeStatistics.sessionCount)")
                        SettingsStatisticTile(label: "Last Session", value: durationText(viewModel.playtimeStatistics.lastSessionSeconds))
                        SettingsStatisticTile(label: "Average Session", value: durationText(viewModel.playtimeStatistics.averageSessionSeconds))
                        SettingsStatisticTile(label: "Longest Session", value: durationText(viewModel.playtimeStatistics.longestSessionSeconds))
                        SettingsStatisticTile(label: "Last Played", value: lastPlayedText)
                    }
                    if !viewModel.playtimeStatistics.lastPlayedTitle.isEmpty {
                        SettingsDivider()
                        AboutDetailRow(label: "Most Recent Game", value: viewModel.playtimeStatistics.lastPlayedTitle, copyValue: viewModel.playtimeStatistics.lastPlayedTitle, copiedKey: $copiedKey)
                    }
                }
            }
        }
    }

    private var profilePrivacyCard: some View {
        SettingsCard(title: "Profile & Privacy") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Personal account details are masked by default.")
                        .font(.settingsNvidia(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Reveal only when validating account state on your own machine.")
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                }
                Spacer()
                SettingsRevealButton(revealed: revealSensitive) { revealSensitive.toggle() }
            }
            SettingsDivider()
            AboutDetailRow(label: "Display Name", value: account.displayName, copyValue: account.displayName, copiedKey: $copiedKey)
            SettingsDivider()
            AboutDetailRow(label: "Email", value: displayedEmail, copyValue: viewModel.account.email, copiedKey: $copiedKey, copyDisabled: viewModel.account.email.isEmpty)
            SettingsDivider()
            AboutDetailRow(label: "User ID", value: displayedUserId, copyValue: account.userId, copiedKey: $copiedKey, copyDisabled: account.userId.isEmpty)
        }
    }

    private var sessionCard: some View {
        SettingsCard(title: "Session") {
            SettingsFlowLayout(spacing: 10) {
                AccountStatusTile(label: "Provider", value: account.providerName, positive: true)
                AccountStatusTile(label: "Authorization", value: account.authorizationState, positive: account.isAuthorized)
                AccountStatusTile(label: "Status", value: account.authStatus, positive: account.isLoggedIn)
                AccountStatusTile(label: "Remember", value: account.rememberSession ? "Enabled" : "Off", positive: account.rememberSession)
            }
            SettingsDivider()
            AboutDetailRow(label: "Preferred Region", value: route.displayValue, copyValue: route.copyValue, copiedKey: $copiedKey)
            SettingsDivider()
            AboutDetailRow(label: "Membership Usage", value: viewModel.subscriptionStatus.usageText, copyValue: viewModel.subscriptionStatus.usageText, copiedKey: $copiedKey)
            SettingsDivider()
            AboutDetailRow(label: "Last Login", value: dateText(viewModel.account.lastLoginAt), copyValue: dateText(viewModel.account.lastLoginAt), copiedKey: $copiedKey)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(positive ? Color.openNowGreen : Color.orange)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.settingsNvidia(size: 12, weight: .bold))
                    .foregroundStyle(positive ? Color.openNowGreen : .white.opacity(0.88))
                    .tracking(1.1)
            }
            Text(subtitle)
                .font(.settingsNvidia(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .frame(width: 172, height: 64, alignment: .leading)
        .background(SettingsVendorLayout.cardRaised)
        .overlay(alignment: .leading) { Rectangle().fill(positive ? Color.openNowGreen : Color.orange).frame(width: 3) }
        .overlay { Rectangle().stroke(positive ? Color.openNowGreen.opacity(0.35) : Color.orange.opacity(0.30), lineWidth: 1) }
    }
}

private struct SettingsRevealButton: View {
    let revealed: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(revealed ? "HIDE DETAILS" : "REVEAL DETAILS")
                .font(.settingsNvidia(size: 11, weight: .bold))
                .foregroundStyle(revealed ? .black : .white.opacity(isHovering ? 0.94 : 0.82))
                .tracking(0.8)
                .padding(.horizontal, 13)
                .frame(height: 32)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.44))
            Text(value.isEmpty ? "Unknown" : value)
                .font(.settingsNvidia(size: 16, weight: .bold))
                .foregroundStyle(positive ? Color.openNowGreen : .white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 188, height: 74, alignment: .leading)
        .background(Color.white.opacity(positive ? 0.065 : 0.045))
        .overlay { Rectangle().stroke(positive ? Color.openNowGreen.opacity(0.32) : Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct AccountEmptyState: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 4, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                Text(subtitle)
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct SettingsStatisticTile: View {
    let label: String
    let value: String
    var emphasized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.44))
            Text(value.isEmpty ? "-" : value)
                .font(.settingsNvidia(size: emphasized ? 24 : 19, weight: .bold))
                .foregroundStyle(emphasized ? Color.openNowGreen : .white.opacity(0.90))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: emphasized ? 206 : 164, height: 78, alignment: .leading)
        .background(Color.white.opacity(emphasized ? 0.075 : 0.052))
        .overlay { Rectangle().stroke(emphasized ? Color.openNowGreen.opacity(0.36) : Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct InterfaceSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel
    @AppStorage(OpenNOWInterfacePreferences.controllerModeEnabledKey) private var controllerModeEnabled = false
    @StateObject private var inputRouter = ControllerInputRouter()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Mode") {
                HStack(alignment: .center, spacing: 18) {
                    Rectangle()
                        .fill(controllerModeEnabled ? Color.openNowGreen : Color.white.opacity(0.18))
                        .frame(width: 4, height: 58)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(controllerModeEnabled ? "Controller mode is active" : "Desktop catalog mode is active")
                            .font(.settingsNvidia(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Controller mode replaces the catalog with a TV-style interface built for gamepads, while keeping keyboard and pointer fallback available.")
                            .font(.settingsNvidia(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    SettingsStatusPill(title: "INPUT", value: inputRouter.glyphs.deviceName, positive: inputRouter.isControllerConnected)
                }
                SettingsDivider()
                SettingsToggleRow(title: "Controller Mode", subtitle: "Use a clean Netflix-style catalog with large focus targets, controller shortcuts, and dynamic input glyphs.", isOn: controllerModeEnabled) { enabled in
                    controllerModeEnabled = enabled
                }
            }

            SettingsCard(title: "Controls") {
                SettingsFlowLayout(spacing: 10) {
                    InterfaceInputLegend(title: "Move", glyphs: [inputRouter.glyphs.left, inputRouter.glyphs.up, inputRouter.glyphs.down, inputRouter.glyphs.right])
                    InterfaceInputLegend(title: "Select", glyphs: [inputRouter.glyphs.confirm])
                    InterfaceInputLegend(title: "Back", glyphs: [inputRouter.glyphs.back])
                    InterfaceInputLegend(title: "Search", glyphs: [inputRouter.glyphs.search])
                    InterfaceInputLegend(title: "Actions", glyphs: [inputRouter.glyphs.actions])
                    InterfaceInputLegend(title: "Rail", glyphs: [inputRouter.glyphs.pageLeft, inputRouter.glyphs.pageRight])
                }
                SettingsDivider()
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: inputRouter.isControllerConnected ? "gamecontroller.fill" : "keyboard")
                        .font(.settingsNvidia(size: 18, weight: .bold))
                        .foregroundStyle(Color.openNowGreen)
                        .frame(width: 34, height: 34)
                        .background(Color.openNowGreen.opacity(0.12))
                        .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.30), lineWidth: 1) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(inputRouter.isControllerConnected ? "Controller glyphs are live" : "Keyboard fallback is active")
                            .font(.settingsNvidia(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                        Text(inputRouter.isControllerConnected ? "Hints use symbols exposed by the connected game controller whenever the system provides them." : "Connect a controller to switch hints from keyboard keys to controller button glyphs automatically.")
                            .font(.settingsNvidia(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct InterfaceInputLegend: View {
    let title: String
    let glyphs: [ControllerInputGlyph]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.settingsNvidia(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.44))
            HStack(spacing: 6) {
                ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                    InterfaceGlyphPill(glyph: glyph)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(minWidth: 132, minHeight: 70, alignment: .leading)
        .background(Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct InterfaceGlyphPill: View {
    let glyph: ControllerInputGlyph

    var body: some View {
        HStack(spacing: 6) {
            if !glyph.symbolName.isEmpty {
                Image(systemName: glyph.symbolName)
                    .font(.settingsNvidia(size: 13, weight: .bold))
            }
            Text(glyph.fallbackText)
                .font(.settingsNvidia(size: 10, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.openNowGreen)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.openNowGreen.opacity(0.12))
        .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.28), lineWidth: 1) }
        .accessibilityLabel(glyph.accessibilityLabel)
    }
}

private struct ConnectionsSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        let stores = connectionStores
        SettingsCard(title: "Store Connections") {
            if stores.isEmpty {
                AccountEmptyState(title: "No store providers available.", subtitle: "OpenNOW did not return any account providers for this session.")
            } else {
                StoreConnectionsOverview(connectedCount: connectedStoreCount(in: stores), totalCount: stores.count)
                SettingsDivider()
                VStack(spacing: 8) {
                    ForEach(stores, id: \.self) { store in
                        StoreConnectionRow(viewModel: viewModel, store: store)
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

private struct TwitchSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel
    @State private var primaryStreamKeyDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Twitch Account") {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.twitchAccountStatus.summary)
                            .font(.settingsNvidia(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        Text(accountSubtitle)
                            .font(.settingsNvidia(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    Spacer(minLength: 12)
                    SettingsStatusPill(title: viewModel.twitchAccountStatus.isConnected ? "CONNECTED" : "OFFLINE", value: viewModel.twitchAccountStatus.streamKeyAvailable ? "READY" : "SETUP", positive: viewModel.twitchAccountStatus.isConnected)
                }
                SettingsDivider()
                SettingsSecureTextFieldRow(title: "Primary Stream Key", subtitle: "Paste the Primary Stream Key from Twitch Creator Dashboard. It is stored in Keychain and is enough to broadcast.", text: $primaryStreamKeyDraft, placeholder: streamKeyPlaceholder)
                HStack(spacing: 10) {
                    SettingsActionButton(title: "SAVE STREAM KEY", minimumWidth: 140) { viewModel.saveTwitchPrimaryStreamKey(primaryStreamKeyDraft); primaryStreamKeyDraft = "" }
                        .disabled(primaryStreamKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    SettingsActionButton(title: "CLEAR STREAM KEY", tone: .secondary, minimumWidth: 140) { viewModel.clearTwitchPrimaryStreamKey() }
                        .disabled(!viewModel.twitchPrimaryStreamKeySaved)
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
                SettingsDivider()
                TwitchAuthorizationInfoRow(isConnected: viewModel.twitchAccountStatus.isConnected)
                SettingsDivider()
                HStack(spacing: 10) {
                    SettingsActionButton(title: viewModel.isConnectingTwitch ? "WAITING FOR TWITCH" : "CONNECT TWITCH", minimumWidth: 170) { viewModel.beginTwitchConnection() }
                        .disabled(viewModel.isConnectingTwitch || viewModel.twitchAccountStatus.isConnected)
                    SettingsActionButton(title: "DISCONNECT", tone: .secondary, minimumWidth: 120) { viewModel.disconnectTwitch() }
                        .disabled(!viewModel.twitchAccountStatus.isConnected)
                    Spacer(minLength: 0)
                }
            }

            SettingsCard(title: "Broadcast") {
                SettingsOptionRow(title: "Ingest", subtitle: "Choose the Twitch ingest endpoint used by the native RTMP publisher.", options: TwitchBroadcastPreferences.IngestRegion.allCases.map(\.label), selectedIndex: selectedIngestIndex, action: viewModel.setTwitchIngestRegion)
                if viewModel.twitchPreferences.ingestRegion == .custom {
                    SettingsDivider()
                    SettingsTextFieldRow(title: "Custom RTMP URL", subtitle: "Use a full RTMP endpoint without the stream key.", text: viewModel.twitchPreferences.customRTMPURL, placeholder: "rtmp://host/app", action: viewModel.setTwitchCustomRTMPURL)
                }
                SettingsDivider()
                SettingsOptionRow(title: "Resolution", subtitle: "Downscale the broadcast independently from the gameplay stream.", options: TwitchBroadcastPreferences.Resolution.allCases.map(\.label), selectedIndex: selectedResolutionIndex, action: viewModel.setTwitchResolution)
                SettingsDivider()
                SettingsOptionRow(title: "Frame Rate", subtitle: "Twitch recommends 60 FPS for high-motion gameplay when bandwidth allows.", options: ["60 FPS", "30 FPS"], selectedIndex: viewModel.twitchPreferences.fps == 30 ? 1 : 0, action: viewModel.setTwitchFPS)
                SettingsDivider()
                SettingsSliderRow(title: "Video Bitrate", valueText: "\(viewModel.twitchPreferences.videoBitrateKbps) Kbps", value: Double(viewModel.twitchPreferences.videoBitrateKbps), range: 500...8_000, step: 100, action: viewModel.setTwitchVideoBitrateKbps)
                SettingsDivider()
                SettingsSliderRow(title: "Audio Bitrate", valueText: "\(viewModel.twitchPreferences.audioBitrateKbps) Kbps", value: Double(viewModel.twitchPreferences.audioBitrateKbps), range: 64...320, step: 16, action: viewModel.setTwitchAudioBitrateKbps)
                SettingsDivider()
                SettingsToggleRow(title: "Use Enhanced Video", subtitle: "Broadcast the upscaled/enhanced frame when available, with decoded stream frames as fallback.", isOn: viewModel.twitchPreferences.useEnhancedVideo, action: viewModel.setTwitchUseEnhancedVideo)
            }

            SettingsCard(title: "Automation & Overlay") {
                SettingsToggleRow(title: "Auto Title From Game", subtitle: "Use the active game title when preparing Twitch broadcast metadata.", isOn: viewModel.twitchPreferences.autoTitleFromGame, action: viewModel.setTwitchAutoTitleFromGame)
                SettingsDivider()
                SettingsToggleRow(title: "Chat Overlay", subtitle: "Show Twitch chat controls inside the stream overlay.", isOn: viewModel.twitchPreferences.chatOverlayEnabled, action: viewModel.setTwitchChatOverlayEnabled)
                SettingsDivider()
                SettingsToggleRow(title: "Event Alerts", subtitle: "Show follows, subscriptions, raids, and channel events over the stream.", isOn: viewModel.twitchPreferences.eventAlertsEnabled, action: viewModel.setTwitchEventAlertsEnabled)
            }

            SettingsCard(title: "In-Stream Hotkeys") {
                SettingsInfoRow(label: "Command-G", value: "Show or hide the unified stream HUD")
                SettingsDivider()
                SettingsInfoRow(label: "Command-N", value: "Show or hide stream stats")
                SettingsDivider()
                SettingsInfoRow(label: "Command-M", value: "Toggle microphone")
                SettingsDivider()
                SettingsInfoRow(label: "Command-R", value: "Toggle recording")
                SettingsDivider()
                SettingsInfoRow(label: "Command-K", value: "Toggle Anti-AFK")
                SettingsDivider()
                SettingsInfoRow(label: "Command-Q", value: "Open stream quit controls")
            }
        }
    }

    private var accountSubtitle: String {
        if viewModel.twitchPrimaryStreamKeySaved, !viewModel.twitchAccountStatus.isConnected {
            return "Primary Stream Key is saved. Connect OAuth for channel metadata, markers, chat, and event features."
        }
        if viewModel.twitchAccountStatus.isConnected {
            return viewModel.twitchAccountStatus.streamKeyAvailable ? "Stream key is available for RTMP publishing." : "Connected, but stream key has not been fetched yet."
        }
        return "Paste your Primary Stream Key to broadcast immediately, or connect Twitch for metadata and chat features."
    }

    private var streamKeyPlaceholder: String {
        viewModel.twitchPrimaryStreamKeySaved ? "Saved in Keychain" : "live_..."
    }

    private var selectedIngestIndex: Int {
        TwitchBroadcastPreferences.IngestRegion.allCases.firstIndex(of: viewModel.twitchPreferences.ingestRegion) ?? 0
    }

    private var selectedResolutionIndex: Int {
        TwitchBroadcastPreferences.Resolution.allCases.firstIndex(of: viewModel.twitchPreferences.resolution) ?? 0
    }
}

private struct TwitchAuthorizationInfoRow: View {
    let isConnected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Rectangle()
                .fill(isConnected ? Color.openNowGreen : Color.white.opacity(0.18))
                .frame(width: 4, height: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text("Browser authorization")
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text("Connect Twitch to enable channel metadata, stream markers, chat, and event features.")
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            SettingsStatusPill(title: "OAUTH", value: isConnected ? "Linked" : "Optional", positive: isConnected)
        }
        .padding(12)
        .background(SettingsVendorLayout.row)
        .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct StoreConnectionsOverview: View {
    let connectedCount: Int
    let totalCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Library ownership sync")
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text("Connected stores can sync library ownership before launch.")
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer(minLength: 0)
            SettingsStatusPill(title: "CONNECTED", value: "\(connectedCount)/\(totalCount)", positive: connectedCount > 0)
        }
    }
}

private struct StoreConnectionRow: View {
    @ObservedObject var viewModel: CatalogViewModel
    let store: String

    var body: some View {
        let account = viewModel.accountStatus(forStore: store)
        let definition = viewModel.storeDefinitions.first { $0.store.caseInsensitiveCompare(store) == .orderedSame }
        let displayName = viewModel.displayName(forStore: store)
        let iconAsset = StoreIconAsset.resolve(store: store, displayName: displayName)
        let iconURL = definition?.smallImageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let isConnected = account != nil
        let supportsLinking = definition?.isAccountLinkingSupported == true || account?.hasAccountLinkingData == true
        HStack(alignment: .center, spacing: 16) {
            Rectangle()
                .fill(isConnected ? Color.openNowGreen : Color.white.opacity(0.18))
                .frame(width: 4, height: 46)
            StoreIcon(asset: iconAsset, imageURL: iconURL, connected: isConnected)
            VStack(alignment: .leading, spacing: 5) {
                Text(displayName)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(isConnected ? .white : .white.opacity(0.86))
                Text(statusText(account))
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(isConnected ? .white.opacity(0.62) : .white.opacity(0.44))
            }
            Spacer(minLength: 12)
            SettingsStatusPill(title: isConnected ? "LINKED" : "AVAILABLE", value: isConnected ? connectionDetail(account) : "Not linked", positive: isConnected)
            if account?.hasAccountSyncingData == true {
                SettingsActionButton(title: "SYNC", tone: .secondary, minimumWidth: 86) { viewModel.syncStoreAccount(store) }
            }
            if supportsLinking {
                SettingsActionButton(title: account == nil ? "CONNECT" : "MANAGE", minimumWidth: 96) { viewModel.linkStoreAccount(store) }
            }
        }
        .padding(12)
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
        .frame(width: 42, height: 42)
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
    static func loadImage(named name: String) -> NSImage? {
        let cacheKey = name as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "StoreIcons") ?? Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Resources/StoreIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    private static let cache = NSCache<NSString, NSImage>()
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

private struct GameplaySettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Streaming Profile") {
                GameplayProfileOverview(
                    mode: streamingProfileMode,
                    resolution: viewModel.streamProfile.resolution.label,
                    frameRate: "\(viewModel.streamProfile.fps) FPS",
                    codec: viewModel.streamProfile.codec.label,
                    bitrate: "\(viewModel.streamProfile.maxBitrateMbps) Mbps",
                    colorPrecision: viewModel.streamProfile.colorQuality.label,
                    dataUsage: estimatedDataUsage
                )
            }

            SettingsCard(title: "Streaming Quality") {
                SettingsOptionRow(title: "Aspect Ratio", subtitle: "Controls the available resolution list.", options: OPNStreamPreferences.aspectOptions.map(\.label), selectedIndex: viewModel.streamProfile.aspectIndex, action: viewModel.setAspectIndex)
                SettingsDivider()
                SettingsOptionRow(title: "Resolution", subtitle: "Current target: \(viewModel.streamProfile.resolution.label).", options: OPNStreamPreferences.resolutionOptions(forAspect: viewModel.streamProfile.aspectIndex).map(\.label), selectedIndex: viewModel.streamProfile.resolutionIndex, action: viewModel.setResolutionIndex)
                SettingsDivider()
                SettingsOptionRow(title: "Frame Rate", subtitle: "Limited by the active display refresh rate.", options: OPNStreamPreferences.fpsOptions.map { "\($0) FPS" }, selectedIndex: viewModel.streamProfile.fpsIndex, enabled: OPNStreamPreferences.fpsOptions.map { OPNStreamPreferences.fpsSupported($0, capabilities: viewModel.streamCapabilities) }, action: viewModel.setFpsIndex)
                SettingsDivider()
                SettingsOptionRow(title: "Codec", subtitle: "Unavailable hardware codecs are disabled.", options: OPNStreamPreferences.codecOptions.map(\.label), selectedIndex: viewModel.streamProfile.codecIndex, enabled: OPNStreamPreferences.codecOptions.map { OPNStreamPreferences.codecSupported($0, capabilities: viewModel.streamCapabilities) }, action: viewModel.setCodecIndex)
                SettingsDivider()
                SettingsOptionRow(title: "Maximum Bitrate", subtitle: "Higher bitrate improves clarity on stable connections.", options: OPNStreamPreferences.bitrateOptions.map(\.label), selectedIndex: viewModel.streamProfile.bitrateIndex, action: viewModel.setBitrateIndex)
                SettingsDivider()
                SettingsOptionRow(title: "Color Precision", subtitle: "10-bit modes require HEVC, AV1, or Auto support.", options: OPNStreamPreferences.colorQualityOptions.map(\.label), selectedIndex: viewModel.streamProfile.colorQualityIndex, enabled: OPNStreamPreferences.colorQualityOptions.map { OPNStreamPreferences.colorQualitySupported($0, codec: viewModel.streamProfile.codec, capabilities: viewModel.streamCapabilities) }, action: viewModel.setColorQualityIndex)
            }

            SettingsCard(title: "Gameplay") {
                SettingsToggleRow(title: "NVIDIA Reflex / Low Latency", subtitle: "Prioritizes responsiveness during supported sessions.", isOn: viewModel.streamProfile.lowLatencyMode, action: viewModel.setLowLatencyModeEnabled)
                SettingsDivider()
                SettingsToggleRow(title: "L4S", subtitle: "Use low-latency scalable throughput when available.", isOn: viewModel.streamProfile.enableL4S, action: viewModel.setL4SEnabled)
                SettingsDivider()
                SettingsToggleRow(title: "HDR", subtitle: "Requires a compatible display and stream capability.", isOn: viewModel.streamProfile.enableHdr, action: viewModel.setHDREnabled)
                SettingsDivider()
                SettingsToggleRow(title: "Power Saver", subtitle: "Reduce resource use when possible.", isOn: viewModel.streamProfile.enablePowerSaver, action: viewModel.setPowerSaverEnabled)
                SettingsDivider()
                SettingsToggleRow(title: "Prevent Display Sleep", subtitle: "Keeps the monitor awake while a stream is active.", isOn: viewModel.streamProfile.preventDisplaySleepWhileStreaming, action: viewModel.setPreventDisplaySleepWhileStreaming)
                SettingsDivider()
                SettingsToggleRow(title: "Direct Mouse Input", subtitle: "Send mouse input directly to the stream.", isOn: viewModel.streamProfile.directMouseInput, action: viewModel.setDirectMouseInputEnabled)
                SettingsDivider()
                SettingsToggleRow(title: "Anti-AFK Mouse Movement", subtitle: "Moves the stream mouse every 60 seconds while a stream is active. Cmd-K toggles it in-stream.", isOn: viewModel.streamProfile.antiAFKMouseMovementEnabled, action: viewModel.setAntiAFKMouseMovementEnabled)
                SettingsDivider()
                SettingsToggleRow(title: "Suppress Input When Inactive", subtitle: "Avoid sending input while OpenNOW is not focused.", isOn: viewModel.streamProfile.suppressInputWhenInactive, action: viewModel.setSuppressInputWhenInactive)
            }

            SettingsCard(title: "Recording") {
                SettingsSliderRow(title: "Video Bitrate", valueText: recordingVideoBitrateText, value: Double(viewModel.streamProfile.recordingVideoBitrateMbps), range: 0...200, step: 1, action: viewModel.setRecordingVideoBitrateMbps)
                SettingsDivider()
                SettingsSliderRow(title: "Audio Bitrate", valueText: "\(viewModel.streamProfile.recordingAudioBitrateKbps) Kbps", value: Double(viewModel.streamProfile.recordingAudioBitrateKbps), range: 64...320, step: 16, action: viewModel.setRecordingAudioBitrateKbps)
                SettingsDivider()
                SettingsToggleRow(title: "Record Enhanced Video", subtitle: "Capture the enhanced/upscaled stream frame when available, with native decoded frames as fallback.", isOn: viewModel.streamProfile.recordingEnhancedVideoEnabled, action: viewModel.setRecordingEnhancedVideoEnabled)
            }

            SettingsCard(title: "Audio") {
                SettingsSliderRow(title: "Game Volume", valueText: percentText(viewModel.streamProfile.gameVolume), value: viewModel.streamProfile.gameVolume, range: 0...1, step: 0.01, action: viewModel.setGameVolume)
                SettingsDivider()
                SettingsSliderRow(title: "Microphone Volume", valueText: percentText(viewModel.streamProfile.microphoneVolume), value: viewModel.streamProfile.microphoneVolume, range: 0...1, step: 0.01, action: viewModel.setMicrophoneVolume)
                SettingsDivider()
                SettingsOptionRow(title: "Microphone Mode", subtitle: "Controls how voice input is sent to the stream.", options: OPNStreamPreferences.microphoneModeOptions.map(\.label), selectedIndex: selectedMicrophoneModeIndex, action: { viewModel.setMicrophoneMode(OPNStreamPreferences.microphoneModeOptions[$0].value) })
                SettingsDivider()
                SettingsOptionRow(title: "Microphone Device", subtitle: "Current input device for OpenNOW streams.", options: viewModel.microphoneDeviceOptions.map(\.label), selectedIndex: selectedMicrophoneDeviceIndex, action: { viewModel.setMicrophoneDeviceId(viewModel.microphoneDeviceOptions[$0].uniqueId) })
            }

            SettingsCard(title: "Profile Maintenance") {
                HStack(alignment: .center, spacing: 16) {
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 4, height: 48)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Restore default streaming settings")
                            .font(.settingsNvidia(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Resets resolution, FPS, codec, bitrate, color precision, latency, HDR, L4S, input, audio, and enhancement options.")
                            .font(.settingsNvidia(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.56))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    SettingsActionButton(title: "RESTORE DEFAULTS", minimumWidth: 150) { viewModel.restoreStreamingProfileDefaults() }
                }
                .padding(12)
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

    private var streamingProfileMode: String {
        viewModel.streamProfile == OPNStreamPreferenceProfile() ? "Balanced defaults" : "Custom"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Active streaming profile")
                        .font(.settingsNvidia(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text("These values are sent to OpenNOW when a new stream starts.")
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer(minLength: 0)
                SettingsStatusPill(title: "MODE", value: mode, positive: mode != "Balanced defaults")
            }

            SettingsFlowLayout(spacing: 10) {
                GameplayProfileMetricTile(label: "Resolution", value: resolution, emphasized: true)
                GameplayProfileMetricTile(label: "Frame Rate", value: frameRate, emphasized: true)
                GameplayProfileMetricTile(label: "Codec", value: codec)
                GameplayProfileMetricTile(label: "Bitrate", value: bitrate)
                GameplayProfileMetricTile(label: "Color", value: colorPrecision)
                GameplayProfileMetricTile(label: "Data Usage", value: dataUsage, width: 260)
            }
        }
    }
}

private struct GameplayProfileMetricTile: View {
    let label: String
    let value: String
    var emphasized = false
    var width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.44))
            Text(value.isEmpty ? "-" : value)
                .font(.settingsNvidia(size: emphasized ? 16 : 14, weight: .bold))
                .foregroundStyle(emphasized ? Color.openNowGreen : .white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: width ?? (emphasized ? 180 : 154), height: 72, alignment: .leading)
        .background(Color.white.opacity(emphasized ? 0.065 : 0.045))
        .overlay { Rectangle().stroke(emphasized ? Color.openNowGreen.opacity(0.32) : Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct ServerLocationSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel
    private let regionColumns = [GridItem(.adaptive(minimum: 138, maximum: 220), spacing: 10)]

    var body: some View {
        let selectedOption = viewModel.settingsRegionOptions.first { $0.url == viewModel.selectedSettingsRegionUrl }
        SettingsCard(title: "Server Location") {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cloudmatch Region")
                        .font(.settingsNvidia(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Automatic chooses the best measured OpenNOW route.")
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer(minLength: 12)
                SettingsStatusPill(title: "ACTIVE", value: selectedRegionTitle(selectedOption), positive: true)
                SettingsActionButton(title: viewModel.isRefreshingSettingsRegions ? "PINGING" : "REFRESH", minimumWidth: 104) { viewModel.refreshSettingsRegions() }
                    .disabled(viewModel.isRefreshingSettingsRegions)
            }
            SettingsDivider()
            if !viewModel.unavailableSettingsRegionUrl.isEmpty {
                UnavailableRegionPrompt(regionUrl: viewModel.unavailableSettingsRegionUrl, keepAction: viewModel.keepUnavailableSettingsRegion, automaticAction: viewModel.switchUnavailableSettingsRegionToAutomatic)
                SettingsDivider()
            }
            LazyVGrid(columns: regionColumns, alignment: .leading, spacing: 10) {
                ForEach(viewModel.settingsRegionOptions, id: \.url) { option in
                    SettingsRegionRow(option: option, selected: option.url == viewModel.selectedSettingsRegionUrl) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected Region Unavailable")
                        .font(.settingsNvidia(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text("CloudMatch no longer advertises the selected route. Keep it for one more launch attempt, or switch to Automatic.")
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                    Text(regionUrl)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
            }
            HStack(spacing: 10) {
                SettingsActionButton(title: "KEEP", tone: .secondary, minimumWidth: 82, action: keepAction)
                SettingsActionButton(title: "AUTOMATIC", minimumWidth: 112, action: automaticAction)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08))
        .overlay { Rectangle().stroke(Color.orange.opacity(0.22), lineWidth: 1) }
    }
}

private struct ResolutionUpscalingSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "MetalFX Upscaling") {
                SettingsToggleRow(title: "MetalFX Upscaling", subtitle: "Optimized for Apple Silicon. Falls back automatically when MetalFX is unavailable.", isOn: viewModel.streamProfile.upscalingMode == 3) { enabled in viewModel.setUpscalingModeIndex(enabled ? 1 : 0) }
                SettingsDivider()
                SettingsInfoRow(label: "Target", value: "Display")
                SettingsDivider()
                SettingsSliderRow(title: "Clarity", valueText: "\(viewModel.streamProfile.upscalingSharpness)", value: Double(viewModel.streamProfile.upscalingSharpness), range: 0...15, action: viewModel.setUpscalingSharpness)
                SettingsDivider()
                SettingsSliderRow(title: "Noise Reduction", valueText: "\(viewModel.streamProfile.upscalingDenoise)", value: Double(viewModel.streamProfile.upscalingDenoise), range: 0...20, action: viewModel.setUpscalingDenoise)
            }

            SettingsCard(title: "Image Enhancement") {
                SettingsOptionRow(title: "Prefilter Mode", subtitle: "Applies GFN-style prefiltering before presentation.", options: OPNStreamPreferences.prefilterModeOptions.map(\.label), selectedIndex: viewModel.streamProfile.prefilterModeIndex, action: viewModel.setPrefilterModeIndex)
                SettingsDivider()
                SettingsSliderRow(title: "Prefilter Sharpness", valueText: "\(viewModel.streamProfile.prefilterSharpness)", value: Double(viewModel.streamProfile.prefilterSharpness), range: 0...10, action: viewModel.setPrefilterSharpness)
                SettingsDivider()
                SettingsSliderRow(title: "Prefilter Denoise", valueText: "\(viewModel.streamProfile.prefilterDenoise)", value: Double(viewModel.streamProfile.prefilterDenoise), range: 0...10, action: viewModel.setPrefilterDenoise)
            }
        }
    }
}

private struct SystemSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel
    @State private var revealSensitive = false
    @State private var copiedKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Readiness") {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(systemSummaryTitle)
                            .font(.settingsNvidia(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Text(systemSummaryDetail)
                            .font(.settingsNvidia(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            AboutStatusPill(title: "Display", value: displaySummary)
                            AboutStatusPill(title: "Decode", value: preferredDecoder)
                            AboutStatusPill(title: "Route", value: route.summary)
                        }
                    }
                    Spacer(minLength: 0)
                    SystemHealthBadge(title: systemHealthTitle, subtitle: systemHealthSubtitle, positive: systemHealthPositive)
                }
            }

            SettingsCard(title: "Display") {
                SettingsFlowLayout(spacing: 10) {
                    SettingsStatisticTile(label: "Resolution", value: displaySummary, emphasized: true)
                    SettingsStatisticTile(label: "Refresh", value: refreshRateText)
                    SettingsStatisticTile(label: "DPI", value: dpiText)
                    SettingsStatisticTile(label: "HDR", value: viewModel.streamCapabilities.hdrDisplaySupported ? "Ready" : "Unavailable")
                }
            }

            SettingsCard(title: "Video Decode") {
                VStack(spacing: 10) {
                    SystemCapabilityRow(title: "H.264", subtitle: "Baseline stream compatibility", value: viewModel.streamCapabilities.h264HardwareDecodeSupported ? "Hardware" : "Software", positive: viewModel.streamCapabilities.h264HardwareDecodeSupported)
                    SystemCapabilityRow(title: "HEVC", subtitle: "Efficient high-quality streaming", value: viewModel.streamCapabilities.h265HardwareDecodeSupported ? "Supported" : "Unavailable", positive: viewModel.streamCapabilities.h265HardwareDecodeSupported)
                    SystemCapabilityRow(title: "AV1", subtitle: "Next-generation low-bitrate streaming", value: viewModel.streamCapabilities.av1HardwareDecodeSupported ? "Supported" : "Unavailable", positive: viewModel.streamCapabilities.av1HardwareDecodeSupported)
                }
            }

            SettingsCard(title: "Device & Route") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Identifiers and endpoint paths are masked by default.")
                            .font(.settingsNvidia(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Reveal only when collecting support information locally.")
                            .font(.settingsNvidia(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                    Spacer()
                    SettingsRevealButton(revealed: revealSensitive) { revealSensitive.toggle() }
                }
                SettingsDivider()
                AboutDetailRow(label: "Device ID", value: displayedDeviceId, copyValue: viewModel.session.deviceId, copiedKey: $copiedKey, copyDisabled: viewModel.session.deviceId.isEmpty)
                SettingsDivider()
                AboutDetailRow(label: "Current Region", value: route.displayValue, copyValue: route.copyValue, copiedKey: $copiedKey)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.settingsNvidia(size: 12, weight: .bold))
                .foregroundStyle(positive ? .black : .white.opacity(0.88))
                .tracking(1.1)
            Text(subtitle)
                .font(.settingsNvidia(size: 11, weight: .bold))
                .foregroundStyle(positive ? .black.opacity(0.74) : .white.opacity(0.54))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .frame(width: 172, height: 64, alignment: .leading)
        .background(positive ? Color.openNowGreen : Color.white.opacity(0.07))
        .overlay { Rectangle().stroke(positive ? Color.openNowGreen : Color.white.opacity(0.13), lineWidth: 1) }
    }
}

private struct SystemCapabilityRow: View {
    let title: String
    let subtitle: String
    let value: String
    let positive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(positive ? Color.openNowGreen : Color.white.opacity(0.22))
                .frame(width: 4, height: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.56))
            }
            Spacer(minLength: 0)
            Text(value.uppercased())
                .font(.settingsNvidia(size: 11, weight: .bold))
                .foregroundStyle(positive ? Color.openNowGreen : .white.opacity(0.56))
                .tracking(0.8)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.white.opacity(positive ? 0.07 : 0.04))
                .overlay { Rectangle().stroke(positive ? Color.openNowGreen.opacity(0.38) : Color.white.opacity(0.08), lineWidth: 1) }
        }
        .padding(12)
        .background(Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct AboutSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel
    @State private var copiedKey = ""
    @State private var diagnosticsState = AboutDiagnosticsState.ready
    @State private var showingDiagnosticsUploadConfirmation = false
    @AppStorage(OpenNOWUpdatePreferences.automaticUpdateChecksEnabledKey) private var automaticUpdateChecksEnabled = OpenNOWUpdatePreferences.defaultAutomaticUpdateChecksEnabled
    @State private var telemetryDisabled = OPNSentry.isTelemetryDisabled()

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Product") {
                HStack(alignment: .top, spacing: 22) {
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.22))
                            .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.72), lineWidth: 1) }
                        VendorResourceImage(name: "nv-gfn-logo_v3", fileExtension: "png")
                            .scaledToFit()
                            .padding(.horizontal, 14)
                    }
                    .frame(width: 180, height: 88)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(SettingsAppMetadata.displayName)
                                .font(.settingsNvidia(size: 25, weight: .bold))
                                .foregroundStyle(.white)
                            Text("UNOFFICIAL CLIENT SHELL")
                                .font(.settingsNvidia(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                                .tracking(0.8)
                                .padding(.horizontal, 8)
                                .frame(height: 20)
                                .background(Color.openNowGreen)
                        }
                        Text("A macOS runtime for launching and streaming OpenNOW sessions with local catalog, account, and diagnostics surfaces.")
                            .font(.settingsNvidia(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.66))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            AboutStatusPill(title: "Stream", value: "WebRTC")
                            AboutStatusPill(title: "Route", value: route.summary)
                            AboutStatusPill(title: "Telemetry", value: telemetryDisabled ? "Off" : "On")
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            SettingsCard(title: "Runtime") {
                AboutDetailRow(label: "Version", value: SettingsAppMetadata.version, copyValue: SettingsAppMetadata.version, copiedKey: $copiedKey)
                SettingsDivider()
                AboutDetailRow(label: "Build", value: SettingsAppMetadata.build, copyValue: SettingsAppMetadata.build, copiedKey: $copiedKey)
                SettingsDivider()
                AboutDetailRow(label: "Bundle", value: bundleIdentifier, copyValue: bundleIdentifier, copiedKey: $copiedKey)
                SettingsDivider()
                AboutDetailRow(label: "macOS", value: operatingSystemVersion, copyValue: operatingSystemVersion, copiedKey: $copiedKey)
                SettingsDivider()
                SettingsToggleRow(title: "Automatic Update Checks", subtitle: automaticUpdateChecksSubtitle, isOn: automaticUpdateChecksEnabled) { enabled in
                    OpenNOWAppDelegate.setAutomaticApplicationUpdateChecksEnabled(enabled)
                }
                SettingsDivider()
                HStack(spacing: 10) {
                    SettingsActionButton(title: "CHECK FOR UPDATES") {
                        OpenNOWAppDelegate.requestApplicationUpdateCheck()
                    }
                    Text("Checks GitHub releases and installs a newer signed OpenNOW build when available.")
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                }
            }

            SettingsCard(title: "Cache") {
                AboutDetailRow(label: "Catalog Images", value: viewModel.catalogImageCacheSummary, copyValue: viewModel.catalogImageCacheSummary, copiedKey: $copiedKey)
                SettingsDivider()
                HStack(spacing: 10) {
                    SettingsActionButton(title: "CLEAR IMAGE CACHE") {
                        viewModel.clearCatalogImageCache()
                    }
                    Text("Removes cached catalog artwork from disk and memory. Images will download again as needed.")
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                }
            }

            SettingsCard(title: "Privacy") {
                SettingsToggleRow(title: "Disable Telemetry", subtitle: "Stops Sentry, trace headers, metrics, and automatic diagnostics logging.", isOn: telemetryDisabled, action: setTelemetryDisabled)
            }

            SettingsCard(title: "Support Diagnostics") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        SettingsActionButton(title: diagnosticsButtonTitle) {
                            showingDiagnosticsUploadConfirmation = true
                        }
                        .disabled(diagnosticsState.isWorking)
                        Text("Uploads the recent sanitized current-run log, then copies diagnostics with the link.")
                            .font(.settingsNvidia(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.54))
                    }
                    Text(diagnosticsState.message)
                        .font(.settingsNvidia(size: 12, weight: .medium))
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
                    }
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
        if OpenNOWUpdatePreferences.updateChecksAreSuspendedForDebugging {
            return "Paused while running a debug build or attached debugger. Manual checks remain available."
        }
        if automaticUpdateChecksEnabled {
            return "Checks GitHub releases on launch and hourly while OpenNOW is running."
        }
        return "OpenNOW will not check for new releases automatically. Manual checks remain available."
    }

    private var diagnosticsText: String {
        diagnosticsText(logURL: nil)
    }

    private func diagnosticsText(logURL: URL?) -> String {
        [
            "OpenNOW Mac Diagnostics",
            "Version: \(SettingsAppMetadata.versionWithBuild)",
            "Bundle: \(bundleIdentifier)",
            "macOS: \(operatingSystemVersion)",
            "Account: \(account.displayName)",
            "Membership: \(account.membershipTier)",
            "User ID: \(SettingsFormat.maskedIdentifier(account.userId))",
            "Streaming: WebRTC",
            "Cloudmatch: \(route.summary)",
            "Logs: \(logURL?.absoluteString ?? "Not uploaded")"
        ].joined(separator: "\n")
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
                copy(diagnosticsText(logURL: logURL), key: "diagnostics")
                diagnosticsState = .copied(logURL.absoluteString)
                OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "Diagnostics", message: "Uploaded sanitized diagnostics log url=\(logURL.absoluteString)"))
            } catch {
                let message = error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
                diagnosticsState = .failed(message)
                OPNSentry.logErrorMessage(OPNSentry.formattedLogMessage(level: "error", area: "Diagnostics", message: "Diagnostics upload failed error=\(message)"))
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

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .onTapGesture(perform: cancel)

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        Rectangle()
                            .fill(Color.openNowGreen.opacity(0.16))
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.settingsNvidia(size: 18, weight: .bold))
                            .foregroundStyle(Color.openNowGreen)
                    }
                    .frame(width: 44, height: 44)
                    .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.42), lineWidth: 1) }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Upload diagnostics logs?")
                            .font(.settingsNvidia(size: 19, weight: .bold))
                            .foregroundStyle(.white)
                        Text("OpenNOW will upload the recent sanitized current-run log to paste.rs and copy a diagnostics summary with the public link.")
                            .font(.settingsNvidia(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Rectangle()
                        .fill(Color.openNowGreen)
                        .frame(width: 4, height: 42)
                    Text("IP addresses and location fields are redacted before upload. Only generate this when preparing support diagnostics.")
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.white.opacity(0.045))
                .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }

                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    SettingsDialogButton(title: "CANCEL", tone: .secondary, action: cancel)
                    SettingsDialogButton(title: "UPLOAD LOGS", tone: .primary, action: upload)
                }
            }
            .padding(22)
            .frame(width: 430, alignment: .leading)
            .background(Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255))
            .overlay { Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1) }
            .shadow(color: .black.opacity(0.62), radius: 34, x: 0, y: 18)
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
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.settingsNvidia(size: 12, weight: .bold))
                .foregroundStyle(tone == .primary ? .black : .white.opacity(0.82))
                .tracking(0.8)
                .padding(.horizontal, 14)
                .frame(minWidth: 104)
                .frame(height: 34)
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
        case .uploading: return "Uploading sanitized logs to paste.rs..."
        case .copying: return "Copying diagnostics and uploaded log link to clipboard..."
        case .copied(let url): return "Diagnostics copied. Uploaded log: \(url)"
        case .failed(let reason): return "Upload failed: \(reason)"
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

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.settingsNvidia(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.44))
                .tracking(0.8)
            Text(value.isEmpty ? "Unknown" : value)
                .font(.settingsNvidia(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
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

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.44))
                .tracking(0.5)
                .frame(width: 150, alignment: .leading)
            Text(value.isEmpty ? "Unavailable" : value)
                .font(.settingsNvidia(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button { copy(copyValue) } label: {
                Text(copiedKey == label ? "COPIED" : "COPY")
                    .font(.settingsNvidia(size: 10, weight: .bold))
                    .foregroundStyle(copyDisabled ? .white.opacity(0.28) : .white.opacity(0.74))
                    .tracking(0.7)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
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
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.openNowGreen)
                    .frame(width: 4, height: 18)
                Text(title.uppercased())
                    .font(.settingsNvidia(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.68))
                    .tracking(1.1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 17)
            .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
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
        .shadow(color: .black.opacity(0.26), radius: 16, y: 8)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.vertical, 14)
    }
}

private struct SettingsInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.44))
                .frame(width: 150, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .font(.settingsNvidia(size: 13, weight: .medium))
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
    let action: (Int) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250, alignment: .leading)
            SettingsFlowLayout(spacing: 8) {
                ForEach(options.indices, id: \.self) { index in
                    let optionEnabled = enabled.indices.contains(index) ? enabled[index] : true
                    Button { action(index) } label: {
                        Text(options[index])
                            .font(.settingsNvidia(size: 12, weight: .bold))
                            .foregroundStyle(index == selectedIndex ? .black : .white.opacity(optionEnabled ? 0.82 : 0.34))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(index == selectedIndex ? Color.openNowGreen : Color.white.opacity(optionEnabled ? 0.07 : 0.035))
                            .overlay { Rectangle().stroke(index == selectedIndex ? Color.openNowGreen : Color.white.opacity(0.12), lineWidth: 1) }
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
    let action: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: action))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

private struct SettingsTextFieldRow: View {
    let title: String
    let subtitle: String
    let text: String
    let placeholder: String
    let action: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250, alignment: .leading)
            TextField(placeholder, text: Binding(get: { draft }, set: updateDraft))
                .textFieldStyle(.plain)
                .font(.settingsNvidia(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .frame(height: 36)
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

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250, alignment: .leading)
            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.settingsNvidia(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color.white.opacity(0.07))
                .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
        }
    }
}

private struct SettingsSliderRow: View {
    let title: String
    let valueText: String
    let value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    let action: (Double) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(valueText)
                    .font(.settingsNvidia(size: 12, weight: .bold))
                    .foregroundStyle(Color.openNowGreen)
            }
            .frame(width: 250, alignment: .leading)
            Slider(value: Binding(get: { value }, set: action), in: range, step: step)
                .tint(Color.openNowGreen)
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
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.settingsNvidia(size: 12, weight: .bold))
                .foregroundStyle(foregroundColor)
                .tracking(0.8)
                .padding(.horizontal, 14)
                .frame(minWidth: minimumWidth)
                .frame(height: 32)
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

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(title.uppercased())
                .font(.settingsNvidia(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
                .tracking(0.8)
            Text(value.isEmpty ? "-" : value)
                .font(.settingsNvidia(size: 12, weight: .bold))
                .foregroundStyle(positive ? Color.openNowGreen : .white.opacity(0.66))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 94, alignment: .trailing)
        .frame(height: 40)
        .background(Color.white.opacity(positive ? 0.055 : 0.035))
        .overlay { Rectangle().stroke(positive ? Color.openNowGreen.opacity(0.24) : Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct SettingsRegionRow: View {
    let option: OPNStreamRegionOption
    let selected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(SettingsRegionName.shortName(for: option))
                        .font(.settingsNvidia(size: 13, weight: .bold))
                        .foregroundStyle(selected ? .white : .white.opacity(0.90))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer(minLength: 6)
                    Circle()
                        .fill(selected ? Color.openNowGreen : Color.white.opacity(isHovering ? 0.34 : 0.22))
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)
                }
                RegionLatencyBadge(latencyMs: option.latencyMs, selected: selected)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
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

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 6, height: 6)
            Text(latencyText)
                .font(.settingsNvidia(size: 11, weight: .bold))
                .foregroundStyle(selected ? Color.openNowGreen : .white.opacity(0.74))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.openNowGreen)
            Text(message)
                .font(.settingsNvidia(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.07))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }
}

private struct SettingsFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
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
