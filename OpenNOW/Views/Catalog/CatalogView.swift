//  CatalogView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import Backend
import Combine
import Common
import CoreText
import ImageIO
import SwiftUI

private enum CatalogVendorLayout {
    static let appBarHeight: CGFloat = 56
    static let appBarBackground = Color(red: 57 / 255, green: 57 / 255, blue: 57 / 255)
    static let mallSurface = Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255)
    static let tileTray = Color(red: 41 / 255, green: 41 / 255, blue: 41 / 255)
    static let sectionHeaderMargin: CGFloat = 40
    static let carouselContainerMargin: CGFloat = 32
    static let tileHorizontalMargin: CGFloat = 8
    static let tileTopMargin: CGFloat = 16
    static let cardTrayHeight: CGFloat = 40
    static let wideTileWidth: CGFloat = 272
    static let wideTileHeight: CGFloat = 153
    static let tileScaleFactor: CGFloat = 1.12
    static let heroAspectRatio: CGFloat = 0.3229
    static let heroFallbackHeight: CGFloat = 500
    static let detailPanelHeight: CGFloat = 548

    static func heroHeight(for width: CGFloat) -> CGFloat {
        width > 0 ? width * heroAspectRatio : heroFallbackHeight
    }

    static func heroImageLeading(for width: CGFloat) -> CGFloat {
        width > 0 ? 56 + width * 0.14 : 258
    }
}

private enum CatalogVendorFont {
    enum Weight: Hashable {
        case regular
        case medium
        case bold
    }

    static func font(size: CGFloat, weight: Weight = .regular) -> Font {
        Font(nsFont(size: size, weight: weight))
    }

    private static func nsFont(size: CGFloat, weight: Weight) -> NSFont {
        if let descriptor = descriptor(weight: weight) {
            return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
        }
        return NSFont.systemFont(ofSize: size, weight: fallbackWeight(weight))
    }

    private static func fallbackWeight(_ weight: Weight) -> NSFont.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .bold: return .bold
        }
    }

    private static func descriptor(weight: Weight) -> CTFontDescriptor? {
        descriptors[weight] ?? nil
    }

    private static let descriptors: [Weight: CTFontDescriptor?] = [
        .regular: loadDescriptor(named: "NVIDIASans_W_Rg"),
        .medium: loadDescriptor(named: "NVIDIASans_W_Md"),
        .bold: loadDescriptor(named: "NVIDIASans_W_Bd")
    ]

    private static func loadDescriptor(named name: String) -> CTFontDescriptor? {
        for subdirectory in ["NVIDIA", "Resources/NVIDIA", nil] as [String?] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "woff2", subdirectory: subdirectory),
                  let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let descriptor = descriptors.first else { continue }
            return descriptor
        }
        return nil
    }
}

private extension Font {
    static func nvidia(size: CGFloat, weight: CatalogVendorFont.Weight = .regular) -> Font {
        CatalogVendorFont.font(size: size, weight: weight)
    }
}

struct CatalogView: View {
    let accounts: [LoginAccount]
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void
    let onRefreshAuth: () -> Void

    @StateObject private var viewModel: CatalogViewModel
    @State private var showsMainMenu = false
    @State private var showsPreviousSessionOverlay = false

    init(
        account: LoginAccount,
        session: LoginSession,
        accounts: [LoginAccount],
        onSwitch: @escaping (LoginAccount) -> Void,
        onSignOut: @escaping () -> Void,
        onForget: @escaping (LoginAccount) -> Void,
        onRefreshAuth: @escaping () -> Void
    ) {
        self.accounts = accounts
        self.onSwitch = onSwitch
        self.onSignOut = onSignOut
        self.onForget = onForget
        self.onRefreshAuth = onRefreshAuth
        _viewModel = StateObject(wrappedValue: CatalogViewModel(account: account, session: session, onRefreshAuth: onRefreshAuth))
    }

    var body: some View {
        ZStack {
            if let streamConfiguration = viewModel.activeStreamConfiguration {
                ZStack {
                    OPNEmbeddedStreamView(
                        configuration: streamConfiguration,
                        onProgress: { progress in viewModel.updateActiveStreamProgress(progress) },
                        onEnd: { success, message, report in
                            viewModel.finishActiveStream(success: success, message: message, report: report)
                        }
                    )
                    .id(streamConfiguration.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if viewModel.isStreamLaunchLoadingVisible {
                        VendorStreamLaunchLoadingOverlay(viewModel: viewModel)
                            .transition(.opacity)
                            .zIndex(10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    CatalogTopBar(viewModel: viewModel, accounts: accounts, showsMainMenu: $showsMainMenu, showsPreviousSessionOverlay: $showsPreviousSessionOverlay, onSwitch: onSwitch, onSignOut: onSignOut, onForget: onForget)
                    if viewModel.selectedMainPage == .settings {
                        SettingsView(viewModel: viewModel)
                    } else {
                        CatalogContentView(viewModel: viewModel)
                    }
                }
                .transition(.opacity)

                if showsMainMenu {
                    CatalogMainMenuOverlay(viewModel: viewModel, isPresented: $showsMainMenu, onSignOut: onSignOut)
                        .transition(.opacity)
                        .zIndex(12)
                }

                if viewModel.isLaunchFlowVisible {
                    VendorLaunchFlowOverlay(viewModel: viewModel)
                        .transition(.opacity)
                        .zIndex(20)
                }

                if showsPreviousSessionOverlay {
                    CatalogPreviousSessionOverlay(viewModel: viewModel, isPresented: $showsPreviousSessionOverlay)
                        .transition(.opacity)
                        .zIndex(15)
                }
            }
        }
        .background(Color.black)
        .task { viewModel.loadIfNeeded() }
        .preferredColorScheme(.dark)
    }
}

private struct VendorLaunchFlowOverlay: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()
            RadialGradient(
                colors: [Color.openNowGreen.opacity(0.20), .clear],
                center: .top,
                startRadius: 20,
                endRadius: 620
            )
            .ignoresSafeArea()

            switch viewModel.launchFlowState {
            case .selectingRoute:
                VendorLaunchRouteCard(viewModel: viewModel)
            case .activeSessionPrompt:
                VendorActiveSessionCard(viewModel: viewModel)
            case .checkingSession, .stoppingSession, .startingStream:
                VendorLaunchProgressCard(viewModel: viewModel)
            case .idle:
                EmptyView()
            }
        }
    }
}

private struct VendorLaunchRouteCard: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        VendorLaunchPanel(title: "GeForce NOW Launch", subtitle: viewModel.launchFlowTitle) {
            VStack(alignment: .leading, spacing: 18) {
                VendorLaunchStepHeader(index: "1", title: "Select Server Location", message: viewModel.launchFlowMessage)
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(viewModel.launchRegionOptions, id: \.url) { option in
                            VendorLaunchRegionRow(
                                option: option,
                                selected: option.url == viewModel.selectedLaunchRegionUrl,
                                action: { viewModel.selectLaunchRegion(option.url) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 420)
                .background(Color.black.opacity(0.14))
                .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
                if !viewModel.launchFlowError.isEmpty {
                    VendorLaunchInlineMessage(message: viewModel.launchFlowError, warning: true)
                }
                HStack(spacing: 12) {
                    Button("CANCEL") { viewModel.cancelVendorLaunch() }
                        .buttonStyle(VendorLaunchSecondaryButtonStyle())
                    Spacer()
                    Button(viewModel.isRefreshingLaunchRegions ? "PINGING..." : "REFRESH") { viewModel.refreshLaunchRegions() }
                        .buttonStyle(VendorLaunchSecondaryButtonStyle())
                        .disabled(viewModel.isRefreshingLaunchRegions)
                    Button("CONTINUE") { viewModel.continueVendorLaunch() }
                        .buttonStyle(VendorLaunchPrimaryButtonStyle())
                }
            }
        }
    }
}

