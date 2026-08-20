//
//  CatalogMainMenuViews.swift
//  MacForceNow
//

import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

struct CatalogMainMenuOverlay: View {
    let viewModel: CatalogViewModel
    @Binding var isPresented: Bool
    let topInset: CGFloat
    let onSignOut: () -> Void
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture { isPresented = false }

                CatalogMainMenuPanel(viewModel: viewModel, isPresented: $isPresented, onSignOut: onSignOut, availableHeight: max(360, proxy.size.height - CatalogVendorLayout.appBarHeight(scale: uiScale) - topInset))
                    .padding(.top, CatalogVendorLayout.appBarHeight(scale: uiScale) + topInset)
                    .padding(.leading, 0)
            }
        }
        .onExitCommand { isPresented = false }
    }
}

struct CatalogMainMenuPanel: View {
    let viewModel: CatalogViewModel
    @Binding var isPresented: Bool
    let onSignOut: () -> Void
    let availableHeight: CGFloat
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("GEFORCE NOW")
                    .nvidiaFont(size: 11, weight: .bold)
                    .tracking(1.4)
                    .foregroundStyle(Color.openNowGreen)
                Text("MacForce Now Menu")
                    .nvidiaFont(size: 20, weight: .bold)
                    .foregroundStyle(.white.opacity(0.96))
            }
            .padding(.horizontal, 22 * uiScale)
            .padding(.top, MacForceNowDesign.Spacing.large(scale: uiScale))
            .padding(.bottom, MacForceNowDesign.Spacing.card(scale: uiScale))

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)

            CatalogMainMenuPlaytimeCard(status: viewModel.subscriptionStatus, activeStreamProgress: viewModel.activeStreamProgress)
                .padding(.horizontal, MacForceNowDesign.Spacing.card(scale: uiScale))
                .padding(.vertical, MacForceNowDesign.Spacing.contentVertical(scale: uiScale))

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6 * uiScale) {
                        CatalogMainMenuSectionLabel("NAVIGATION")
                        CatalogMainMenuRow(
                            title: CatalogDestination.home.title,
                            subtitle: catalogDestinationSubtitle(.home),
                            systemImage: catalogDestinationIcon(.home),
                            isActive: viewModel.selectedMainPage == .games && viewModel.selectedCatalogDestination == .home
                        ) {
                            viewModel.showCatalogDestination(.home)
                            isPresented = false
                        }
                        CatalogMainMenuRow(title: "Recordings", subtitle: "Watch saved stream videos", systemImage: "play.rectangle.fill", isActive: viewModel.selectedMainPage == .recordings) {
                            viewModel.showRecordings()
                            isPresented = false
                        }
                        CatalogMainMenuRow(title: "Settings", subtitle: "Streaming, account, and system options", systemImage: "gearshape.fill", isActive: viewModel.selectedMainPage == .settings) {
                            viewModel.showSettings()
                            isPresented = false
                        }
                    }
                    .padding(.horizontal, MacForceNowDesign.Spacing.section(scale: uiScale))
                    .padding(.top, MacForceNowDesign.Spacing.contentVertical(scale: uiScale))

                    VStack(alignment: .leading, spacing: 6 * uiScale) {
                        CatalogMainMenuSectionLabel("ACTIONS")
                        CatalogMainMenuRow(title: viewModel.isCatalogRefreshInProgress ? "Refreshing Catalog" : "Refresh Catalog", subtitle: viewModel.isCatalogRefreshInProgress ? "Fetching latest panels and game metadata" : "Fetch latest panels and game metadata", systemImage: "arrow.clockwise", isActive: false, isLoading: viewModel.isCatalogRefreshInProgress) {
                            viewModel.refresh()
                        }
                        if viewModel.selectedMainPage == .games, viewModel.isBrowseMode {
                            CatalogMainMenuRow(title: "Clear Search and Filters", subtitle: "Return to the default catalog view", systemImage: "line.3.horizontal.decrease.circle", isActive: false) {
                                viewModel.clearSearchAndFilters()
                                isPresented = false
                            }
                        }
                    }
                    .padding(.horizontal, MacForceNowDesign.Spacing.section(scale: uiScale))
                    .padding(.top, MacForceNowDesign.Spacing.contentVertical(scale: uiScale))
                    .padding(.bottom, MacForceNowDesign.Spacing.card(scale: uiScale))
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)

            CatalogMainMenuRow(title: "Sign Out", subtitle: viewModel.account.displayName, systemImage: "rectangle.portrait.and.arrow.right", isActive: false, role: .destructive) {
                isPresented = false
                onSignOut()
            }
            .padding(.horizontal, MacForceNowDesign.Spacing.section(scale: uiScale))
            .padding(.vertical, MacForceNowDesign.Spacing.small(scale: uiScale))
        }
        .frame(width: CatalogVendorLayout.mainMenuWidth(scale: uiScale), height: availableHeight, alignment: .topLeading)
        .background(Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255).opacity(0.985))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.openNowGreen)
                .frame(height: 2)
        }
        .shadow(color: .black.opacity(0.58), radius: 28, x: 14, y: 20)
    }

    private func catalogDestinationIcon(_ destination: CatalogDestination) -> String {
        switch destination {
        case .home: return "gamecontroller.fill"
        case .library: return "rectangle.stack.fill"
        case .favorites: return "heart.fill"
        }
    }

    private func catalogDestinationSubtitle(_ destination: CatalogDestination) -> String {
        switch destination {
        case .home: return "Browse and launch cloud games"
        case .library: return "Games synced from connected stores"
        case .favorites: return "Saved games for quick access"
        }
    }
}

