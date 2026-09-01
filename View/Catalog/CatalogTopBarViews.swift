//
//  CatalogTopBarViews.swift
//  OpenNOW
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
    @Environment(\.openWindow) private var openWindow
    @AppStorage(OpenNOWInterfacePreferences.controllerModeEnabledKey) private var controllerModeEnabled = false

    /// The collapsed button and the expanded field are one element to SwiftUI, so the trip between
    /// the trailing icon row and the centre of the bar is a single interpolated frame change
    /// rather than a fade between two separately positioned views.
    @Namespace private var searchTransition
    @State private var isSearchExpanded = false
    @FocusState private var isSearchFieldFocused: Bool

    private static let searchGeometryID = "catalog-top-bar-search"
    private static let searchTransitionAnimation = Animation.spring(response: 0.36, dampingFraction: 0.86)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .center) {
                HStack(alignment: .center, spacing: 14 * uiScale) {
                    Button {
                        showsMainMenu.toggle()
                        showsAccountMenu = false
                    } label: {
                        CatalogHamburgerLabel(isOpen: showsMainMenu)
                    }
                    .frame(width: 44 * uiScale, height: 40 * uiScale)
                    .buttonStyle(.opnPressable(scale: 0.90))
                    .accessibilityLabel(showsMainMenu ? "Close main menu" : "Open main menu")
                    Text(mainPageTitle)
                        .nvidiaFont(size: 17, weight: .medium)
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(height: 40 * uiScale, alignment: .center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: CatalogVendorLayout.appBarHeight(scale: uiScale), alignment: .leading)
                .padding(.leading, 22 * uiScale)

                if viewModel.selectedMainPage == .games {
                    if isSearchExpanded {
                        catalogSearchField
                            .frame(width: CatalogVendorLayout.searchWidth(for: proxy.size.width))
                            .matchedGeometryEffect(id: Self.searchGeometryID, in: searchTransition)
                    }
                } else {
                    Text(viewModel.selectedMainPage == .recordings ? "Saved gameplay videos" : viewModel.selectedSettingsGroup.title)
                        .nvidiaFont(size: 15, weight: .bold)
                        .foregroundStyle(.white.opacity(0.70))
                        .tracking(1.1)
                        .frame(width: CatalogVendorLayout.searchWidth(for: proxy.size.width))
                }

                HStack(spacing: 24 * uiScale) {
                    Spacer()
                    HStack(spacing: 4 * uiScale) {
                        if viewModel.selectedMainPage == .games, !isSearchExpanded {
                            Button { setSearchExpanded(true) } label: {
                                CatalogTopBarIconLabel(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.opnPressable(scale: 0.90))
                            .accessibilityLabel("Search games")
                            .matchedGeometryEffect(id: Self.searchGeometryID, in: searchTransition)
                        }
                        Button { controllerModeEnabled = true } label: {
                            CatalogTopBarIconLabel(systemName: "gamecontroller")
                        }
                        .buttonStyle(.opnPressable(scale: 0.90))
                        .accessibilityLabel("Switch to controller mode")
                        .help("Controller mode")
                        // Joining someone else's session is a thing you do *instead* of browsing your
                        // own library, so it belongs where you already are rather than only in a menu.
                        // Hidden unless Remote Co-Op is on, since it is alpha-gated.
                        if viewModel.remoteCoOpPreferences.isAvailable {
                            Button { openWindow(id: "remote-coop-guest") } label: {
                                CatalogTopBarIconLabel(systemName: "person.2")
                            }
                            .buttonStyle(.opnPressable(scale: 0.90))
                            .accessibilityLabel("Join a Remote Co-Op session")
                            .help("Join Remote Co-Op")
                        }
                    }
                    Button {
                        showsAccountMenu.toggle()
                        showsMainMenu = false
                    } label: {
                        HStack(spacing: 12 * uiScale) {
                            CatalogAccountAvatar(account: viewModel.account, size: 32 * uiScale)
                            VStack(alignment: .leading, spacing: 1 * uiScale) {
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
                                .opnMotion(OpenNOWDesign.Motion.toggle, value: showsAccountMenu)
                        }
                    }
                    .buttonStyle(.opnPressable(scale: 0.97))
                    .accessibilityLabel("Open account menu")
                }
                .frame(height: CatalogVendorLayout.appBarHeight(scale: uiScale), alignment: .center)
                .padding(.trailing, 22 * uiScale)
            }
        }
        .frame(height: CatalogVendorLayout.appBarHeight(scale: uiScale))
        .background {
            CatalogVendorLayout.appBarBackground
            WindowDragArea()
        }
        // An active query has to stay visible - the field is the only place it can be read or
        // edited, so a browse restored from state opens expanded rather than hiding itself
        // behind an icon.
        .onAppear { if hasActiveSearchQuery { isSearchExpanded = true } }
        .onChange(of: hasActiveSearchQuery) { _, hasQuery in
            if hasQuery, !isSearchExpanded { setSearchExpanded(true) }
        }
        .onChange(of: viewModel.selectedMainPage) { _, _ in
            if !hasActiveSearchQuery { setSearchExpanded(false) }
        }
        .onChange(of: isSearchFieldFocused) { _, isFocused in
            guard !isFocused, !hasActiveSearchQuery else { return }
            setSearchExpanded(false)
        }
        .opnTakingFocus($isSearchFieldFocused, while: isSearchExpanded)
    }

    private var hasActiveSearchQuery: Bool { !viewModel.searchQuery.trimmed.isEmpty }

    private func setSearchExpanded(_ expanded: Bool) {
        guard isSearchExpanded != expanded else { return }
        withAnimation(Self.searchTransitionAnimation) { isSearchExpanded = expanded }
        if !expanded { isSearchFieldFocused = false }
    }

    private var mainPageTitle: String {
        switch viewModel.selectedMainPage {
        case .games: return viewModel.selectedCatalogDestination.title
        case .recordings: return "Recordings"
        case .settings: return "Settings"
        }
    }

    private var catalogSearchField: some View {
        HStack(spacing: 14 * uiScale) {
            Image(systemName: "magnifyingglass")
                .nvidiaFont(size: 18, weight: .medium)
                .foregroundStyle(.white.opacity(0.76))
            TextField("Search", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .nvidiaFont(size: 16, weight: .medium)
                .foregroundStyle(.white)
                .focused($isSearchFieldFocused)
                .onSubmit { viewModel.browseCatalog() }
                .onChange(of: viewModel.searchQuery) { _, newValue in
                    if !newValue.trimmed.isEmpty, viewModel.selectedShowAllSection == nil {
                        viewModel.openBrowseFromSearch()
                    }
                }
            Button {
                if hasActiveSearchQuery {
                    viewModel.searchQuery = ""
                } else {
                    setSearchExpanded(false)
                }
            } label: {
                Image(systemName: hasActiveSearchQuery ? "xmark.circle.fill" : "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.52))
            .accessibilityLabel(hasActiveSearchQuery ? "Clear search" : "Close search")
        }
        .padding(.horizontal, 18 * uiScale)
        .frame(height: 46 * uiScale)
        .background(OpenNOWDesign.Surface.field)
        .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
        .onExitCommand { setSearchExpanded(false) }
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

/// The plate every top-bar control sits on: fixed size, dark tint and a 3pt accent underline when
/// active. Shared so the bar reads as one row of controls and its metrics exist once.
private struct CatalogTopBarPlate: ViewModifier {
    let isActive: Bool
    @Environment(\.opnUIScale) private var uiScale

    func body(content: Content) -> some View {
        content
            .frame(width: 44 * uiScale, height: 40 * uiScale)
            .background(isActive ? Color.black.opacity(0.22) : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? OpenNOWDesign.accent : Color.clear)
                    .frame(height: 3)
            }
            .contentShape(Rectangle())
    }
}

/// Square icon control for the top bar's trailing row.
struct CatalogTopBarIconLabel: View {
    let systemName: String
    @State private var isHovering = false

    var body: some View {
        Image(systemName: systemName)
            .nvidiaFont(size: 17, weight: .medium)
            .foregroundStyle(isHovering ? OpenNOWDesign.accent : Color.white.opacity(0.84))
            .modifier(CatalogTopBarPlate(isActive: isHovering))
            .onHover { isHovering = $0 }
            .opnMotion(OpenNOWDesign.Motion.hover, value: isHovering)
    }
}

struct CatalogHamburgerLabel: View {
    let isOpen: Bool
    @State private var isHovering = false
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        ZStack {
            VStack(spacing: 4 * uiScale) {
                ForEach(0..<3, id: \.self) { index in
                    Rectangle()
                        .fill((isOpen || isHovering) ? OpenNOWDesign.accent : Color.white.opacity(0.84))
                        .frame(width: (index == 1 ? 20 : 23) * uiScale, height: 2)
                        // Folds into a close cross while the drawer is open, so the button says
                        // what the click will do instead of only recolouring.
                        .opacity(isOpen && index == 1 ? 0 : 1)
                        .rotationEffect(.degrees(isOpen ? barRotation(index: index) : 0))
                        .offset(y: isOpen ? barOffset(index: index) : 0)
                }
            }
        }
        .modifier(CatalogTopBarPlate(isActive: isOpen || isHovering))
        .onHover { isHovering = $0 }
        .opnMotion(OpenNOWDesign.Motion.hover, value: isHovering)
        .opnMotion(OpenNOWDesign.Motion.toggle, value: isOpen)
        .accessibilityLabel("Main menu")
    }

    /// The outer bars meet in the middle: 2pt bar, 4pt gap, so each travels one bar plus one gap.
    private func barOffset(index: Int) -> CGFloat {
        switch index {
        case 0: return 6 * uiScale
        case 2: return -6 * uiScale
        default: return 0
        }
    }

    private func barRotation(index: Int) -> Double {
        switch index {
        case 0: return 45
        case 2: return -45
        default: return 0
        }
    }
}
