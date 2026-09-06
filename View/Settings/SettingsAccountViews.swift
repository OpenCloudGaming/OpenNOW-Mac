import AppKit
import CryptoKit
import SwiftUI

struct AccountSettingsPage: View {
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
                            .overlay { Rectangle().stroke(OpenNOWDesign.accent.opacity(0.42), lineWidth: 1) }
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
                                .background(OpenNOWDesign.accent)
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
            .settingsSection("membership")

            // Full width, one under the other, like every other settings page. Side by side the
            // two cards held different amounts and so ended at different heights, which read as a
            // layout accident rather than a choice, and squeezed the value columns of both.
            profilePrivacyCard
                .settingsSection("profile")
            sessionCard
                .settingsSection("session")

            SettingsCard(title: "Playtime Statistics", uiScale: uiScale) {
                if viewModel.playtimeStatistics.sessionCount == 0 {
                    AccountEmptyState(title: "No completed streams recorded yet.", subtitle: "OpenNOW will track local playtime after your next OpenNOW session ends.", uiScale: uiScale)
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
            .settingsSection("playtime")
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

struct AccountHealthBadge: View {
    let title: String
    let subtitle: String
    let positive: Bool
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * uiScale) {
            HStack(spacing: 7 * uiScale) {
                Circle()
                    .fill(positive ? OpenNOWDesign.accent : Color.orange)
                    .frame(width: 7 * uiScale, height: 7 * uiScale)
                Text(title)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                    .foregroundStyle(positive ? OpenNOWDesign.accent : .white.opacity(0.88))
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
        .overlay(alignment: .leading) { Rectangle().fill(positive ? OpenNOWDesign.accent : Color.orange).frame(width: 3 * uiScale) }
        .overlay { Rectangle().stroke(positive ? OpenNOWDesign.accent.opacity(0.35) : Color.orange.opacity(0.30), lineWidth: 1) }
    }
}

struct SettingsRevealButton: View {
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
                .background(revealed ? OpenNOWDesign.accent.opacity(isHovering ? 0.90 : 1) : Color.white.opacity(isHovering ? 0.10 : 0.065))
                .overlay { Rectangle().stroke(revealed ? OpenNOWDesign.accent : Color.white.opacity(isHovering ? 0.20 : 0.13), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct SettingsAccountAvatar: View {
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

struct AccountStatusTile: View {
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
                .foregroundStyle(positive ? OpenNOWDesign.accent : .white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 14 * uiScale)
        .padding(.vertical, 12 * uiScale)
        .frame(width: 188 * uiScale, height: 74 * uiScale, alignment: .leading)
        .background(Color.white.opacity(positive ? 0.065 : 0.045))
        .overlay { Rectangle().stroke(positive ? OpenNOWDesign.accent.opacity(0.32) : Color.white.opacity(0.08), lineWidth: 1) }
    }
}

struct AccountEmptyState: View {
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

struct SettingsStatisticTile: View {
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
                .foregroundStyle(emphasized ? OpenNOWDesign.accent : .white.opacity(0.90))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 14 * uiScale)
        .padding(.vertical, 12 * uiScale)
        .frame(width: (emphasized ? 206 : 164) * uiScale, height: 78 * uiScale, alignment: .leading)
        .background(Color.white.opacity(emphasized ? 0.075 : 0.052))
        .overlay { Rectangle().stroke(emphasized ? OpenNOWDesign.accent.opacity(0.36) : Color.white.opacity(0.08), lineWidth: 1) }
    }
}
