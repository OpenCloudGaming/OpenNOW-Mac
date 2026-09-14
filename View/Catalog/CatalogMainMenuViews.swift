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
    let onSignOut: (LoginAccount) -> Void
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Presentation is decided here rather than by an `if` at the call site so the scrim
                // and the panel can carry separate transitions. A conditional ancestor animates as
                // one block: the dimming would slide in with the drawer.
                if isPresented {
                    OPNDesign.Surface.scrim
                        .ignoresSafeArea()
                        .onTapGesture { isPresented = false }
                        .transition(.opacity)

                    // The transition is attached before the padding on purpose. `.move` travels by
                    // the frame of the view it is attached to, so outside the padding the panel
                    // would start a full window width away instead of just off its own edge.
                    CatalogMainMenuPanel(viewModel: viewModel, isPresented: $isPresented, onSignOut: onSignOut, availableHeight: max(360, proxy.size.height - CatalogVendorLayout.appBarHeight(scale: uiScale) - topInset))
                        .opnTransition(.move(edge: .leading).combined(with: .opacity))
                        .padding(.top, CatalogVendorLayout.appBarHeight(scale: uiScale) + topInset)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .opnMotion(OPNDesign.Motion.panel, value: isPresented)
        // Closed, this is an empty ZStack with nothing to hit; the guard is belt and braces so a
        // permanently mounted full-window overlay can never steal hover from the rails below it.
        .allowsHitTesting(isPresented)
        // Nil while closed: this view stays mounted to own the transition, and a permanently
        // installed handler would eat Escape from whatever is actually on screen.
        .onExitCommand(perform: isPresented ? { isPresented = false } : nil)
    }
}

struct CatalogMainMenuPanel: View {
    let viewModel: CatalogViewModel
    @Binding var isPresented: Bool
    let onSignOut: (LoginAccount) -> Void
    let availableHeight: CGFloat
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("GEFORCE NOW")
                    .catalogFont(size: 11, weight: .bold)
                    .tracking(1.4)
                    .foregroundStyle(OPNDesign.accentInk)
                Text("OpenNOW Menu")
                    .catalogFont(size: 20, weight: .bold)
                    .foregroundStyle(OPNDesign.Text.primary)
            }
            .padding(.horizontal, 22 * uiScale)
            .padding(.top, OPNDesign.Spacing.large(scale: uiScale))
            .padding(.bottom, OPNDesign.Spacing.card(scale: uiScale))

            Rectangle()
                .fill(OPNDesign.Stroke.subtle)
                .frame(height: 1)

            CatalogMainMenuPlaytimeCard(status: viewModel.subscriptionStatus, activeStreamProgress: viewModel.activeStreamProgress)
                .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
                .padding(.vertical, OPNDesign.Spacing.contentVertical(scale: uiScale))

            Rectangle()
                .fill(OPNDesign.Stroke.subtle)
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
                    .padding(.horizontal, OPNDesign.Spacing.section(scale: uiScale))
                    .padding(.top, OPNDesign.Spacing.contentVertical(scale: uiScale))

                    VStack(alignment: .leading, spacing: 6 * uiScale) {
                        CatalogMainMenuSectionLabel("ACTIONS")
                        CatalogMainMenuRow(title: viewModel.isCatalogRefreshInProgress ? "Refreshing Catalog" : "Refresh Catalog", subtitle: viewModel.isCatalogRefreshInProgress ? "Fetching latest panels and game metadata" : "Fetch latest panels and game metadata", systemImage: "arrow.clockwise", isActive: false, isLoading: viewModel.isCatalogRefreshInProgress) {
                            viewModel.refresh()
                        }
                        if viewModel.selectedMainPage == .games, viewModel.isBrowseMode {
                            CatalogMainMenuRow(title: "Clear Search and Filters", subtitle: "Return to the default catalog view", systemImage: "line.3.horizontal.decrease.circle", isActive: false) {
                                viewModel.clearSearch()
                                viewModel.clearFilters()
                                viewModel.browseCatalog()
                                isPresented = false
                            }
                        }
                    }
                    .padding(.horizontal, OPNDesign.Spacing.section(scale: uiScale))
                    .padding(.top, OPNDesign.Spacing.contentVertical(scale: uiScale))
                    .padding(.bottom, OPNDesign.Spacing.card(scale: uiScale))
                }
            }

            Rectangle()
                .fill(OPNDesign.Stroke.subtle)
                .frame(height: 1)

            CatalogMainMenuRow(title: "Sign Out", subtitle: viewModel.account.displayName, systemImage: "rectangle.portrait.and.arrow.right", isActive: false) {
                isPresented = false
                onSignOut(viewModel.account)
            }
            .padding(.horizontal, OPNDesign.Spacing.section(scale: uiScale))
            .padding(.vertical, OPNDesign.Spacing.small(scale: uiScale))
        }
        .frame(width: CatalogVendorLayout.mainMenuWidth(scale: uiScale), height: availableHeight, alignment: .topLeading)
        .background(OPNDesign.Surface.overlay.opacity(0.985))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(OPNDesign.Stroke.subtle)
                .frame(width: 1)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OPNDesign.accent)
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