struct CatalogAccountDropdownOverlay: View {
    let viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    @Binding var isPresented: Bool
    let topInset: CGFloat
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }

                CatalogAccountDropdownPanel(viewModel: viewModel, accounts: accounts, isPresented: $isPresented, onSwitch: onSwitch, onSignOut: onSignOut, onForget: onForget)
                    .padding(.top, CatalogVendorLayout.appBarHeight(scale: uiScale) + topInset)
                    .padding(.trailing, 22)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onExitCommand { isPresented = false }
    }
}

struct CatalogAccountDropdownPanel: View {
    let viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    @Binding var isPresented: Bool
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: MacForceNowDesign.Spacing.small(scale: uiScale)) {
                CatalogAccountAvatar(account: viewModel.account, size: 44 * uiScale)
                VStack(alignment: .leading, spacing: 3 * uiScale) {
                    Text(viewModel.account.displayName)
                        .nvidiaFont(size: 15, weight: .medium)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(viewModel.subscriptionStatus.membershipTier.uppercased())
                        .nvidiaFont(size: 10, weight: .bold)
                        .tracking(0.6)
                        .foregroundStyle(.black.opacity(0.86))
                        .padding(.horizontal, MacForceNowDesign.Spacing.xSmall(scale: uiScale))
                        .frame(height: MacForceNowDesign.Spacing.card(scale: uiScale))
                        .background(Color.openNowGreen)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MacForceNowDesign.Spacing.contentVertical(scale: uiScale))
            .padding(.vertical, MacForceNowDesign.Spacing.contentVertical(scale: uiScale))

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: MacForceNowDesign.Spacing.xxSmall(scale: uiScale)) {
                Text("ACCOUNTS")
                    .nvidiaFont(size: 10, weight: .bold)
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.horizontal, MacForceNowDesign.Spacing.small(scale: uiScale))
                    .padding(.vertical, 5 * uiScale)
                ForEach(accounts) { account in
                    let isActive = account === viewModel.account
                    CatalogAccountDropdownRow(
                        title: account.displayName,
                        subtitle: nil,
                        systemImage: isActive ? "checkmark" : "person",
                        isActive: isActive,
                        role: nil
                    ) {
                        isPresented = false
                        if !isActive {
                            onSwitch(account)
                        }
                    }
                }
            }
            .padding(.horizontal, MacForceNowDesign.Spacing.section(scale: uiScale))
            .padding(.top, MacForceNowDesign.Spacing.section(scale: uiScale))
            .padding(.bottom, MacForceNowDesign.Spacing.small(scale: uiScale))

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: MacForceNowDesign.Spacing.xxSmall(scale: uiScale)) {
                CatalogAccountDropdownRow(
                    title: "Sign Out",
                    subtitle: nil,
                    systemImage: "rectangle.portrait.and.arrow.right",
                    isActive: false,
                    role: nil
                ) {
                    isPresented = false
                    onSignOut()
                }
                ForEach(accounts) { account in
                    CatalogAccountDropdownRow(
                        title: "Forget \(account.displayName)",
                        subtitle: nil,
                        systemImage: "xmark.circle",
                        isActive: false,
                        role: .destructive
                    ) {
                        isPresented = false
                        onForget(account)
                    }
                }
            }
            .padding(.horizontal, MacForceNowDesign.Spacing.section(scale: uiScale))
            .padding(.vertical, MacForceNowDesign.Spacing.small(scale: uiScale))
        }
        .frame(width: CatalogVendorLayout.accountMenuWidth(scale: uiScale), alignment: .topLeading)
        .background(Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255).opacity(0.985))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.openNowGreen)
                .frame(height: 2)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.58), radius: 28, x: 14, y: 20)
    }
}