private struct VendorActiveSessionCard: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        VendorLaunchPanel(title: "Active Session", subtitle: viewModel.activeLaunchSession?.title ?? "Current Stream") {
            VStack(alignment: .leading, spacing: 18) {
                VendorLaunchStepHeader(index: "2", title: "Session Already Running", message: viewModel.launchFlowMessage)
                if let active = viewModel.activeLaunchSession {
                    VStack(alignment: .leading, spacing: 10) {
                        VendorLaunchSessionRow(label: "Current session", value: active.title)
                        VendorLaunchSessionRow(label: "App ID", value: active.appId > 0 ? String(active.appId) : "Unknown")
                        VendorLaunchSessionRow(label: "Server", value: active.serverIp)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.055))
                    .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
                }
                if !viewModel.launchFlowError.isEmpty {
                    VendorLaunchInlineMessage(message: viewModel.launchFlowError, warning: true)
                }
                HStack(spacing: 12) {
                    Button("CANCEL") { viewModel.cancelVendorLaunch() }
                        .buttonStyle(VendorLaunchSecondaryButtonStyle())
                    Spacer()
                    Button("RESUME SESSION") { viewModel.resumeActiveLaunchSession() }
                        .buttonStyle(VendorLaunchSecondaryButtonStyle())
                    Button("END AND LAUNCH") { viewModel.endActiveSessionAndLaunchSelectedGame() }
                        .buttonStyle(VendorLaunchPrimaryButtonStyle())
                }
            }
        }
    }
}

private struct VendorLaunchProgressCard: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        VendorLaunchPanel(title: "Launching", subtitle: viewModel.launchFlowTitle) {
            VStack(alignment: .leading, spacing: 18) {
                VendorLaunchStepHeader(index: progressIndex, title: progressTitle, message: viewModel.launchFlowMessage)
                VendorIndeterminateProgressBar()
                    .frame(height: 4)
                if !viewModel.launchFlowError.isEmpty {
                    VendorLaunchInlineMessage(message: viewModel.launchFlowError, warning: true)
                }
            }
        }
    }

    private var progressIndex: String {
        switch viewModel.launchFlowState {
        case .checkingSession: return "2"
        case .stoppingSession: return "3"
        case .startingStream: return "4"
        default: return ""
        }
    }

    private var progressTitle: String {
        switch viewModel.launchFlowState {
        case .checkingSession: return "Checking Session"
        case .stoppingSession: return "Ending Session"
        case .startingStream: return "Starting Stream"
        default: return "Preparing Launch"
        }
    }
}

private struct VendorStreamLaunchLoadingOverlay: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        GeometryReader { proxy in
            let progress = viewModel.activeStreamProgress
            let steps = progress?.steps ?? []
            let title = progress?.title.isEmpty == false ? progress?.title ?? "GeForce NOW" : "GeForce NOW"
            let message = progress?.message ?? "Starting GeForce NOW stream..."
            ZStack {
                Color.black

                RadialGradient(
                    stops: [
                        .init(color: .white.opacity(0.18), location: 0.00),
                        .init(color: .white.opacity(0.05), location: 0.46),
                        .init(color: .clear, location: 1.00)
                    ],
                    center: .top,
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.72
                )

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.80), location: 0.00),
                        .init(color: .black.opacity(0.34), location: 0.24),
                        .init(color: .black.opacity(0.18), location: 0.50),
                        .init(color: .black.opacity(0.34), location: 0.76),
                        .init(color: .black.opacity(0.80), location: 1.00)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                VStack(spacing: 24) {
                    VendorResourceImage(name: "splash-gfn-logo-v3", fileExtension: "svg")
                        .scaledToFit()
                        .frame(width: 174, height: 131)

                    VStack(spacing: 10) {
                        Text(title)
                            .font(.nvidia(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(message)
                            .font(.nvidia(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }

                    VendorIndeterminateProgressBar()
                        .frame(width: 320, height: 4)

                    if !steps.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                                VendorStreamLaunchStepRow(step: step, index: index, currentIndex: progress?.currentStepIndex ?? -1)
                            }
                        }
                        .frame(width: 320, alignment: .leading)
                    }
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .background(.black)
    }
}

private struct VendorStreamLaunchStepRow: View {
    let step: String
    let index: Int
    let currentIndex: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(marker)
                .font(.nvidia(size: 11, weight: .bold))
                .foregroundStyle(markerColor)
                .frame(width: 22, alignment: .center)
            Text(step)
                .font(.nvidia(size: 12, weight: index == currentIndex ? .bold : .medium))
                .foregroundStyle(textColor)
            Spacer(minLength: 0)
        }
        .opacity(index > currentIndex && currentIndex >= 0 ? 0.58 : 1)
    }

    private var marker: String {
        if index < currentIndex { return "OK" }
        return String(index + 1)
    }

    private var markerColor: Color {
        index <= currentIndex ? .openNowGreen : .white.opacity(0.46)
    }

    private var textColor: Color {
        index <= currentIndex || currentIndex < 0 ? .white.opacity(0.84) : .white.opacity(0.52)
    }
}

private struct VendorLaunchPanel<Content: View>: View {
    let title: String
    let subtitle: String
    private let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VendorResourceImage(name: "nv-gfn-logo_v3", fileExtension: "png")
                    .scaledToFit()
                    .frame(width: 108, height: 32, alignment: .leading)
                Spacer()
                Button { } label: {
                    Text("LAUNCH FLOW")
                        .font(.nvidia(size: 10, weight: .bold))
                        .foregroundStyle(Color.openNowGreen)
                        .tracking(1.4)
                }
                .buttonStyle(.plain)
                .disabled(true)
            }
            .padding(.horizontal, 22)
            .frame(height: 58)
            .background(Color(red: 57 / 255, green: 57 / 255, blue: 57 / 255))

            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.nvidia(size: 13, weight: .bold))
                    .foregroundStyle(Color.openNowGreen)
                    .tracking(1.2)
                Text(subtitle.isEmpty ? "GeForce NOW" : subtitle)
                    .font(.nvidia(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .padding(.bottom, 18)

            content
                .padding(.horizontal, 26)
                .padding(.bottom, 26)
        }
        .frame(width: 640)
        .background(Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255))
        .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
        .shadow(color: .black.opacity(0.55), radius: 28, y: 18)
    }
}

private struct VendorLaunchStepHeader: View {
    let index: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(index)
                .font(.nvidia(size: 12, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 26, height: 26)
                .background(Color.openNowGreen)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.nvidia(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.nvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct VendorLaunchRegionRow: View {
    let option: OPNStreamRegionOption
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(selected ? Color.openNowGreen : Color.white.opacity(0.18))
                    .frame(width: 4, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.automatic ? "Automatic" : option.name)
                        .font(.nvidia(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text(option.automatic ? "Best measured route" : "Cloudmatch region")
                        .font(.nvidia(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                }
                Spacer()
                Text(latencyText)
                    .font(.nvidia(size: 12, weight: .bold))
                    .foregroundStyle(selected ? Color.openNowGreen : .white.opacity(0.70))
            }
            .padding(12)
            .background(selected ? Color.openNowGreen.opacity(0.12) : Color.white.opacity(0.045))
            .overlay { Rectangle().stroke(selected ? Color.openNowGreen.opacity(0.72) : Color.white.opacity(0.08), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private var latencyText: String {
        option.latencyMs >= 0 ? "\(option.latencyMs) ms" : "Measuring"
    }
}

private struct VendorLaunchSessionRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label.uppercased())
                .font(.nvidia(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.48))
                .frame(width: 130, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .font(.nvidia(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
        }
    }
}

private struct VendorLaunchInlineMessage: View {
    let message: String
    let warning: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
            Text(message)
                .font(.nvidia(size: 12, weight: .medium))
        }
        .foregroundStyle(warning ? Color.yellow.opacity(0.86) : .white.opacity(0.72))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct VendorLaunchPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.nvidia(size: 12, weight: .bold))
            .foregroundStyle(.black)
            .tracking(0.8)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(Color.openNowGreen.opacity(configuration.isPressed ? 0.78 : 1.0))
    }
}

private struct VendorLaunchSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.nvidia(size: 12, weight: .bold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.68 : 0.86))
            .tracking(0.8)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(Color.white.opacity(configuration.isPressed ? 0.10 : 0.055))
            .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
    }
}