struct CatalogMainMenuSectionLabel: View {
    let title: String

    @Environment(\.opnUIScale) private var uiScale

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .catalogFont(size: 10, weight: .bold)
            .tracking(1.1)
            .foregroundStyle(OPNDesign.Text.muted)
            .padding(.horizontal, OPNDesign.Spacing.small(scale: uiScale))
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
            VStack(alignment: .leading, spacing: OPNDesign.Spacing.section(scale: uiScale)) {
                HStack(alignment: .firstTextBaseline) {
                    Text(activeSession == nil ? "REMAINING PLAYTIME" : "CURRENT SESSION")
                        .catalogFont(size: 10, weight: .bold)
                        .tracking(1.1)
                        .foregroundStyle(OPNDesign.Text.tertiary)
                    Spacer(minLength: 0)
                    Text(status.membershipTier.uppercased())
                        .catalogFont(size: 10, weight: .bold)
                        .tracking(0.6)
                        .foregroundStyle(.black.opacity(0.86))
                        .padding(.horizontal, OPNDesign.Spacing.xSmall(scale: uiScale))
                        .frame(height: OPNDesign.Spacing.large(scale: uiScale))
                        .background(OPNDesign.accent)
                }
                Text(activeSession?.remainingText ?? status.remainingPlaytimeText)
                    .catalogFont(size: 22, weight: .bold)
                    .foregroundStyle((activeSession != nil || status.isAvailable) ? OPNDesign.Text.primary : OPNDesign.Text.tertiary)
                    .lineLimit(1)
                Text(activeSession?.usageText ?? status.usageText)
                    .catalogFont(size: 11, weight: .medium)
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .lineLimit(1)
            }
            .padding(OPNDesign.Spacing.contentVertical(scale: uiScale))
            .background(OPNDesign.Fill.neutral(0.055))
            .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
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
                        .fill(isActive ? OPNDesign.accent : OPNDesign.Fill.neutral(isHovering ? 0.16 : 0.08))
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(iconColor)
                            .scaleEffect((compact ? 0.72 : 0.82) * uiScale)
                    } else {
                        Image(systemName: systemImage)
                            .catalogFont(size: compact ? 12 : 14, weight: .bold)
                            .foregroundStyle(iconColor)
                    }
                }
                .frame(width: (compact ? 28 : 34) * uiScale, height: (compact ? 28 : 34) * uiScale)

                VStack(alignment: .leading, spacing: 2 * uiScale) {
                    Text(title)
                        .catalogFont(size: compact ? 12 : 14, weight: .bold)
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .catalogFont(size: 11, weight: .medium)
                            .foregroundStyle(OPNDesign.Text.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, OPNDesign.Spacing.xSmall(scale: uiScale))
            .padding(.trailing, OPNDesign.Spacing.controlRow(scale: uiScale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: (compact ? 38 : 50) * uiScale)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isActive ? OPNDesign.accent : Color.clear)
                    .frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.opnPressable)
        .disabled(isLoading)
        .onHover { isHovering = $0 }
        .opnMotion(OPNDesign.Motion.hover, value: isHovering)
        .accessibilityLabel(title)
    }

    private var rowBackground: Color {
        if isActive { return OPNDesign.accent.opacity(0.095) }
        return OPNDesign.Fill.neutral(isHovering ? 0.085 : 0)
    }

    private var titleColor: Color {
        if role == .destructive { return OPNDesign.Semantic.destructive }
        return isActive ? OPNDesign.Text.primary : OPNDesign.Fill.neutral(isHovering ? 0.96 : 0.82)
    }

    private var iconColor: Color {
        if isActive { return .black.opacity(0.86) }
        if role == .destructive { return OPNDesign.Semantic.destructive }
        return isHovering ? OPNDesign.Text.primary : OPNDesign.Text.secondary
    }
}
