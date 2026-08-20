//
//  CatalogTopBarViews.swift
//  MacForceNow
//

import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

struct CatalogTopBar: View {
    @Bindable var viewModel: CatalogViewModel
    @Binding var showsMainMenu: Bool
    @Binding var showsAccountMenu: Bool
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .center) {
                HStack(alignment: .center, spacing: 14) {
                    Button {
                        showsMainMenu.toggle()
                        showsAccountMenu = false
                    } label: {
                        CatalogHamburgerLabel(isOpen: showsMainMenu)
                    }
                    .frame(width: 44, height: 40)
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsMainMenu ? "Close main menu" : "Open main menu")
                    Text(mainPageTitle)
                        .nvidiaFont(size: 17, weight: .medium)
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(height: 40, alignment: .center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: CatalogVendorLayout.appBarHeight(scale: uiScale), alignment: .leading)
                .padding(.leading, 22)

                if viewModel.selectedMainPage == .games {
                    catalogSearchField
                        .frame(width: CatalogVendorLayout.searchWidth(for: proxy.size.width))
                } else {
                    Text(viewModel.selectedMainPage == .recordings ? "Saved gameplay videos" : viewModel.selectedSettingsGroup.title)
                        .nvidiaFont(size: 15, weight: .bold)
                        .foregroundStyle(.white.opacity(0.70))
                        .tracking(1.1)
                        .frame(width: CatalogVendorLayout.searchWidth(for: proxy.size.width))
                }

                HStack(spacing: 24) {
                    Spacer()
                    Button {
                        showsAccountMenu.toggle()
                        showsMainMenu = false
                    } label: {
                        HStack(spacing: 12) {
                            CatalogAccountAvatar(account: viewModel.account, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(viewModel.account.displayName)
                                    .nvidiaFont(size: 15, weight: .medium)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(viewModel.subscriptionStatus.membershipTier)
                                    .nvidiaFont(size: 12, weight: .medium)
                                    .foregroundStyle(.white.opacity(0.78))
                            }
                            Image(systemName: "chevron.down")
                                .nvidiaFont(size: 10, weight: .bold)
                                .foregroundStyle(.white.opacity(0.88))
                                .rotationEffect(.degrees(showsAccountMenu ? 180 : 0))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open account menu")
                }
                .frame(height: CatalogVendorLayout.appBarHeight(scale: uiScale), alignment: .center)
                .padding(.trailing, 22)
            }
        }
        .frame(height: CatalogVendorLayout.appBarHeight(scale: uiScale))
        .background {
            CatalogVendorLayout.appBarBackground
            WindowDragArea()
        }
    }

    private var mainPageTitle: String {
        switch viewModel.selectedMainPage {
        case .games: return viewModel.selectedCatalogDestination.title
        case .recordings: return "Recordings"
        case .settings: return "Settings"
        }
    }

    private var catalogSearchField: some View {
        let placeholder = viewModel.selectedShowAllSection != nil
            ? "Search titles, genres, publishers, stores, controls, ratings, or tags"
            : "Search games, stores, or genres"
        return HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .nvidiaFont(size: 18, weight: .medium)
                .foregroundStyle(.white.opacity(0.76))
            TextField(placeholder, text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .nvidiaFont(size: 16, weight: .medium)
                .foregroundStyle(.white)
                .onSubmit { viewModel.browseCatalog() }
                .onChange(of: viewModel.searchQuery) { _, newValue in
                    if !newValue.trimmed.isEmpty, viewModel.selectedShowAllSection == nil {
                        viewModel.openBrowseFromSearch()
                    }
                }
            if !viewModel.searchQuery.isEmpty {
                Button { viewModel.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.52))
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
        .background(MacForceNowDesign.Surface.field)
        .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
    }
}

struct CatalogAccountAvatar: View {
    let account: LoginAccount
    let size: CGFloat

    private var gravatarURL: URL? {
        let normalizedEmail = account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

struct CatalogHamburgerLabel: View {
    let isOpen: Bool
    @State private var isHovering = false

    var body: some View {
        ZStack {
            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Rectangle()
                        .fill((isOpen || isHovering) ? MacForceNowDesign.accent : Color.white.opacity(0.84))
                        .frame(width: index == 1 ? 20 : 23, height: 2)
                }
            }
        }
        .frame(width: 44, height: 40)
        .background((isOpen || isHovering) ? Color.black.opacity(0.22) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill((isOpen || isHovering) ? MacForceNowDesign.accent : Color.clear)
                .frame(height: 3)
        }
        .onHover { isHovering = $0 }
        .accessibilityLabel("Main menu")
    }
}