private struct CatalogTopBar: View {
    @ObservedObject var viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    @Binding var showsMainMenu: Bool
    @Binding var showsPreviousSessionOverlay: Bool
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 28) {
                Button { showsMainMenu.toggle() } label: {
                    CatalogHamburgerLabel(isOpen: showsMainMenu)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsMainMenu ? "Close main menu" : "Open main menu")
                Text(viewModel.selectedMainPage == .settings ? "Settings" : "Games")
                    .font(.nvidia(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
            }
            .padding(.leading, 20)

            if viewModel.selectedMainPage == .games {
                catalogSearchField
                    .frame(width: 540)
            } else {
                Text(viewModel.selectedSettingsPage.title)
                    .font(.nvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.70))
                    .tracking(1.1)
                    .frame(width: 540)
            }

            HStack(spacing: 24) {
                Spacer()
                Button { showsPreviousSessionOverlay.toggle() } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.nvidia(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.94))
                        .overlay(alignment: .topTrailing) {
                            if viewModel.previousGameSession != nil {
                                Circle()
                                    .fill(Color.openNowGreen)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 2, y: -2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous game session")

                Menu {
                    ForEach(accounts) { account in
                        Button(account.displayName) { onSwitch(account) }
                    }
                    Divider()
                    Button("Sign Out", action: onSignOut)
                    ForEach(accounts) { account in
                        Button("Forget \(account.displayName)", role: .destructive) { onForget(account) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        VendorResourceImage(name: "avatar_generic_118", fileExtension: "svg")
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(viewModel.account.displayName)
                                .font(.nvidia(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("Performance")
                                .font(.nvidia(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        Image(systemName: "chevron.down")
                            .font(.nvidia(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.88))
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 22)
        }
        .frame(height: CatalogVendorLayout.appBarHeight)
        .background(CatalogVendorLayout.appBarBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.28)).frame(height: 1) }
    }

    private var catalogSearchField: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.nvidia(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.76))
            TextField("Search games, stores, or genres", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.nvidia(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .onSubmit { viewModel.browseCatalog() }
            if !viewModel.searchQuery.isEmpty {
                Button { viewModel.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.52))
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 40)
        .background(Color(red: 0.145, green: 0.145, blue: 0.145))
        .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
    }
}

private struct CatalogHamburgerLabel: View {
    let isOpen: Bool
    @State private var isHovering = false

    var body: some View {
        ZStack {
            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill((isOpen || isHovering) ? Color.openNowGreen : Color.white.opacity(0.84))
                        .frame(width: index == 1 ? 20 : 23, height: 2)
                }
            }
        }
        .frame(width: 44, height: 40)
        .background((isOpen || isHovering) ? Color.black.opacity(0.32) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill((isOpen || isHovering) ? Color.openNowGreen : Color.clear)
                .frame(height: 3)
        }
        .onHover { isHovering = $0 }
        .accessibilityLabel("Main menu")
    }
}

private struct CatalogMainMenuOverlay: View {
    @ObservedObject var viewModel: CatalogViewModel
    @Binding var isPresented: Bool
    let onSignOut: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            CatalogMainMenuPanel(viewModel: viewModel, isPresented: $isPresented, onSignOut: onSignOut)
                .padding(.top, CatalogVendorLayout.appBarHeight)
                .padding(.leading, 0)
        }
        .onExitCommand { isPresented = false }
    }
}