struct CatalogAccountDropdownRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let isActive: Bool
    let role: ButtonRole?
    let action: () -> Void
    @Environment(\.opnUIScale) private var uiScale
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: MacForceNowDesign.Spacing.small(scale: uiScale)) {
                if let systemImage {
                    ZStack {
                        Rectangle()
                            .fill(isActive ? Color.openNowGreen : Color.white.opacity(isHovering ? 0.16 : 0.08))
                        Image(systemName: systemImage)
                            .nvidiaFont(size: 13, weight: .bold)
                            .foregroundStyle(iconColor)
                    }
                    .frame(width: 30 * uiScale, height: 30 * uiScale)
                }
                VStack(alignment: .leading, spacing: 2 * uiScale) {
                    Text(title)
                        .nvidiaFont(size: 14, weight: .bold)
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .nvidiaFont(size: 11, weight: .medium)
                            .foregroundStyle(.white.opacity(0.52))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, MacForceNowDesign.Spacing.xSmall(scale: uiScale))
            .padding(.trailing, MacForceNowDesign.Spacing.controlRow(scale: uiScale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 42 * uiScale)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }

    private var rowBackground: Color {
        if isActive { return Color.openNowGreen.opacity(0.095) }
        return Color.white.opacity(isHovering ? 0.085 : 0)
    }

    private var titleColor: Color {
        if role == .destructive { return Color(red: 1, green: 0.54, blue: 0.50) }
        return isActive ? .white : .white.opacity(isHovering ? 0.96 : 0.82)
    }

    private var iconColor: Color {
        if role == .destructive { return Color(red: 1, green: 0.54, blue: 0.50) }
        return isActive ? .black : .white.opacity(isHovering ? 0.96 : 0.82)
    }
}

struct CatalogMainMenuSectionLabel: View {
    let title: String

    @Environment(\.opnUIScale) private var uiScale

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .nvidiaFont(size: 10, weight: .bold)
            .tracking(1.1)
            .foregroundStyle(.white.opacity(0.42))
            .padding(.horizontal, MacForceNowDesign.Spacing.small(scale: uiScale))
            .padding(.vertical, 5 * uiScale)
    }
}