private struct CatalogMainMenuPanel: View {
    @ObservedObject var viewModel: CatalogViewModel
    @Binding var isPresented: Bool
    let onSignOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("GEFORCE NOW")
                    .font(.nvidia(size: 11, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Color.openNowGreen)
                Text("OpenNOW Menu")
                    .font(.nvidia(size: 20, weight: .bold))
                    .foregroundStyle(.white.opacity(0.96))
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 18)

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 6) {
                CatalogMainMenuSectionLabel("NAVIGATION")
                CatalogMainMenuRow(title: "Games", subtitle: "Browse and launch cloud games", systemImage: "gamecontroller.fill", isActive: viewModel.selectedMainPage == .games) {
                    viewModel.showGames()
                    isPresented = false
                }
                CatalogMainMenuRow(title: "Settings", subtitle: "Streaming, account, and system options", systemImage: "gearshape.fill", isActive: viewModel.selectedMainPage == .settings) {
                    viewModel.showSettings()
                    isPresented = false
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 6) {
                CatalogMainMenuSectionLabel("SETTINGS")
                ForEach(CatalogSettingsPage.allCases) { page in
                    CatalogMainMenuRow(title: page.title, subtitle: "", systemImage: settingsIcon(for: page), isActive: viewModel.selectedMainPage == .settings && viewModel.selectedSettingsPage == page, compact: true) {
                        viewModel.showSettings(page)
                        isPresented = false
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 6) {
                CatalogMainMenuSectionLabel("ACTIONS")
                CatalogMainMenuRow(title: "Refresh Catalog", subtitle: "Fetch latest panels and game metadata", systemImage: "arrow.clockwise", isActive: false) {
                    viewModel.refresh()
                    isPresented = false
                }
                if viewModel.selectedMainPage == .games, viewModel.isBrowseMode {
                    CatalogMainMenuRow(title: "Clear Search and Filters", subtitle: "Return to the default catalog view", systemImage: "line.3.horizontal.decrease.circle", isActive: false) {
                        viewModel.clearSearchAndFilters()
                        isPresented = false
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)

            Spacer(minLength: 18)

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)

            CatalogMainMenuRow(title: "Sign Out", subtitle: viewModel.account.displayName, systemImage: "rectangle.portrait.and.arrow.right", isActive: false, role: .destructive) {
                isPresented = false
                onSignOut()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .frame(width: 344, height: 620, alignment: .topLeading)
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

    private func settingsIcon(for page: CatalogSettingsPage) -> String {
        switch page {
        case .account: return "person.crop.circle.fill"
        case .connections: return "link"
        case .gameplay: return "slider.horizontal.3"
        case .serverLocation: return "network"
        case .resolutionUpscaling: return "sparkles.tv.fill"
        case .system: return "desktopcomputer"
        case .about: return "info.circle.fill"
        }
    }
}

private struct CatalogMainMenuSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.nvidia(size: 10, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(.white.opacity(0.42))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
    }
}

private struct CatalogMainMenuRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isActive: Bool
    var compact = false
    var role: ButtonRole?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ZStack {
                    Rectangle()
                        .fill(isActive ? Color.openNowGreen : Color.white.opacity(isHovering ? 0.16 : 0.08))
                    Image(systemName: systemImage)
                        .font(.nvidia(size: compact ? 12 : 14, weight: .bold))
                        .foregroundStyle(iconColor)
                }
                .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.nvidia(size: compact ? 12 : 14, weight: .bold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.nvidia(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.52))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isActive {
                    Rectangle()
                        .fill(Color.openNowGreen)
                        .frame(width: 4, height: compact ? 26 : 38)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 0)
            .frame(height: compact ? 38 : 50)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isActive ? Color.openNowGreen : Color.clear)
                    .frame(width: 3)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }

    private var rowBackground: Color {
        if isActive { return Color.openNowGreen.opacity(0.14) }
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

private struct CatalogPreviousSessionOverlay: View {
    @ObservedObject var viewModel: CatalogViewModel
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.34)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.nvidia(size: 20, weight: .bold))
                        .foregroundStyle(Color.openNowGreen)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Previous Game Session")
                            .font(.nvidia(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Most recent GeForce NOW stream summary")
                            .font(.nvidia(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark")
                            .font(.nvidia(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.78))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)

                if let previous = viewModel.previousGameSession {
                    VStack(alignment: .leading, spacing: 10) {
                        detailRow("Game", previous.title)
                        detailRow("App ID", previous.appId)
                        detailRow("Store", previous.store.isEmpty ? "GeForce NOW" : viewModel.displayName(forStore: previous.store))
                        detailRow("Ended", formattedDate(previous.endedAt))
                        detailRow("Result", previous.result)
                        detailRow("Launch", previous.launchTime)
                        detailRow("Latency", previous.averageLatency)
                        detailRow("Bitrate", previous.averageBitrate)
                        detailRow("Dropped", previous.droppedFrames)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No completed game stream yet.")
                            .font(.nvidia(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                        Text("The green indicator appears after OpenNOW has a previous game session to show.")
                            .font(.nvidia(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.64))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(22)
            .frame(width: 430, alignment: .leading)
            .background(Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255).opacity(0.98))
            .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
            .shadow(color: .black.opacity(0.48), radius: 22, x: 0, y: 14)
            .padding(.top, CatalogVendorLayout.appBarHeight + 12)
            .padding(.trailing, 22)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label.uppercased())
                .font(.nvidia(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.46))
                .frame(width: 72, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .font(.nvidia(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct CatalogContentView: View {
    @ObservedObject var viewModel: CatalogViewModel
    @State private var heroIndex = 0
    @State private var heroAutoScrollEnabled = true
    private let heroTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let heroes = heroGames
        let hero = heroes.indices.contains(heroIndex) ? heroes[heroIndex] : heroes.first
        let sections = viewModel.catalogSections
        ScrollViewReader { proxy in
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if hero != nil {
                            CatalogHeroView(
                                viewModel: viewModel,
                                games: heroes,
                                activeIndex: heroes.indices.contains(heroIndex) ? heroIndex : 0,
                                onSelectSlide: { index in
                                    heroAutoScrollEnabled = false
                                    heroIndex = index
                                },
                                onPreviousSlide: {
                                    guard !heroes.isEmpty else { return }
                                    heroAutoScrollEnabled = false
                                    heroIndex = max(heroIndex - 1, 0)
                                },
                                onNextSlide: {
                                    guard !heroes.isEmpty else { return }
                                    heroAutoScrollEnabled = false
                                    heroIndex = min(heroIndex + 1, heroes.count - 1)
                                }
                            )
                        }

                        if !viewModel.errorMessage.isEmpty {
                            CatalogMessageView(message: viewModel.errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin)
                        }
                        if viewModel.isBrowseMode {
                            CatalogBrowseControlsView(viewModel: viewModel)
                                .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin)
                        }
                        if (viewModel.isLoading || viewModel.isLoadingPanels) && !sections.isEmpty {
                            CatalogLoadingStrip()
                                .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin)
                        }

                        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                            CatalogRailView(viewModel: viewModel, section: section)
                            if shouldShowDetail(afterSectionAt: index, sections: sections), let detailAnchor = selectedDetailScrollAnchor {
                                GameDetailPanel(viewModel: viewModel)
                                    .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin)
                                    .padding(.top, -CatalogVendorLayout.cardTrayHeight)
                                    .id(detailAnchor)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }
                    }
                    .padding(.bottom, 44)
                }
                .background(
                    Color.black
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.closeGameDetailsFromBackground() }
                )

                if (viewModel.isLoading || viewModel.isLoadingPanels) && sections.isEmpty {
                    VendorSplashLoadingView()
                        .transition(.opacity)
                }
            }
            .onChange(of: selectedDetailScrollAnchor) { _, anchor in
                scrollToSelectedDetail(anchor, proxy: proxy)
            }
        }
        .background(Color.black)
        .onReceive(heroTimer) { _ in
            guard heroAutoScrollEnabled, heroes.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                heroIndex = (heroIndex + 1) % heroes.count
            }
        }
        .onChange(of: heroIdentityList) { _, identities in
            guard !identities.isEmpty else {
                heroIndex = 0
                return
            }
            if heroIndex >= identities.count { heroIndex = 0 }
        }
    }

    private var heroGames: [OPNCatalogGameObject] {
        viewModel.marqueeGames
    }

    private var heroIdentityList: [String] {
        heroGames.map { CatalogViewModel.identity(for: $0) }
    }

    private var selectedDetailScrollAnchor: String? {
        guard let selectedGame = viewModel.selectedGame else { return nil }
        return "detail-\(viewModel.selectedSectionId)-\(selectedGame.catalogIdentity)"
    }

    private func scrollToSelectedDetail(_ anchor: String?, proxy: ScrollViewProxy) {
        guard let anchor else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.24)) {
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
    }

    private func shouldShowDetail(afterSectionAt index: Int, sections: [CatalogSectionModel]) -> Bool {
        guard let selectedGame = viewModel.selectedGame else { return false }
        if !viewModel.selectedSectionId.isEmpty {
            return sections[index].id == viewModel.selectedSectionId && sections[index].games.contains(where: { CatalogViewModel.looseIdentityMatches($0, selectedGame) })
        }
        guard sections[index].games.contains(where: { CatalogViewModel.looseIdentityMatches($0, selectedGame) }) else {
            return false
        }
        return !sections.prefix(index).contains { section in
            section.games.contains { CatalogViewModel.looseIdentityMatches($0, selectedGame) }
        }
    }
}

private struct CatalogHeroView: View {
    @ObservedObject var viewModel: CatalogViewModel
    let games: [OPNCatalogGameObject]
    let activeIndex: Int
    let onSelectSlide: (Int) -> Void
    let onPreviousSlide: () -> Void
    let onNextSlide: () -> Void
    @State private var scrimColor = CatalogMarqueeScrimColor.black
    @State private var containerWidth: CGFloat = 0

    private var game: OPNCatalogGameObject? {
        games.indices.contains(activeIndex) ? games[activeIndex] : games.first
    }

    var body: some View {
        if let game {
            GeometryReader { proxy in
                let heroHeight = CatalogVendorLayout.heroHeight(for: proxy.size.width)
                let imageLeading = CatalogVendorLayout.heroImageLeading(for: proxy.size.width)
                ZStack(alignment: .bottom) {
                    CatalogHeroVendorBackgroundScrim(color: scrimColor)
                    CatalogHeroRemoteImage(url: viewModel.optimizedImageURL(game.bestHeroImageURL, width: 1920), contentMode: .fill) { color in
                        scrimColor = color
                    }
                    .frame(width: max(proxy.size.width - imageLeading, 1), height: heroHeight)
                    .mask(CatalogHeroVendorImageMask())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .clipped()
                    .id(game.catalogIdentity)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                    CatalogHeroVendorGradientOverlays(imageLeading: imageLeading)

                    VStack(spacing: 24) {
                        CatalogHeroTitleView(viewModel: viewModel, game: game, scrimColor: scrimColor)
                        VStack(spacing: 2) {
                            Text(game.primaryStoreLabel)
                                .font(.nvidia(size: 13, weight: .bold))
                            if !game.ratingLabel.isEmpty {
                                Text(game.ratingLabel)
                                    .font(.nvidia(size: 13, weight: .bold))
                            }
                        }
                        .foregroundStyle(scrimColor.preferredTextColor.opacity(0.94))
                        Button { viewModel.selectGameFromHero(game) } label: {
                            Text("VIEW DETAILS")
                                .font(.nvidia(size: 14, weight: .bold))
                                .frame(width: 142, height: 41)
                        }
                        .buttonStyle(VendorGetInButtonStyle())
                    }
                    .frame(width: 470)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 102)
                    .padding(.leading, 108)

                    HStack {
                        if activeIndex > 0 {
                            CatalogMarqueeArrow(name: "lt_arrow", action: onPreviousSlide)
                        } else {
                            Color.clear.frame(width: 48, height: 48)
                        }
                        Spacer()
                        if activeIndex < games.count - 1 {
                            CatalogMarqueeArrow(name: "rt_arrow", action: onNextSlide)
                        } else {
                            Color.clear.frame(width: 48, height: 48)
                        }
                    }
                    .frame(height: heroHeight, alignment: .center)
                    .padding(.horizontal, 16)

                    HStack(spacing: 8) {
                        ForEach(Array(games.enumerated()), id: \.element.catalogIdentity) { index, _ in
                            Button { onSelectSlide(index) } label: {
                                Circle()
                                    .fill(index == activeIndex ? Color.openNowGreen : Color.white.opacity(0.58))
                                    .frame(width: index == activeIndex ? 12 : 9, height: index == activeIndex ? 12 : 9)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 34)
                }
                .onAppear { containerWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in containerWidth = width }
            }
            .frame(height: CatalogVendorLayout.heroHeight(for: containerWidth))
            .clipShape(Rectangle())
        }
    }
}

private struct CatalogHeroTitleView: View {
    @ObservedObject var viewModel: CatalogViewModel
    let game: OPNCatalogGameObject
    let scrimColor: CatalogMarqueeScrimColor

    var body: some View {
        if let logoURL = viewModel.optimizedImageURL(game.bestLogoImageURL, width: 620) {
            AsyncImage(url: logoURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 390, maxHeight: 150)
                case .failure:
                    fallbackTitle
                case .empty:
                    fallbackTitle.opacity(0)
                @unknown default:
                    fallbackTitle
                }
            }
        } else {
            fallbackTitle
        }
    }

    private var fallbackTitle: some View {
        Text(game.mallDisplayTitle)
            .font(.nvidia(size: 52))
            .tracking(8)
            .foregroundStyle(scrimColor.preferredTextColor.opacity(0.94))
            .lineLimit(2)
            .minimumScaleFactor(0.55)
            .multilineTextAlignment(.center)
    }
}

private struct CatalogMarqueeArrow: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VendorResourceImage(name: name, fileExtension: "svg")
                .scaledToFit()
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
    }
}

private struct CatalogBrowseControlsView: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if !viewModel.resultSummary.isEmpty {
                    Text(viewModel.resultSummary.uppercased())
                        .font(.nvidia(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.62))
                }
                if viewModel.hasMoreCatalogResults {
                    Text("SHOWING TOP RESULTS")
                        .font(.nvidia(size: 12, weight: .bold))
                        .foregroundStyle(Color.openNowGreen.opacity(0.88))
                }
                Spacer()
                if !viewModel.searchQuery.trimmed.isEmpty || viewModel.selectedFilterCount > 0 {
                    Button("CLEAR") { viewModel.clearSearchAndFilters() }
                        .buttonStyle(.plain)
                        .font(.nvidia(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.84))
                }
                Menu {
                    ForEach(viewModel.sortOptions, id: \.id) { option in
                        Button(option.label.isEmpty ? option.id : option.label) { viewModel.setSort(option.id) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("SORT: \(viewModel.selectedSortLabel.uppercased())")
                        Image(systemName: "chevron.down")
                    }
                    .font(.nvidia(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.08))
                }
                .menuStyle(.button)
                .disabled(viewModel.sortOptions.isEmpty)
            }

            if !viewModel.visibleFilterGroups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.visibleFilterGroups, id: \.id) { group in
                            Menu {
                                ForEach(group.options, id: \.id) { option in
                                    Button(filterTitle(option: option)) { viewModel.toggleFilter(option.id) }
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    Text((group.label.isEmpty ? group.id : group.label).uppercased())
                                    Image(systemName: "slider.horizontal.3")
                                }
                                .font(.nvidia(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.82))
                                .padding(.horizontal, 11)
                                .frame(height: 32)
                                .background(Color.white.opacity(0.075))
                                .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
                            }
                            .menuStyle(.button)
                        }
                        ForEach(selectedFilterOptions, id: \.id) { option in
                            Button { viewModel.toggleFilter(option.id) } label: {
                                HStack(spacing: 7) {
                                    Text(option.label.uppercased())
                                    Image(systemName: "xmark")
                                }
                                .font(.nvidia(size: 11, weight: .bold))
                                .foregroundStyle(.black.opacity(0.88))
                                .padding(.horizontal, 11)
                                .frame(height: 32)
                                .background(Color.openNowGreen)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var selectedFilterOptions: [OPNCatalogFilterOptionObject] {
        viewModel.visibleFilterGroups.flatMap(\.options).filter { viewModel.selectedFilterIds.contains($0.id) }
    }

    private func filterTitle(option: OPNCatalogFilterOptionObject) -> String {
        let selectedPrefix = viewModel.selectedFilterIds.contains(option.id) ? "✓ " : ""
        return selectedPrefix + (option.label.isEmpty ? option.id : option.label)
    }
}

private struct CatalogRailView: View {
    @ObservedObject var viewModel: CatalogViewModel
    let section: CatalogSectionModel
    @State private var scrollIndex = 0

    private var isExpanded: Bool { viewModel.expandedSectionIds.contains(section.id) }
    private var games: [OPNCatalogGameObject] { section.visibleGames(expanded: isExpanded) }
    private var canSeeAll: Bool { section.games.count > games.count || isExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(section.title)
                    .font(.nvidia(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.96))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if canSeeAll {
                    Button(isExpanded ? "SHOW LESS" : "SEE ALL") { viewModel.toggleSectionExpansion(section.id) }
                        .buttonStyle(.plain)
                        .font(.nvidia(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .frame(height: 28)
            .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin)

            ScrollViewReader { proxy in
                ZStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(games.enumerated()), id: \.element.catalogIdentity) { _, game in
                                CatalogGameTile(viewModel: viewModel, game: game, sectionId: section.id)
                                    .id(game.catalogIdentity)
                            }
                            if section.games.count > games.count {
                                CatalogSeeMoreTile(title: "See All") { viewModel.toggleSectionExpansion(section.id) }
                            }
                        }
                        .padding(.horizontal, CatalogVendorLayout.carouselContainerMargin)
                        .padding(.bottom, 4)
                    }
                    if games.count > 3 {
                        HStack {
                            CatalogRailArrow(name: "lt_arrow") {
                                moveRail(proxy: proxy, delta: -3)
                            }
                            Spacer()
                            CatalogRailArrow(name: "rt_arrow") {
                                moveRail(proxy: proxy, delta: 3)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
            }
        }
    }

    private func moveRail(proxy: ScrollViewProxy, delta: Int) {
        guard !games.isEmpty else { return }
        scrollIndex = min(max(scrollIndex + delta, 0), max(games.count - 1, 0))
        withAnimation(.easeInOut(duration: 0.22)) {
            proxy.scrollTo(games[scrollIndex].catalogIdentity, anchor: .leading)
        }
    }
}

private struct CatalogRailArrow: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VendorResourceImage(name: name, fileExtension: "svg")
                .scaledToFit()
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.24), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct CatalogSeeMoreTile: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: "ellipsis")
                    .font(.nvidia(size: 34, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                Text(title.uppercased())
                    .font(.nvidia(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .frame(width: CatalogVendorLayout.wideTileWidth, height: CatalogVendorLayout.wideTileHeight)
            .background(Color(red: 43 / 255, green: 43 / 255, blue: 43 / 255))
            .overlay { Rectangle().stroke(Color.white.opacity(0.24), lineWidth: 2) }
            .scaleEffect(isHovering ? CatalogVendorLayout.tileScaleFactor : 1.0)
            .animation(.easeOut(duration: 0.2), value: isHovering)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin)
        .padding(.top, CatalogVendorLayout.tileTopMargin)
        .frame(width: CatalogVendorLayout.wideTileWidth + CatalogVendorLayout.tileHorizontalMargin * 2, height: CatalogVendorLayout.wideTileHeight + CatalogVendorLayout.cardTrayHeight + CatalogVendorLayout.tileTopMargin, alignment: .top)
        .onHover { isHovering = $0 }
        .accessibilityLabel("See all")
    }
}

private struct CatalogGameTile: View {
    @ObservedObject var viewModel: CatalogViewModel
    let game: OPNCatalogGameObject
    let sectionId: String
    @State private var isHovering = false

    private var isSelected: Bool {
        guard let selectedGame = viewModel.selectedGame else { return false }
        if !viewModel.selectedSectionId.isEmpty, viewModel.selectedSectionId != sectionId { return false }
        return CatalogViewModel.looseIdentityMatches(selectedGame, game)
    }

    private var shouldDim: Bool {
        viewModel.selectedGame != nil && !isSelected
    }

    var body: some View {
        Button { viewModel.selectGame(game, inSection: sectionId) } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestWideImageURL, width: 620), contentMode: .fill)
                        .frame(width: CatalogVendorLayout.wideTileWidth, height: CatalogVendorLayout.wideTileHeight)
                        .clipped()
                    if shouldDim {
                        Color.black.opacity(0.80)
                    }
                    if isHovering || isSelected {
                        Color.black.opacity(0.50)
                        LinearGradient(colors: [CatalogVendorLayout.tileTray, CatalogVendorLayout.tileTray.opacity(0)], startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.63))
                    }
                    if game.isInLibrary {
                        MallRibbonShape()
                            .fill(Color.openNowGreen)
                            .frame(width: 7, height: 24)
                    }
                }
                if isHovering || isSelected {
                    HStack(spacing: 8) {
                        Text(game.title.isEmpty ? "GeForce NOW" : game.title)
                            .font(.nvidia(size: 12, weight: isSelected ? .medium : .regular))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? .white.opacity(0.90) : .white.opacity(0.60))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.nvidia(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.76))
                    }
                    .frame(width: CatalogVendorLayout.wideTileWidth - 32, height: CatalogVendorLayout.cardTrayHeight)
                    .padding(.horizontal, 16)
                    .background(CatalogVendorLayout.tileTray)
                }
            }
            .frame(width: CatalogVendorLayout.wideTileWidth, alignment: .top)
            .overlay(alignment: .top) {
                if isSelected {
                    Rectangle()
                        .fill(Color.openNowGreen)
                        .frame(width: CatalogVendorLayout.wideTileWidth, height: 4)
                        .offset(y: CatalogVendorLayout.wideTileHeight + 4)
                }
            }
            .shadow(color: isSelected ? .black.opacity(0.28) : .clear, radius: 5, x: 0, y: 3)
            .scaleEffect(isHovering && !viewModel.selectedGameExists ? CatalogVendorLayout.tileScaleFactor : 1.0)
            .animation(.easeOut(duration: 0.2), value: isHovering)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin)
        .padding(.top, CatalogVendorLayout.tileTopMargin)
        .frame(width: CatalogVendorLayout.wideTileWidth + CatalogVendorLayout.tileHorizontalMargin * 2, height: CatalogVendorLayout.wideTileHeight + CatalogVendorLayout.cardTrayHeight + CatalogVendorLayout.tileTopMargin, alignment: .top)
        .onHover { isHovering = $0 }
        .accessibilityLabel(game.title.isEmpty ? "Game tile" : game.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isSelected ? "Details open" : "")
    }
}