struct CatalogMainMenuPlaytimeCard: View {
    let status: CatalogSubscriptionStatus
    let activeStreamProgress: StreamProgress?

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let activeSession = activeSessionTime(at: context.date)
            VStack(alignment: .leading, spacing: MacForceNowDesign.Spacing.section(scale: uiScale)) {
                HStack(alignment: .firstTextBaseline) {
                    Text(activeSession == nil ? "REMAINING PLAYTIME" : "CURRENT SESSION")
                        .nvidiaFont(size: 10, weight: .bold)
                        .tracking(1.1)
                        .foregroundStyle(.white.opacity(0.46))
                    Spacer(minLength: 0)
                    Text(status.membershipTier.uppercased())
                        .nvidiaFont(size: 10, weight: .bold)
                        .tracking(0.6)
                        .foregroundStyle(.black.opacity(0.86))
                        .padding(.horizontal, MacForceNowDesign.Spacing.xSmall(scale: uiScale))
                        .frame(height: MacForceNowDesign.Spacing.large(scale: uiScale))
                        .background(Color.openNowGreen)
                }
                Text(activeSession?.remainingText ?? status.remainingPlaytimeText)
                    .nvidiaFont(size: 22, weight: .bold)
                    .foregroundStyle((activeSession != nil || status.isAvailable) ? .white.opacity(0.95) : .white.opacity(0.56))
                    .lineLimit(1)
                Text(activeSession?.usageText ?? status.usageText)
                    .nvidiaFont(size: 11, weight: .medium)
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
            }
            .padding(MacForceNowDesign.Spacing.contentVertical(scale: uiScale))
            .background(Color.white.opacity(0.055))
            .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
        }
    }

    private func activeSessionTime(at date: Date) -> (remainingText: String, usageText: String)? {
        guard let progress = activeStreamProgress,
              let startedAtEpoch = progress.sessionLimitStartedAtEpochSeconds,
              let limitSeconds = progress.sessionLimitSeconds,
              limitSeconds > 0 else { return nil }
        let elapsedSeconds = max(0, Int(date.timeIntervalSince1970 - startedAtEpoch))
        let remainingSeconds = max(0, limitSeconds - elapsedSeconds)
        return (
            CatalogSubscriptionStatus.durationText(seconds: remainingSeconds),
            "Server session limit for this stream"
        )
    }
}

extension CatalogSubscriptionStatus {
    static func durationText(seconds: Int) -> String {
        let totalSeconds = max(0, seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        return String(format: "%dm %02ds", minutes, seconds)
    }
}

struct CatalogMainMenuRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isActive: Bool
    var isLoading = false
    var compact = false
    var role: ButtonRole?
    let action: () -> Void
    @Environment(\.opnUIScale) private var uiScale
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13 * uiScale) {
                ZStack {
                    Rectangle()
                        .fill(isActive ? Color.openNowGreen : Color.white.opacity(isHovering ? 0.16 : 0.08))
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(iconColor)
                            .scaleEffect((compact ? 0.72 : 0.82) * uiScale)
                    } else {
                        Image(systemName: systemImage)
                            .nvidiaFont(size: compact ? 12 : 14, weight: .bold)
                            .foregroundStyle(iconColor)
                    }
                }
                .frame(width: (compact ? 28 : 34) * uiScale, height: (compact ? 28 : 34) * uiScale)

                VStack(alignment: .leading, spacing: 2 * uiScale) {
                    Text(title)
                        .nvidiaFont(size: compact ? 12 : 14, weight: .bold)
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .nvidiaFont(size: 11, weight: .medium)
                            .foregroundStyle(.white.opacity(0.52))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, MacForceNowDesign.Spacing.xSmall(scale: uiScale))
            .padding(.trailing, MacForceNowDesign.Spacing.controlRow(scale: uiScale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: (compact ? 38 : 50) * uiScale)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isActive ? Color.openNowGreen : Color.clear)
                    .frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }

    private var rowBackground: Color {
        if isActive { return Color.openNowGreen.opacity(0.095) }
        return Color.white.opacity(isHovering ? 0.085 : 0)
    }

    private var titleColor: Color {
        if role == .destructive { return Color(red: 1, green: 0.54, blue: 0.50) }
        return isActive ? .white : .white.opacity(isHovering ? 0.96 : 0.82)
    }

    private var iconColor: Color {
        if isActive { return .black.opacity(0.86) }
        if role == .destructive { return Color(red: 1, green: 0.54, blue: 0.50) }
        return .white.opacity(isHovering ? 0.94 : 0.72)
    }
}