private extension CatalogViewModel {
    var selectedGameExists: Bool { selectedGame != nil }
}

private struct MallRibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.72))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct GameDetailPanel: View {
    @ObservedObject var viewModel: CatalogViewModel
    @State private var activeImageIndex = 0
    private let imageTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        if let game = viewModel.selectedGame {
            let imageURLs = game.detailImageURLs
            let imageIndex = imageURLs.indices.contains(activeImageIndex) ? activeImageIndex : 0
            let imageURL = imageURLs.indices.contains(imageIndex) ? imageURLs[imageIndex] : game.bestDetailImageURL
            GeometryReader { proxy in
                ZStack(alignment: .topTrailing) {
                    CatalogRemoteImage(url: viewModel.optimizedImageURL(imageURL, width: 1600), contentMode: .fill)
                        .frame(width: proxy.size.width, height: CatalogVendorLayout.detailPanelHeight)
                        .clipped()
                        .id(imageURL)
                        .transition(.opacity.animation(.easeInOut(duration: 0.22)))
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 82 / 255, green: 82 / 255, blue: 82 / 255).opacity(0.96), location: 0.00),
                            .init(color: Color(red: 82 / 255, green: 82 / 255, blue: 82 / 255).opacity(0.88), location: 0.36),
                            .init(color: Color(red: 82 / 255, green: 82 / 255, blue: 82 / 255).opacity(0.50), location: 0.54),
                            .init(color: .black.opacity(0.08), location: 0.74),
                            .init(color: .clear, location: 1.00)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    LinearGradient(colors: [.black.opacity(0.06), .black.opacity(0.46)], startPoint: .top, endPoint: .bottom)

                    VStack(alignment: .leading, spacing: 15) {
                        Text(game.title.isEmpty ? "Selected Game" : game.title)
                            .font(.nvidia(size: 34, weight: .bold))
                            .lineLimit(2)

                        if !game.detailChips.isEmpty {
                            detailChips(game: game)
                        }

                        Text(game.gameDescription.isEmpty ? "Play instantly through GeForce NOW cloud streaming." : game.gameDescription)
                            .font(.nvidia(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.76))
                            .lineSpacing(4)
                            .lineLimit(5)
                            .frame(maxWidth: 640, alignment: .leading)

                        HStack(spacing: 14) {
                            Button { primaryAction(game: game) } label: {
                                Text(primaryActionTitle(game: game))
                                    .font(.nvidia(size: 15, weight: .bold))
                                    .frame(width: 152, height: 42)
                            }
                            .buttonStyle(VendorGetInButtonStyle())

                            Button("Open Store") { viewModel.openStoreForSelectedVariant() }
                                .buttonStyle(SecondaryLoginButtonStyle(compact: true))
                                .opacity(game.variants.isEmpty ? 0.5 : 1)
                                .disabled(game.variants.isEmpty)

                            Menu {
                                Button("Share") { viewModel.shareSelectedGame() }
                                if selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true || game.isInLibrary {
                                    Button("Remove from Library", role: .destructive) { viewModel.removeSelectedVariantOwned() }
                                } else if selectedVariant != nil {
                                    Button("Mark as Owned") { viewModel.markSelectedVariantOwned() }
                                }
                                if selectedVariant?.appStore.isEmpty == false {
                                    Button("Sync \(viewModel.displayName(forStore: selectedVariant?.appStore ?? ""))") { viewModel.syncSelectedStoreAccount() }
                                    Button("Connect \(viewModel.displayName(forStore: selectedVariant?.appStore ?? ""))") { viewModel.linkSelectedStoreAccount() }
                                }
                            } label: {
                                Image(systemName: "ellipsis.vertical")
                                    .font(.nvidia(size: 16, weight: .bold))
                                    .frame(width: 42, height: 42)
                            }
                            .menuStyle(.button)
                        }

                        if !game.variants.isEmpty {
                            variantChips(game: game)
                        }

                        if let selectedVariant, !selectedVariant.appStore.isEmpty {
                            storeAccountStatus(store: selectedVariant.appStore)
                        }

                        if !viewModel.launchMessage.isEmpty {
                            CatalogMessageView(message: viewModel.launchMessage, systemImage: "play.circle.fill")
                                .frame(maxWidth: 520)
                        }

                        if !viewModel.actionMessage.isEmpty {
                            CatalogMessageView(message: viewModel.actionMessage, systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: 520)
                        }

                        detailRows(game: game)
                    }
                    .frame(width: min(proxy.size.width * 0.47, 760), alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 34)
                    .padding(.leading, 40)
                    .padding(.trailing, 54)

                    Button { viewModel.selectGame(nil) } label: {
                        Image(systemName: "xmark")
                            .font(.nvidia(size: 22, weight: .regular))
                            .foregroundStyle(.white.opacity(0.90))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .padding(18)
                }
                .overlay {
                    if imageURLs.count > 1 {
                        HStack {
                            CatalogDetailImageArrow(name: "lt_arrow") {
                                moveImage(delta: -1, count: imageURLs.count)
                            }
                            Spacer()
                            CatalogDetailImageArrow(name: "rt_arrow") {
                                moveImage(delta: 1, count: imageURLs.count)
                            }
                        }
                        .padding(.horizontal, 18)
                    }
                }
                .overlay(alignment: .bottom) {
                    if imageURLs.count > 1 {
                        HStack(spacing: 12) {
                            ForEach(imageURLs.indices, id: \.self) { index in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.18)) { activeImageIndex = index }
                                } label: {
                                    Circle()
                                        .fill(index == imageIndex ? Color.openNowGreen : Color.white.opacity(0.62))
                                        .frame(width: index == imageIndex ? 12 : 9, height: index == imageIndex ? 12 : 9)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 38)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let logoURL = viewModel.optimizedImageURL(game.bestLogoImageURL, width: 300) {
                        AsyncImage(url: logoURL) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            default:
                                EmptyView()
                            }
                        }
                        .frame(width: 160, height: 70, alignment: .bottomTrailing)
                        .padding(.trailing, 42)
                        .padding(.bottom, 28)
                        .opacity(0.94)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: CatalogVendorLayout.detailPanelHeight, maxHeight: CatalogVendorLayout.detailPanelHeight)
            .background(Color(red: 82 / 255, green: 82 / 255, blue: 82 / 255))
            .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
            .onReceive(imageTimer) { _ in
                guard game.detailImageURLs.count > 1 else { return }
                moveImage(delta: 1, count: game.detailImageURLs.count)
            }
            .onChange(of: game.catalogIdentity) { _, _ in activeImageIndex = 0 }
        }
    }

    private func moveImage(delta: Int, count: Int) {
        guard count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            activeImageIndex = (activeImageIndex + delta + count) % count
        }
    }

    private func detailChips(game: OPNCatalogGameObject) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(game.detailChips, id: \.self) { chip in
                Text(chip)
                    .font(.nvidia(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.09))
                    .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
            }
        }
    }

    private var selectedVariant: OPNCatalogGameVariantObject? {
        viewModel.selectedVariant(in: viewModel.selectedGame)
    }

    private func primaryActionTitle(game: OPNCatalogGameObject) -> String {
        if game.isInLibrary || selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true { return "PLAY" }
        if selectedVariant != nil { return "MARK OWNED" }
        return "PLAY"
    }

    private func primaryAction(game: OPNCatalogGameObject) {
        if game.isInLibrary || selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true || selectedVariant == nil {
            viewModel.launchSelectedGame()
        } else {
            viewModel.markSelectedVariantOwned()
        }
    }

    private func variantChips(game: OPNCatalogGameObject) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(game.variants.enumerated()), id: \.offset) { index, variant in
                Button { selectVariant(at: index, in: game) } label: {
                    HStack(spacing: 7) {
                        if variant.librarySelected || variant.inLibrary || index == viewModel.selectedVariantIndex {
                            Image(systemName: variant.librarySelected || variant.inLibrary ? "checkmark.circle.fill" : "circle.fill")
                                .font(.nvidia(size: 11, weight: .bold))
                        }
                        Text(storePickerTitle(variant: variant))
                            .font(.nvidia(size: 11, weight: .bold))
                    }
                    .foregroundStyle(index == viewModel.selectedVariantIndex ? .black.opacity(0.88) : .white.opacity(0.82))
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(index == viewModel.selectedVariantIndex ? Color.openNowGreen : Color.white.opacity(0.09))
                    .overlay { Rectangle().stroke(index == viewModel.selectedVariantIndex ? Color.openNowGreen : Color.white.opacity(0.14), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(storePickerTitle(variant: variant))
                .accessibilityValue(index == viewModel.selectedVariantIndex ? "Selected" : "")
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func selectVariant(at index: Int, in game: OPNCatalogGameObject) {
        viewModel.selectedVariantIndex = index
        guard index >= 0, index < game.variants.count else { return }
        let variant = game.variants[index]
        if variant.inLibrary || variant.librarySelected { viewModel.selectOwnedVariant(variant) }
    }

    private func storePickerTitle(variant: OPNCatalogGameVariantObject) -> String {
        variant.appStore.isEmpty ? "GeForce NOW" : viewModel.displayName(forStore: variant.appStore)
    }

    private func storeAccountStatus(store: String) -> some View {
        let account = viewModel.accountStatus(forStore: store)
        let storeName = viewModel.displayName(forStore: store)
        return HStack(spacing: 8) {
            Image(systemName: account?.hasAccountLinkingData == true ? "link.circle.fill" : "link.circle")
                .foregroundStyle(Color.openNowGreen)
            Text(accountStatusText(account: account, storeName: storeName))
                .font(.nvidia(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 520)
    }

    private func accountStatusText(account: CatalogStoreAccount?, storeName: String) -> String {
        guard let account else { return "Connect \(storeName) to sync owned games." }
        if !account.userDisplayName.isEmpty { return "Connected to \(storeName) as \(account.userDisplayName)." }
        if account.totalSyncedGames > 0 { return "\(account.totalSyncedGames) \(storeName) games synced." }
        if !account.syncState.isEmpty { return "\(storeName) sync state: \(account.syncState)." }
        return "\(storeName) account connected."
    }

    private func detailRows(game: OPNCatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CatalogDetailRow(label: "Developer", value: game.developerName)
            CatalogDetailRow(label: "Publisher", value: game.publisherName)
            CatalogDetailRow(label: "Stores", value: game.storeLine)
            CatalogDetailRow(label: "Controls", value: game.supportedControls.joined(separator: ", "))
            CatalogDetailRow(label: "Features", value: game.featureLabels.joined(separator: ", "))
        }
    }
}

private struct CatalogDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        if !value.isEmpty {
            HStack(alignment: .top) {
                Text(label.uppercased())
                    .font(.nvidia(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 84, alignment: .leading)
                Text(value)
                    .font(.nvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct CatalogHeroRemoteImage: View {
    let url: URL?
    let contentMode: ContentMode
    let onScrimColorChange: (CatalogMarqueeScrimColor) -> Void

    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var hasFailed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if hasFailed {
                CatalogImageFallback()
            } else {
                CatalogImageFallback()
                    .overlay {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .task(id: url) { await loadImage() }
    }

    @MainActor
    private func loadImage() async {
        image = nil
        hasFailed = false
        guard let url else {
            onScrimColorChange(.black)
            return
        }

        onScrimColorChange(.black)
        isLoading = true
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                throw URLError(.badServerResponse)
            }
            guard let loadedImage = NSImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            image = loadedImage
            hasFailed = false
            isLoading = false
            onScrimColorChange(CatalogHeroImageMetadata.scrimColor(from: data) ?? .black)
        } catch {
            guard !Task.isCancelled else { return }
            image = nil
            hasFailed = true
            isLoading = false
            onScrimColorChange(.black)
        }
    }
}

private struct CatalogHeroVendorBackgroundScrim: View {
    let color: CatalogMarqueeScrimColor

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: color.color.opacity(0.00), location: 0.0000),
                .init(color: color.color.opacity(0.02), location: 0.0342),
                .init(color: color.color.opacity(0.05), location: 0.0668),
                .init(color: color.color.opacity(0.12), location: 0.0955),
                .init(color: color.color.opacity(0.20), location: 0.1230),
                .init(color: color.color.opacity(0.29), location: 0.1500),
                .init(color: color.color.opacity(0.39), location: 0.1752),
                .init(color: color.color.opacity(0.50), location: 0.2000),
                .init(color: color.color.opacity(0.61), location: 0.2248),
                .init(color: color.color.opacity(0.71), location: 0.2500),
                .init(color: color.color.opacity(0.80), location: 0.2770),
                .init(color: color.color.opacity(0.88), location: 0.3045),
                .init(color: color.color.opacity(0.95), location: 0.3332),
                .init(color: color.color.opacity(0.98), location: 0.3658),
                .init(color: color.color.opacity(1.00), location: 0.4000)
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }
}

private struct CatalogHeroVendorImageMask: View {
    var body: some View {
        VendorResourceImage(name: "Marquee_Hero_Image_Gradient", fileExtension: "svg")
            .scaledToFill()
    }
}

private struct CatalogHeroVendorGradientOverlays: View {
    let imageLeading: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [CatalogVendorLayout.mallSurface.opacity(0.00), CatalogVendorLayout.mallSurface.opacity(0.25)],
                    startPoint: .trailing,
                    endPoint: .leading
                )
                .frame(width: imageLeading)
                .frame(maxWidth: .infinity, alignment: .leading)

                LinearGradient(
                    colors: [CatalogVendorLayout.mallSurface.opacity(0.00), CatalogVendorLayout.mallSurface],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: proxy.size.height * 0.33)
                .offset(y: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CatalogMarqueeScrimColor: Equatable, Sendable {
    static let black = CatalogMarqueeScrimColor(red: 0, green: 0, blue: 0)

    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255)
    }

    var preferredTextColor: Color {
        red * 0.299 + green * 0.587 + blue * 0.114 > 150 ? .black : .white
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = value.hasPrefix("#") ? String(value.dropFirst()) : value
        let expanded: String
        if sanitized.count == 3 {
            expanded = sanitized.map { String(repeating: String($0), count: 2) }.joined()
        } else {
            expanded = sanitized
        }
        guard expanded.count == 6, let number = Int(expanded, radix: 16) else { return nil }
        red = Double((number >> 16) & 0xFF)
        green = Double((number >> 8) & 0xFF)
        blue = Double(number & 0xFF)
    }
}

private enum CatalogHeroImageMetadata {
    private struct Metadata: Decodable {
        let colors: Colors?
    }

    private struct Colors: Decodable {
        let left: String?
        let right: String?
        let bottom: String?
    }

    static func scrimColor(from data: Data) -> CatalogMarqueeScrimColor? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let metadataColor = metadataScrimColor(from: source) {
            return metadataColor
        }
        return sampledLeftEdgeColor(from: source)
    }

    private static func metadataScrimColor(from source: CGImageSource) -> CatalogMarqueeScrimColor? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let userComment = findUserComment(in: properties),
              let jsonStart = userComment.firstIndex(of: "{") else { return nil }
        let json = String(userComment[jsonStart...])
        guard let data = json.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              let hexColor = metadata.colors?.left ?? metadata.colors?.right ?? metadata.colors?.bottom else { return nil }
        return CatalogMarqueeScrimColor(hex: hexColor)
    }

    private static func findUserComment(in value: Any) -> String? {
        if let string = value as? String, string.contains("colors") {
            return string
        }
        if let data = value as? Data, let string = String(data: data, encoding: .utf8), string.contains("colors") {
            return string
        }
        if let dictionary = value as? [String: Any] {
            if let directValue = dictionary[kCGImagePropertyExifUserComment as String] {
                return findUserComment(in: directValue)
            }
            for nestedValue in dictionary.values {
                if let match = findUserComment(in: nestedValue) {
                    return match
                }
            }
        }
        if let array = value as? [Any] {
            let scalarValues = array.compactMap { $0 as? UInt8 }
            if scalarValues.count == array.count,
               let string = String(bytes: scalarValues, encoding: .utf8),
               string.contains("colors") {
                return string
            }
            for nestedValue in array {
                if let match = findUserComment(in: nestedValue) {
                    return match
                }
            }
        }
        return nil
    }

    private static func sampledLeftEdgeColor(from source: CGImageSource) -> CatalogMarqueeScrimColor? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 48
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drewImage = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else { return nil }

        let sampleWidth = min(max(width / 8, 1), width)
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0.0
        for y in 0..<height {
            for x in 0..<sampleWidth {
                let index = (y * width + x) * 4
                red += Double(pixels[index])
                green += Double(pixels[index + 1])
                blue += Double(pixels[index + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return CatalogMarqueeScrimColor(red: red / count, green: green / count, blue: blue / count)
    }
}

private struct CatalogRemoteImage: View {
    let url: URL?
    let contentMode: ContentMode

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode)
            case .failure:
                CatalogImageFallback()
            case .empty:
                CatalogImageFallback().overlay { ProgressView().controlSize(.small) }
            @unknown default:
                CatalogImageFallback()
            }
        }
    }
}

private struct CatalogImageFallback: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "play.rectangle.fill")
                .font(.nvidia(size: 34, weight: .bold))
                .foregroundStyle(Color.openNowGreen.opacity(0.78))
        }
    }
}

private struct CatalogMessageView: View {
    let message: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.openNowGreen)
            Text(message)
                .font(.nvidia(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.07))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }
}

private struct CatalogLoadingStrip: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Loading GeForce NOW catalog")
                .font(.nvidia(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.62))
            VendorIndeterminateProgressBar()
                .frame(width: 260, height: 4)
        }
        .padding(12)
        .background(Color.white.opacity(0.055))
    }
}

private struct CatalogDetailImageArrow: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VendorResourceImage(name: name, fileExtension: "svg")
                .scaledToFit()
                .frame(width: 34, height: 34)
                .frame(width: 48, height: 48)
                .background(.black.opacity(0.28), in: Circle())
                .overlay { Circle().stroke(Color.white.opacity(0.22), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

private struct FlowLayout: Layout {
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

private extension OPNCatalogGameObject {
    var catalogIdentity: String { CatalogViewModel.identity(for: self) }

    var bestHeroImageURL: String {
        if !heroImageUrl.isEmpty { return heroImageUrl }
        for key in ["MARQUEE_HERO_IMAGE", "HERO_IMAGE"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        return bestTileImageURL
    }

    var bestLogoImageURL: String {
        for key in ["GAME_LOGO", "LOGO", "TITLE_LOGO"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
            if let value = imageUrlsByType[key.lowercased()]?.first, !value.isEmpty { return value }
        }
        return ""
    }

    var bestTileImageURL: String {
        if !imageUrl.isEmpty { return imageUrl }
        for key in ["BOX_ART", "BOXART", "TILE", "GAME_BOX_ART", "HERO_IMAGE"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        if let value = screenshotUrls.first, !value.isEmpty { return value }
        return heroImageUrl
    }

    var bestWideImageURL: String {
        for key in ["TV_BANNER"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        return ""
    }

    var bestDetailImageURL: String {
        for key in ["HERO_IMAGE", "MARQUEE_HERO_IMAGE", "FEATURE_IMAGE", "KEY_ART", "TV_BANNER"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        if !heroImageUrl.isEmpty { return heroImageUrl }
        if let value = screenshotUrls.first, !value.isEmpty { return value }
        return imageUrl
    }

    var detailImageURLs: [String] {
        var values: [String] = []
        var seen = Set<String>()

        func append(_ value: String) {
            guard !value.isEmpty, !seen.contains(value) else { return }
            seen.insert(value)
            values.append(value)
        }

        func appendValues(forKey key: String) {
            for value in imageUrlsByType[key] ?? [] { append(value) }
            for value in imageUrlsByType[key.lowercased()] ?? [] { append(value) }
        }

        appendValues(forKey: "SCREENSHOTS")
        for value in screenshotUrls { append(value) }
        append(heroImageUrl)
        append(imageUrl)
        append(bestDetailImageURL)
        return values
    }

    var mallDisplayTitle: String {
        let displayTitle = shortName.isEmpty ? title : shortName
        return displayTitle.isEmpty ? "GEFORCE NOW" : displayTitle.uppercased()
    }

    var primaryStoreLabel: String {
        if let store = availableStores.first, !store.isEmpty { return store.capitalized }
        if let store = variants.first?.appStore, !store.isEmpty { return store.capitalized }
        return "GeForce NOW"
    }

    var ratingLabel: String {
        contentRatings.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    var genreLine: String { genres.prefix(3).joined(separator: " / ") }

    var storeLine: String {
        let stores = availableStores.isEmpty ? variants.map(\.appStore) : availableStores
        return stores.filter { !$0.isEmpty }.map { $0.uppercased() }.joined(separator: ", ")
    }

    var detailChips: [String] {
        var chips: [String] = []
        if isInLibrary { chips.append("IN LIBRARY") }
        if !membershipTierLabel.isEmpty { chips.append(membershipTierLabel.uppercased()) }
        if !playabilityState.isEmpty { chips.append(playabilityState.replacingOccurrences(of: "_", with: " ").uppercased()) }
        chips.append(contentsOf: genres.prefix(3).map { $0.uppercased() })
        return chips.isEmpty ? ["CLOUD READY"] : chips
    }
}
