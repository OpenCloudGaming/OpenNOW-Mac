//  CatalogView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import Combine
import Common
import CoreText
import CryptoKit
import ImageIO
import OpenNOWGameServices
import SwiftUI
import WebRTCMedia

private enum CatalogVendorLayout {
    static let windowTopInset: CGFloat = 10
    static let appBarHeight: CGFloat = 56
    static let searchFieldHeight: CGFloat = 40
    static let searchTopGapHeight: CGFloat = (appBarHeight - searchFieldHeight) / 2
    static let appBarBackground = OpenNOWDesign.Surface.appBar
    static let mallSurface = OpenNOWDesign.Surface.app
    static let tileTray = OpenNOWDesign.Surface.tileTray
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
    static let detailPanelHeight: CGFloat = 500
    static let mainMenuWidth: CGFloat = 344

    static func heroHeight(for width: CGFloat) -> CGFloat {
        width > 0 ? min(width * heroAspectRatio, heroFallbackHeight) : heroFallbackHeight
    }

    static func heroImageLeading(for width: CGFloat) -> CGFloat {
        width > 0 ? OpenNOWDesign.clamped(56 + width * 0.14, minimum: 120, maximum: 280) : 258
    }

    static func searchWidth(for width: CGFloat) -> CGFloat {
        OpenNOWDesign.clamped(width * 0.42, minimum: 280, maximum: 540)
    }

    static func launchPanelWidth(for width: CGFloat) -> CGFloat {
        OpenNOWDesign.clamped(width - 64, minimum: 360, maximum: 640)
    }

    static func heroTextLeading(for width: CGFloat) -> CGFloat {
        OpenNOWDesign.clamped(width * 0.09, minimum: 42, maximum: 108)
    }

    static func heroTextWidth(for width: CGFloat) -> CGFloat {
        OpenNOWDesign.clamped(width * 0.39, minimum: 320, maximum: 470)
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
    let onWindowTitleChange: (String?) -> Void

    @Binding private var pendingGameShortcut: GFNGameShortcut?

    @StateObject private var viewModel: CatalogViewModel
    @State private var showsMainMenu = false

    init(
        account: LoginAccount,
        session: LoginSession,
        accounts: [LoginAccount],
        pendingGameShortcut: Binding<GFNGameShortcut?>,
        onSwitch: @escaping (LoginAccount) -> Void,
        onSignOut: @escaping () -> Void,
        onForget: @escaping (LoginAccount) -> Void,
        onRefreshAuth: @escaping () -> Void,
        onWindowTitleChange: @escaping (String?) -> Void
    ) {
        self.accounts = accounts
        self.onSwitch = onSwitch
        self.onSignOut = onSignOut
        self.onForget = onForget
        self.onRefreshAuth = onRefreshAuth
        self.onWindowTitleChange = onWindowTitleChange
        _pendingGameShortcut = pendingGameShortcut
        _viewModel = StateObject(wrappedValue: CatalogViewModel(account: account, session: session, onRefreshAuth: onRefreshAuth))
    }

    var body: some View {
        ZStack {
            if let streamConfiguration = viewModel.activeStreamConfiguration {
                ZStack {
                    WebRTCMediaStreamView(
                        configuration: streamConfiguration,
                        onProgress: { progress in viewModel.updateActiveStreamProgress(progress) },
                        onEnd: { success, message, report in
                            viewModel.finishActiveStream(success: success, message: message, report: report)
                        }
                    )
                    .id(streamConfiguration.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.all)

                    if viewModel.isStreamLaunchLoadingVisible {
                        VendorStreamLaunchLoadingOverlay(viewModel: viewModel)
                            .transition(.opacity)
                            .zIndex(10)
                            .ignoresSafeArea(.all)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.all)
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    CatalogTopBar(viewModel: viewModel, accounts: accounts, showsMainMenu: $showsMainMenu, onSwitch: onSwitch, onSignOut: onSignOut, onForget: onForget)
                    if viewModel.selectedMainPage == .settings {
                        SettingsView(viewModel: viewModel)
                    } else if viewModel.selectedMainPage == .recordings {
                        RecordingsView()
                    } else {
                        CatalogContentView(viewModel: viewModel)
                    }
                }
                .padding(.top, CatalogVendorLayout.windowTopInset)
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

                if viewModel.isStorePickerVisible {
                    CatalogStorePickerOverlay(viewModel: viewModel)
                        .transition(.opacity)
                        .zIndex(18)
                }
            }
        }
        .background(Color.gfnBackgroundGreen)
        .background(StreamWindowAspectConfigurator(aspectRatio: viewModel.streamProfile.aspectRatio, isLocked: viewModel.activeStreamConfiguration != nil))
        .task {
            viewModel.loadIfNeeded()
            consumePendingGameShortcut()
        }
        .onChange(of: pendingGameShortcut) { _, _ in consumePendingGameShortcut() }
        .onChange(of: viewModel.activeStreamConfiguration?.id) { _, _ in updateWindowTitleForActiveStream() }
        .onDisappear { onWindowTitleChange(nil) }
        .preferredColorScheme(.dark)
    }

    private func updateWindowTitleForActiveStream() {
        guard let configuration = viewModel.activeStreamConfiguration else {
            onWindowTitleChange(nil)
            return
        }
        let title = configuration.title.trimmingCharacters(in: .whitespacesAndNewlines)
        onWindowTitleChange("\(title.isEmpty ? "GeForce NOW" : title) on GeForce NOW")
    }

    private func consumePendingGameShortcut() {
        guard let shortcut = pendingGameShortcut else { return }
        OpenNOWLog.info(.shortcut, "CatalogView consuming pending shortcut cmsId=\(shortcut.cmsId) shortName=\(shortcut.shortName) title=\(shortcut.lookupTitle)")
        pendingGameShortcut = nil
        viewModel.openGameShortcut(shortcut)
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

private struct StreamWindowAspectConfigurator: NSViewRepresentable {
    let aspectRatio: Double
    let isLocked: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowAspectView {
        let view = WindowAspectView(frame: .zero)
        let coordinator = context.coordinator
        view.onWindowChanged = { window in coordinator.attach(window) }
        return view
    }

    func updateNSView(_ view: WindowAspectView, context: Context) {
        context.coordinator.update(aspectRatio: aspectRatio, isLocked: isLocked)
    }

    static func dismantleNSView(_ nsView: WindowAspectView, coordinator: Coordinator) {
        nsView.onWindowChanged = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var aspectRatio: Double = 0
        private var isLocked = false
        private var appliedAspectRatio: Double?
        private var appliedLockState: Bool?
        private var fullScreenTransitionObserverTokens: [NSObjectProtocol] = []
        private var isFullScreenTransitioning = false

        func attach(_ window: NSWindow?) {
            guard self.window !== window else { return }
            clearAppliedAspectRatio()
            removeFullScreenTransitionObservers()
            self.window = window
            appliedAspectRatio = nil
            appliedLockState = nil
            isFullScreenTransitioning = false
            addFullScreenTransitionObservers(for: window)
            apply()
        }

        func update(aspectRatio: Double, isLocked: Bool) {
            self.aspectRatio = aspectRatio
            self.isLocked = isLocked
            apply()
        }

        func detach() {
            clearAppliedAspectRatio()
            removeFullScreenTransitionObservers()
            window = nil
            appliedAspectRatio = nil
            appliedLockState = nil
            isFullScreenTransitioning = false
        }

        private func apply() {
            guard let window else { return }
            guard isLocked, aspectRatio.isFinite, aspectRatio > 0 else {
                clearAppliedAspectRatio()
                appliedAspectRatio = nil
                appliedLockState = false
                return
            }

            guard !isFullScreenTransitioning, !window.styleMask.contains(.fullScreen) else {
                clearAppliedAspectRatio()
                return
            }

            let alreadyApplied = appliedLockState == true && appliedAspectRatio.map { abs($0 - aspectRatio) <= 0.001 } == true
            guard !alreadyApplied else { return }
            window.contentAspectRatio = NSSize(width: aspectRatio, height: 1)
            appliedAspectRatio = aspectRatio
            appliedLockState = true
        }

        private func clearAppliedAspectRatio() {
            if appliedLockState == true {
                window?.contentAspectRatio = .zero
            }
            appliedAspectRatio = nil
            appliedLockState = false
        }

        private func addFullScreenTransitionObservers(for window: NSWindow?) {
            guard let window else { return }
            let notificationCenter = NotificationCenter.default
            let willEnterToken = notificationCenter.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.beginFullScreenTransition()
                }
            }
            let willExitToken = notificationCenter.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.beginFullScreenTransition()
                }
            }
            let didExitToken = notificationCenter.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.finishFullScreenTransition()
                }
            }
            fullScreenTransitionObserverTokens = [willEnterToken, willExitToken, didExitToken]
        }

        private func removeFullScreenTransitionObservers() {
            let notificationCenter = NotificationCenter.default
            for token in fullScreenTransitionObserverTokens {
                notificationCenter.removeObserver(token)
            }
            fullScreenTransitionObserverTokens = []
        }

        private func beginFullScreenTransition() {
            isFullScreenTransitioning = true
            clearAppliedAspectRatio()
        }

        private func finishFullScreenTransition() {
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in
                    self?.isFullScreenTransitioning = false
                    self?.apply()
                }
            }
        }
    }

    final class WindowAspectView: NSView {
        var onWindowChanged: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
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
                    if viewModel.canResumeActiveLaunchSession {
                        Button("RESUME SESSION") { viewModel.resumeActiveLaunchSession() }
                            .buttonStyle(VendorLaunchSecondaryButtonStyle())
                    }
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

                if let screenshotURL = loadingScreenshotURL {
                    AsyncImage(url: screenshotURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                        default:
                            EmptyView()
                        }
                    }
                    .transition(.opacity)
                }

                Rectangle()
                    .fill(.black.opacity(0.42))

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

                    Button("CANCEL STREAM") { viewModel.cancelActiveStreamLaunch() }
                        .buttonStyle(VendorLaunchSecondaryButtonStyle())
                        .accessibilityLabel("Cancel stream launch")

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

    private var loadingScreenshotURL: URL? {
        guard let configuration = viewModel.activeStreamConfiguration else { return nil }
        let urls = (configuration.metadata["loadingScreenshotUrls"] ?? "")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else { return nil }
        let index = abs(configuration.id.uuidString.hashValue) % urls.count
        return URL(string: urls[index])
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
                    Text("LAUNCH STATUS")
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
        .frame(minWidth: 360, idealWidth: 640, maxWidth: 640)
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
        let presentation = CatalogErrorPresentation(rawMessage: message)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.nvidia(size: 12, weight: .bold))
                if let hint = presentation.hint {
                    Text(hint)
                        .font(.nvidia(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
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
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                HStack(spacing: 18) {
                    Button { showsMainMenu.toggle() } label: {
                        CatalogHamburgerLabel(isOpen: showsMainMenu)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsMainMenu ? "Close main menu" : "Open main menu")
                    Text(mainPageTitle)
                        .font(.nvidia(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                }
                .padding(.leading, 86)

                if viewModel.selectedMainPage == .games {
                    CatalogVendorLayout.appBarBackground
                        .frame(width: CatalogVendorLayout.searchWidth(for: proxy.size.width), height: CatalogVendorLayout.windowTopInset + CatalogVendorLayout.searchTopGapHeight)
                        .offset(y: -CatalogVendorLayout.windowTopInset)
                        .frame(width: CatalogVendorLayout.searchWidth(for: proxy.size.width), height: CatalogVendorLayout.appBarHeight, alignment: .top)

                    catalogSearchField
                        .frame(width: CatalogVendorLayout.searchWidth(for: proxy.size.width))
                } else {
                    Text(viewModel.selectedMainPage == .recordings ? "Saved gameplay videos" : viewModel.selectedSettingsPage.title)
                        .font(.nvidia(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.70))
                        .tracking(1.1)
                        .frame(width: CatalogVendorLayout.searchWidth(for: proxy.size.width))
                }

                HStack(spacing: 24) {
                    Spacer()
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
                            CatalogAccountAvatar(account: viewModel.account, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(viewModel.account.displayName)
                                    .font(.nvidia(size: 15, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(viewModel.subscriptionStatus.membershipTier)
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
        }
        .frame(height: CatalogVendorLayout.appBarHeight)
        .background(CatalogVendorLayout.appBarBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.42)).frame(height: 1) }
    }

    private var mainPageTitle: String {
        switch viewModel.selectedMainPage {
        case .games: return viewModel.selectedCatalogDestination.title
        case .recordings: return "Recordings"
        case .settings: return "Settings"
        }
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
        .frame(height: CatalogVendorLayout.searchFieldHeight)
        .background(Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255))
        .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
    }
}

private struct CatalogAccountAvatar: View {
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
        .background((isOpen || isHovering) ? Color.black.opacity(0.22) : Color.clear)
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
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { isPresented = false }

                CatalogMainMenuPanel(viewModel: viewModel, isPresented: $isPresented, onSignOut: onSignOut, availableHeight: max(360, proxy.size.height - CatalogVendorLayout.appBarHeight - CatalogVendorLayout.windowTopInset))
                    .padding(.top, CatalogVendorLayout.appBarHeight + CatalogVendorLayout.windowTopInset)
                    .padding(.leading, 0)
            }
        }
        .onExitCommand { isPresented = false }
    }
}

private struct CatalogMainMenuPanel: View {
    @ObservedObject var viewModel: CatalogViewModel
    @Binding var isPresented: Bool
    let onSignOut: () -> Void
    let availableHeight: CGFloat

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

            CatalogMainMenuPlaytimeCard(status: viewModel.subscriptionStatus)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        CatalogMainMenuSectionLabel("NAVIGATION")
                        ForEach(CatalogDestination.allCases) { destination in
                            CatalogMainMenuRow(
                                title: destination.title,
                                subtitle: catalogDestinationSubtitle(destination),
                                systemImage: catalogDestinationIcon(destination),
                                isActive: viewModel.selectedMainPage == .games && viewModel.selectedCatalogDestination == destination
                            ) {
                                viewModel.showCatalogDestination(destination)
                                isPresented = false
                            }
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
                    .padding(.bottom, 18)
                }
            }

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
        .frame(width: CatalogVendorLayout.mainMenuWidth, height: availableHeight, alignment: .topLeading)
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

private struct CatalogMainMenuPlaytimeCard: View {
    let status: CatalogSubscriptionStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("REMAINING PLAYTIME")
                    .font(.nvidia(size: 10, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.46))
                Spacer(minLength: 0)
                Text(status.membershipTier.uppercased())
                    .font(.nvidia(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.black.opacity(0.86))
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Color.openNowGreen)
            }
            Text(status.remainingPlaytimeText)
                .font(.nvidia(size: 22, weight: .bold))
                .foregroundStyle(status.isAvailable ? .white.opacity(0.95) : .white.opacity(0.56))
                .lineLimit(1)
            Text(status.usageText)
                .font(.nvidia(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.56))
                .lineLimit(1)
        }
        .padding(14)
        .background(Color.white.opacity(0.055))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
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
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: compact ? 38 : 50)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isActive ? Color.openNowGreen : Color.clear)
                    .frame(width: 3)
            }
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
        if isActive { return .black.opacity(0.86) }
        if role == .destructive { return Color(red: 1, green: 0.54, blue: 0.50) }
        return .white.opacity(isHovering ? 0.94 : 0.72)
    }
}

private struct CatalogStorePickerOverlay: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        if let game = viewModel.selectedGame {
            GeometryReader { proxy in
                ZStack(alignment: .topTrailing) {
                    CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestDetailImageURL, width: 1920), contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                    Color.black.opacity(0.68)
                    LinearGradient(colors: [.black.opacity(0.42), .clear, .black.opacity(0.58)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.black.opacity(0.18), .clear, .black.opacity(0.52)], startPoint: .top, endPoint: .bottom)

                    HStack(alignment: .top, spacing: max(52, min(proxy.size.width * 0.07, 104))) {
                        CatalogStorePickerPoster(viewModel: viewModel, game: game)
                            .padding(.top, max(88, proxy.size.height * 0.17))

                        VStack(alignment: .leading, spacing: 0) {
                            header(game: game)
                            content(game: game)
                        }
                        .frame(width: min(650, max(500, proxy.size.width * 0.38)), alignment: .leading)
                        .padding(.top, max(92, proxy.size.height * 0.17))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, max(38, min(proxy.size.width * 0.08, 150)))

                    Button { viewModel.closeStorePicker() } label: {
                        Image(systemName: "xmark")
                            .font(.nvidia(size: 24, weight: .regular))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 14)
                    .padding(.trailing, 18)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .background(Color.black)
        }
    }

    private func header(game: OPNCatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(game.title.isEmpty ? "Selected Game" : game.title)
                .font(.nvidia(size: 17, weight: .bold))
                .foregroundStyle(.white.opacity(0.96))
                .lineLimit(1)
                .padding(.bottom, 10)
            FlowLayout(spacing: 8) {
                if viewModel.ownershipFlowStage == .success, let variant = selectedVariant(game: game) {
                    storeInlineLabel(variant: variant, owned: true)
                } else {
                    Text("PC Digital Version")
                        .font(.nvidia(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                    if viewModel.ownershipFlowStage == .manualMark, let variant = selectedVariant(game: game) {
                        Text("|")
                            .font(.nvidia(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                        storeInlineLabel(variant: variant, owned: false)
                    }
                }
            }
            Rectangle()
                .fill(Color.white.opacity(0.24))
                .frame(height: 1)
                .padding(.top, 14)
                .padding(.bottom, 26)
        }
    }

    @ViewBuilder
    private func content(game: OPNCatalogGameObject) -> some View {
        switch viewModel.ownershipFlowStage {
        case .resyncing:
            resyncingContent(game: game)
        case .storeSelection:
            storeSelectionContent(game: game)
        case .manualMark:
            manualMarkContent(game: game)
        case .success:
            successContent(game: game)
        case .hidden:
            storeSelectionContent(game: game)
        }
    }

    private func resyncingContent(game: OPNCatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Finding where you own this game")
                .font(.nvidia(size: 24, weight: .bold))
                .foregroundStyle(.white.opacity(0.96))
                .padding(.bottom, 12)
            Text("Checking all your connected accounts to sync this game. This may take some time...")
                .font(.nvidia(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
            VStack(spacing: 18) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.7)
                    .tint(Color.openNowGreen)
                Text(viewModel.ownershipFlowMessage.isEmpty ? "Syncing connected game libraries..." : viewModel.ownershipFlowMessage)
                    .font(.nvidia(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
            }
            .frame(maxWidth: .infinity, minHeight: 330, alignment: .center)
            HStack {
                Spacer()
                Button("STOP RESYNC") { viewModel.stopOwnershipResync() }
                    .buttonStyle(CatalogOwnershipTextButtonStyle())
            }
        }
    }

    private func storeSelectionContent(game: OPNCatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose a game store")
                .font(.nvidia(size: 24, weight: .bold))
                .foregroundStyle(.white.opacity(0.96))
                .padding(.bottom, 12)
            Text("Where do you own this game and want to play?")
                .font(.nvidia(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.bottom, 32)
            CatalogStorePickerSection(label: "Game stores:") {
                VStack(alignment: .leading, spacing: 19) {
                    ForEach(Array(game.variants.enumerated()), id: \.offset) { index, variant in
                        CatalogStorePickerRow(
                            title: storeTitle(variant),
                            iconURL: storeIconURL(variant),
                            status: storeStatus(game: game, variant: variant),
                            isSelected: selectedIndex(game: game) == index,
                            isAvailable: variantIsOwned(game: game, variant: variant)
                        ) {
                            viewModel.selectGameStoreVariant(at: index)
                        }
                    }
                }
            }
        }
    }

    private func manualMarkContent(game: OPNCatalogGameObject) -> some View {
        let variant = selectedVariant(game: game)
        let storeName = variant.map(storeTitle) ?? "this store"
        return VStack(alignment: .leading, spacing: 0) {
            Text("Mark as owned")
                .font(.nvidia(size: 24, weight: .bold))
                .foregroundStyle(.white.opacity(0.96))
                .padding(.bottom, 14)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Press CONTINUE to manually mark this game as owned only if you have this in your \(storeName) library or it may fail to launch. Don't own it? ")
                    .font(.nvidia(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Button("Get this game.") { viewModel.openStoreForSelectedVariant() }
                    .buttonStyle(.plain)
                    .font(.nvidia(size: 15, weight: .bold))
                    .foregroundStyle(Color.openNowGreen)
            }
            .lineLimit(3)
            .frame(maxWidth: 650, alignment: .leading)
            Spacer(minLength: 300)
            HStack(spacing: 28) {
                Spacer()
                Button("CONTINUE") { viewModel.confirmSelectedVariantOwned() }
                    .buttonStyle(CatalogOwnershipTextButtonStyle())
                Button("EXIT") { viewModel.closeStorePicker() }
                    .buttonStyle(CatalogOwnershipPrimaryButtonStyle())
            }
        }
    }

    private func successContent(game: OPNCatalogGameObject) -> some View {
        let variant = selectedVariant(game: game)
        let storeName = variant.map(storeTitle) ?? "Game Store"
        let account = variant.flatMap { viewModel.accountStatus(forStore: $0.appStore) }
        return VStack(alignment: .leading, spacing: 0) {
            Text("You're all set to play")
                .font(.nvidia(size: 24, weight: .bold))
                .foregroundStyle(.white.opacity(0.96))
                .padding(.bottom, 30)
            HStack(alignment: .top, spacing: 16) {
                if let variant { storeIconView(iconURL: storeIconURL(variant)) }
                VStack(alignment: .leading, spacing: 10) {
                    Text(successAccountTitle(storeName: storeName, account: account))
                        .font(.nvidia(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.96))
                    Text(successAccountSubtitle(storeName: storeName, account: account))
                        .font(.nvidia(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.74))
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.nvidia(size: 15, weight: .bold))
                        Text(successSyncText(account: account))
                            .font(.nvidia(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.74))
                }
            }
            Spacer(minLength: 330)
            HStack {
                Spacer()
                Button("DONE") { viewModel.finishOwnershipFlow() }
                    .buttonStyle(CatalogOwnershipPrimaryButtonStyle())
            }
        }
    }

    private func selectedIndex(game: OPNCatalogGameObject) -> Int {
        let preferred = viewModel.selectedVariantIndex >= 0 ? viewModel.selectedVariantIndex : CatalogViewModel.preferredVariantIndex(for: game)
        return max(preferred, 0)
    }

    private func storeTitle(_ variant: OPNCatalogGameVariantObject) -> String {
        if !variant.appStoreLabel.isEmpty { return variant.appStoreLabel }
        return variant.appStore.isEmpty ? "GeForce NOW" : viewModel.displayName(forStore: variant.appStore)
    }

    private func storeIconURL(_ variant: OPNCatalogGameVariantObject) -> String {
        variant.appStoreSmallImageUrl
    }

    private func storeStatus(game: OPNCatalogGameObject, variant: OPNCatalogGameVariantObject) -> String {
        if variantIsOwned(game: game, variant: variant) { return "Owned" }
        let status = variant.serviceStatus.lowercased()
        if status.contains("not") || status.contains("unavailable") || status.contains("unsupported") { return "Game not found" }
        return ""
    }

    private func variantIsOwned(game: OPNCatalogGameObject, variant: OPNCatalogGameVariantObject) -> Bool {
        variant.inLibrary || variant.librarySelected || (game.isInLibrary && game.variants.count == 1)
    }

    private func selectedVariant(game: OPNCatalogGameObject) -> OPNCatalogGameVariantObject? {
        let index = selectedIndex(game: game)
        guard game.variants.indices.contains(index) else { return nil }
        return game.variants[index]
    }

    private func storeInlineLabel(variant: OPNCatalogGameVariantObject, owned: Bool) -> some View {
        HStack(spacing: 8) {
            storeIconView(iconURL: storeIconURL(variant))
            Text(storeTitle(variant))
                .font(.nvidia(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
            if owned {
                Text("Owned")
                    .font(.nvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.black.opacity(0.24))
                Image(systemName: "checkmark")
                    .font(.nvidia(size: 13, weight: .bold))
                    .foregroundStyle(Color.openNowGreen)
            }
        }
    }

    @ViewBuilder
    private func storeIconView(iconURL: String) -> some View {
        if !iconURL.isEmpty {
            CatalogStoreIconImage(url: URL(string: iconURL), size: 20)
                .frame(width: 20, height: 20)
        }
    }

    private func successAccountTitle(storeName: String, account: CatalogStoreAccount?) -> String {
        guard let account, !account.userDisplayName.isEmpty else { return storeName }
        return "\(storeName) | \(account.userDisplayName)"
    }

    private func successAccountSubtitle(storeName: String, account: CatalogStoreAccount?) -> String {
        account?.hasAccountLinkingData == true ? "Your \(storeName) account is connected." : "Your game store is selected."
    }

    private func successSyncText(account: CatalogStoreAccount?) -> String {
        guard let account else { return "Manual ownership selected" }
        if account.hasAccountSyncingData { return "Automatic game library sync enabled" }
        return "Automatic sign-in available when supported"
    }
}

private struct CatalogOwnershipTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.nvidia(size: 14, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.62 : 0.96))
            .frame(height: 46)
            .padding(.horizontal, 8)
    }
}

private struct CatalogOwnershipPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.nvidia(size: 14, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.black.opacity(0.88))
            .frame(width: 112, height: 46)
            .background(Color.openNowGreen.opacity(configuration.isPressed ? 0.78 : 1))
    }
}

private struct CatalogStorePickerPoster: View {
    @ObservedObject var viewModel: CatalogViewModel
    let game: OPNCatalogGameObject

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestStorePickerPosterURL, width: 720), contentMode: .fill)
                .frame(width: 292, height: 410)
                .clipped()
        }
        .frame(width: 292, height: 410)
        .shadow(color: .black.opacity(0.42), radius: 20, x: 0, y: 10)
    }
}

private struct CatalogStorePickerSection<Content: View>: View {
    let label: String
    private let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            Text(label)
                .font(.nvidia(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 132, alignment: .leading)
                .padding(.top, 3)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CatalogStorePickerRow: View {
    let title: String
    let iconURL: String
    let status: String
    let isSelected: Bool
    let isAvailable: Bool
    let action: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .onHover { isHovering = $0 }
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            storeIcon
            Text(title)
                .font(.nvidia(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 232, alignment: .leading)
            if !status.isEmpty {
                Text(status)
                    .font(.nvidia(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 0)
                    .frame(height: 24)
                if isAvailable {
                    Image(systemName: "checkmark")
                        .font(.nvidia(size: 14, weight: .bold))
                        .foregroundStyle(Color.openNowGreen)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .padding(.horizontal, isHovering ? 8 : 0)
        .background(Color.white.opacity(isHovering ? 0.08 : 0))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var storeIcon: some View {
        if !iconURL.isEmpty {
            CatalogStoreIconImage(url: URL(string: iconURL), size: 22)
                .frame(width: 22, height: 22)
        } else {
            Color.clear.frame(width: 22, height: 22)
        }
    }
}

private struct CatalogStoreIconImage: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        CatalogCachedImageView(url: url, contentMode: .fit, placeholder: Color.clear, failure: Color.clear)
            .frame(width: size, height: size)
    }
}

private struct CatalogContentView: View {
    @ObservedObject var viewModel: CatalogViewModel
    @State private var heroIndex = 0
    @State private var heroAutoScrollEnabled = true
    @State private var isPointerInsideDetailPanel = false
    @State private var showAllSection: CatalogSectionModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let heroTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let heroes = heroGames
        let hero = heroes.indices.contains(heroIndex) ? heroes[heroIndex] : heroes.first
        let sections = viewModel.catalogSections
        let isGridDestination = shouldUseGrid(for: viewModel.selectedCatalogDestination)
        ScrollViewReader { proxy in
            ZStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        if hero != nil && !isGridDestination {
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
                        if isGridDestination, let section = sections.first {
                            CatalogDestinationGridView(viewModel: viewModel, section: section)
                            if selectedGameBelongs(to: section), let detailAnchor = selectedDetailScrollAnchor {
                                GameDetailPanel(viewModel: viewModel)
                                    .padding(.top, -10)
                                    .padding(.bottom, 22)
                                    .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin)
                                    .onHover { isPointerInsideDetailPanel = $0 }
                                    .id(detailAnchor)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        } else {
                            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                                let showsDetail = shouldShowDetail(afterSectionAt: index, sections: sections)
                                if showsDetail, let railAnchor = selectedRailScrollAnchor {
                                    Color.clear
                                        .frame(height: 0)
                                        .id(railAnchor)
                                }
                                CatalogRailView(viewModel: viewModel, section: section, onShowAll: { showAllSection = section })
                                if showsDetail, let detailAnchor = selectedDetailScrollAnchor {
                                    GameDetailPanel(viewModel: viewModel)
                                        .padding(.top, -8)
                                        .padding(.bottom, 22)
                                        .onHover { isPointerInsideDetailPanel = $0 }
                                        .id(detailAnchor)
                                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                                }
                            }
                        }

                        if sections.isEmpty && !viewModel.isLoading && !viewModel.isLoadingPanels {
                            CatalogEmptyDestinationView(viewModel: viewModel, destination: viewModel.selectedCatalogDestination)
                                .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin)
                                .padding(.top, viewModel.selectedCatalogDestination == .home ? 52 : 118)
                        }
                    }
                    .padding(.bottom, 44)
                }
                .background(
                    Color.gfnBackgroundGreen
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.closeGameDetailsFromBackground() }
                )
                .simultaneousGesture(TapGesture().onEnded {
                    guard viewModel.selectedGame != nil, !isPointerInsideDetailPanel else { return }
                    viewModel.closeGameDetailsFromBackground()
                })

                if (viewModel.isLoading || viewModel.isLoadingPanels) && sections.isEmpty {
                    VendorSplashLoadingView()
                        .transition(.opacity)
                }

                if let showAllSection {
                    CatalogShowAllOverlay(
                        viewModel: viewModel,
                        section: showAllSection,
                        onDismiss: { self.showAllSection = nil },
                        onSelect: { game in
                            viewModel.selectGame(game, inSection: showAllSection.id)
                            self.showAllSection = nil
                        }
                    )
                    .transition(.opacity)
                    .zIndex(30)
                }
            }
            .onChange(of: selectedRailScrollAnchor) { _, anchor in
                scrollToSelectedRail(anchor, proxy: proxy)
            }
            .onChange(of: viewModel.selectedGameRevealRequest) { _, _ in
                scrollToSelectedRail(selectedRailScrollAnchor, proxy: proxy)
            }
        }
        .background(Color.gfnBackgroundGreen)
        .onReceive(heroTimer) { _ in
            guard !reduceMotion, heroAutoScrollEnabled, heroes.count > 1 else { return }
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
        viewModel.heroRotationGames
    }

    private var selectedRailScrollAnchor: String? {
        guard let selectedGame = viewModel.selectedGame else { return nil }
        return "rail-\(viewModel.selectedSectionId)-\(selectedGame.catalogIdentity)"
    }

    private var heroIdentityList: [String] {
        heroGames.map { CatalogViewModel.identity(for: $0) }
    }

    private var selectedDetailScrollAnchor: String? {
        guard let selectedGame = viewModel.selectedGame else { return nil }
        return "detail-\(viewModel.selectedSectionId)-\(selectedGame.catalogIdentity)"
    }

    private func shouldUseGrid(for destination: CatalogDestination) -> Bool {
        !viewModel.isBrowseMode && (destination == .library || destination == .favorites)
    }

    private func selectedGameBelongs(to section: CatalogSectionModel) -> Bool {
        guard let selectedGame = viewModel.selectedGame else { return false }
        return section.games.contains { CatalogViewModel.looseIdentityMatches($0, selectedGame) }
    }

    private func scrollToSelectedRail(_ anchor: String?, proxy: ScrollViewProxy) {
        guard let anchor else { return }
        scrollToSelectedRail(anchor, proxy: proxy, remainingDeferredPasses: 2)
    }

    private func scrollToSelectedRail(_ anchor: String, proxy: ScrollViewProxy, remainingDeferredPasses: Int) {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.24)) {
                proxy.scrollTo(anchor, anchor: .top)
            }
            if remainingDeferredPasses > 0 {
                scrollToSelectedRail(anchor, proxy: proxy, remainingDeferredPasses: remainingDeferredPasses - 1)
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
                let textWidth = CatalogVendorLayout.heroTextWidth(for: proxy.size.width)
                ZStack(alignment: .bottom) {
                    CatalogHeroVendorBackgroundScrim(color: scrimColor)
                    CatalogHeroRemoteImage(url: viewModel.optimizedImageURL(game.bestMarqueeHeroImageURL, width: 1920), contentMode: .fill) { color in
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
                    .frame(width: textWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, proxy.size.width < 760 ? 76 : 102)
                    .padding(.leading, CatalogVendorLayout.heroTextLeading(for: proxy.size.width))

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
            CatalogCachedImageView(url: logoURL, contentMode: .fit, placeholder: fallbackTitle.opacity(0), failure: fallbackTitle)
                .frame(maxWidth: 390, maxHeight: 150)
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

private struct CatalogEmptyDestinationView: View {
    @ObservedObject var viewModel: CatalogViewModel
    let destination: CatalogDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.nvidia(size: 22, weight: .bold))
                    .foregroundStyle(Color.openNowGreen)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.nvidia(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.nvidia(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
            HStack(spacing: 10) {
                Button(primaryActionTitle) { primaryAction() }
                    .buttonStyle(VendorGetInButtonStyle())
                if viewModel.isBrowseMode {
                    Button("CLEAR FILTERS") { viewModel.clearSearchAndFilters() }
                        .buttonStyle(VendorLaunchSecondaryButtonStyle())
                }
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(maxWidth: 620, alignment: .leading)
        .background(Color.white.opacity(0.055))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }

    private var icon: String {
        switch destination {
        case .home: return "gamecontroller.fill"
        case .library: return "rectangle.stack.fill"
        case .favorites: return "heart.fill"
        }
    }

    private var title: String {
        switch destination {
        case .home: return "No games to show"
        case .library: return "Your library is empty"
        case .favorites: return "No favorites yet"
        }
    }

    private var message: String {
        switch destination {
        case .home: return "Refresh the catalog or adjust search and filters to find supported GeForce NOW games."
        case .library: return "Connect or sync your game store accounts to populate My Library."
        case .favorites: return "Open a game detail panel and use the heart button to add it to My Favorites."
        }
    }

    private var primaryActionTitle: String {
        switch destination {
        case .home: return viewModel.isBrowseMode ? "REFRESH" : "REFRESH CATALOG"
        case .library: return "OPEN CONNECTIONS"
        case .favorites: return "BROWSE GAMES"
        }
    }

    private func primaryAction() {
        switch destination {
        case .home:
            viewModel.refresh()
        case .library:
            viewModel.showSettings(.connections)
        case .favorites:
            viewModel.showCatalogDestination(.home)
        }
    }
}

private struct CatalogRailView: View {
    @ObservedObject var viewModel: CatalogViewModel
    let section: CatalogSectionModel
    let onShowAll: () -> Void
    @State private var scrollIndex = 0
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var viewportWidth: CGFloat = 0

    private var coordinateSpaceName: String { "catalog-rail-\(section.id)" }

    private var games: [OPNCatalogGameObject] {
        var visibleGames = section.visibleGames(expanded: false)
        guard let selectedGame = viewModel.selectedGame else { return visibleGames }
        if !viewModel.selectedSectionId.isEmpty, viewModel.selectedSectionId != section.id { return visibleGames }
        guard !visibleGames.contains(where: { CatalogViewModel.looseIdentityMatches($0, selectedGame) }),
              let sectionGame = section.games.first(where: { CatalogViewModel.looseIdentityMatches($0, selectedGame) }) else { return visibleGames }
        visibleGames.append(sectionGame)
        return visibleGames
    }
    private var canShowAll: Bool { section.games.count > games.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(section.title)
                    .font(.nvidia(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.96))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if canShowAll {
                    Button("SHOW ALL", action: onShowAll)
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
                        LazyHStack(alignment: .top, spacing: 0) {
                            ForEach(Array(games.enumerated()), id: \.element.catalogIdentity) { _, game in
                                CatalogGameTile(
                                    game: game,
                                    imageURL: viewModel.optimizedImageURL(game.bestWideImageURL, width: 620),
                                    isSelected: isSelected(game),
                                    isSelectionActive: viewModel.selectedGame != nil,
                                    onSelect: { viewModel.selectGame(game, inSection: section.id) },
                                    onPlay: { viewModel.launch(game: game) }
                                )
                                    .id(game.catalogIdentity)
                                    .background(CatalogRailTileFrameReader(identity: game.catalogIdentity, coordinateSpaceName: coordinateSpaceName))
                            }
                            if section.games.count > games.count {
                                CatalogSeeMoreTile(title: "Show All", action: onShowAll)
                            }
                        }
                        .padding(.horizontal, CatalogVendorLayout.carouselContainerMargin)
                        .padding(.bottom, 4)
                    }
                    .coordinateSpace(name: coordinateSpaceName)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { viewportWidth = proxy.size.width }
                                .onChange(of: proxy.size.width) { _, width in viewportWidth = width }
                        }
                    )
                    .onPreferenceChange(CatalogRailTileFramePreferenceKey.self) { frames in
                        tileFrames = frames
                        revealSelectedGameIfNeeded(proxy: proxy, request: viewModel.selectedGameRevealRequest)
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
                .onAppear { revealSelectedGameIfNeeded(proxy: proxy, request: viewModel.selectedGameRevealRequest) }
                .onChange(of: viewModel.selectedGameRevealRequest) { _, request in revealSelectedGameIfNeeded(proxy: proxy, request: request) }
                .onChange(of: viewportWidth) { _, _ in revealSelectedGameIfNeeded(proxy: proxy, request: viewModel.selectedGameRevealRequest) }
            }
        }
        .onAppear { prefetchNearVisibleImages() }
        .onChange(of: games.map(\.catalogIdentity)) { _, _ in prefetchNearVisibleImages() }
    }

    private func moveRail(proxy: ScrollViewProxy, delta: Int) {
        guard !games.isEmpty else { return }
        scrollIndex = min(max(scrollIndex + delta, 0), max(games.count - 1, 0))
        withAnimation(.easeInOut(duration: 0.22)) {
            proxy.scrollTo(games[scrollIndex].catalogIdentity, anchor: .leading)
        }
    }

    private func isSelected(_ game: OPNCatalogGameObject) -> Bool {
        guard let selectedGame = viewModel.selectedGame else { return false }
        if !viewModel.selectedSectionId.isEmpty, viewModel.selectedSectionId != section.id { return false }
        return CatalogViewModel.looseIdentityMatches(selectedGame, game)
    }

    private func prefetchNearVisibleImages() {
        var urls: [URL] = []
        var seen = Set<String>()
        for game in games.prefix(8) {
            appendPrefetchURL(game.bestTileImageURL, width: 620, urls: &urls, seen: &seen)
            appendPrefetchURL(game.bestWideImageURL, width: 620, urls: &urls, seen: &seen)
            appendPrefetchURL(game.bestLogoImageURL, width: 300, urls: &urls, seen: &seen)
        }
        CatalogImageCache.shared.prefetch(urls)
    }

    private func appendPrefetchURL(_ rawValue: String, width: Int, urls: inout [URL], seen: inout Set<String>) {
        guard let url = viewModel.optimizedImageURL(rawValue, width: width) else { return }
        let key = url.absoluteString
        guard !seen.contains(key) else { return }
        seen.insert(key)
        urls.append(url)
    }

    private func revealSelectedGameIfNeeded(proxy: ScrollViewProxy, request: CatalogGameRevealRequest?) {
        guard let request, request.sectionId.isEmpty || request.sectionId == section.id else { return }
        guard games.contains(where: { $0.catalogIdentity == request.gameIdentity }) else { return }
        revealSelectedGameIfNeeded(proxy: proxy, identity: request.gameIdentity, remainingDeferredPasses: 3)
    }

    private func revealSelectedGameIfNeeded(proxy: ScrollViewProxy, identity: String, remainingDeferredPasses: Int) {
        DispatchQueue.main.async {
            guard games.contains(where: { $0.catalogIdentity == identity }) else { return }
            guard !isTileFullyVisible(identity) else { return }
            withAnimation(.easeInOut(duration: 0.24)) {
                proxy.scrollTo(identity, anchor: .center)
            }
            if remainingDeferredPasses > 0 {
                revealSelectedGameIfNeeded(proxy: proxy, identity: identity, remainingDeferredPasses: remainingDeferredPasses - 1)
            }
        }
    }

    private func isTileFullyVisible(_ identity: String) -> Bool {
        guard viewportWidth > 0, let frame = tileFrames[identity] else { return false }
        return frame.minX >= 0 && frame.maxX <= viewportWidth
    }
}

private struct CatalogRailTileFrameReader: View {
    let identity: String
    let coordinateSpaceName: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: CatalogRailTileFramePreferenceKey.self, value: [identity: proxy.frame(in: .named(coordinateSpaceName))])
        }
    }
}

private struct CatalogRailTileFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct CatalogDestinationGridView: View {
    @ObservedObject var viewModel: CatalogViewModel
    let section: CatalogSectionModel

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CatalogVendorLayout.wideTileWidth + CatalogVendorLayout.tileHorizontalMargin * 2), spacing: 4, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .lastTextBaseline, spacing: 14) {
                Text(section.title)
                    .font(.nvidia(size: 24, weight: .bold))
                    .foregroundStyle(.white.opacity(0.96))
                    .accessibilityAddTraits(.isHeader)
                Text("\(section.games.count) game\(section.games.count == 1 ? "" : "s")")
                    .font(.nvidia(size: 12, weight: .bold))
                    .foregroundStyle(Color.openNowGreen.opacity(0.86))
                    .tracking(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Array(section.games.enumerated()), id: \.element.catalogIdentity) { _, game in
                    CatalogGameTile(
                        game: game,
                        imageURL: viewModel.optimizedImageURL(game.bestWideImageURL, width: 620),
                        isSelected: isSelected(game),
                        isSelectionActive: viewModel.selectedGame != nil,
                        onSelect: { viewModel.selectGame(game, inSection: section.id) },
                        onPlay: { viewModel.launch(game: game) }
                    )
                }
            }
            .padding(.horizontal, CatalogVendorLayout.carouselContainerMargin)
            .padding(.bottom, 12)
        }
        .onAppear { prefetchGridImages() }
        .onChange(of: section.games.map(\.catalogIdentity)) { _, _ in prefetchGridImages() }
    }

    private func isSelected(_ game: OPNCatalogGameObject) -> Bool {
        guard let selectedGame = viewModel.selectedGame else { return false }
        return CatalogViewModel.looseIdentityMatches(selectedGame, game)
    }

    private func prefetchGridImages() {
        var urls: [URL] = []
        var seen = Set<String>()
        for game in section.games.prefix(18) {
            appendPrefetchURL(game.bestTileImageURL, width: 620, urls: &urls, seen: &seen)
            appendPrefetchURL(game.bestWideImageURL, width: 620, urls: &urls, seen: &seen)
            appendPrefetchURL(game.bestLogoImageURL, width: 300, urls: &urls, seen: &seen)
        }
        CatalogImageCache.shared.prefetch(urls)
    }

    private func appendPrefetchURL(_ rawValue: String, width: Int, urls: inout [URL], seen: inout Set<String>) {
        guard let url = viewModel.optimizedImageURL(rawValue, width: width) else { return }
        let key = url.absoluteString
        guard !seen.contains(key) else { return }
        seen.insert(key)
        urls.append(url)
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
            .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin)
            .padding(.top, CatalogVendorLayout.tileTopMargin)
            .frame(width: CatalogVendorLayout.wideTileWidth + CatalogVendorLayout.tileHorizontalMargin * 2, height: CatalogVendorLayout.wideTileHeight + CatalogVendorLayout.tileTopMargin, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("See all")
    }
}

private struct CatalogShowAllOverlay: View {
    @ObservedObject var viewModel: CatalogViewModel
    let section: CatalogSectionModel
    let onDismiss: () -> Void
    let onSelect: (OPNCatalogGameObject) -> Void
    @State private var searchQuery = ""
    @State private var userSize: CGSize? = CatalogShowAllWindowPreferences.loadSize()
    @State private var resizeStartSize: CGSize?
    @State private var userOffset = CGSize.zero
    @State private var resizeStartOffset = CGSize.zero

    private let columns = [GridItem(.adaptive(minimum: CatalogVendorLayout.wideTileWidth + CatalogVendorLayout.tileHorizontalMargin * 2), spacing: 4, alignment: .top)]

    var body: some View {
        GeometryReader { proxy in
            let panelSize = overlaySize(for: proxy.size)
            let panelOffset = clampedOffset(userOffset, panelSize: panelSize, containerSize: proxy.size)
            ZStack {
                Color.black.opacity(0.50)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)

                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(section.title.uppercased())
                                .font(.nvidia(size: 24, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(resultSummary)
                                .font(.nvidia(size: 12, weight: .bold))
                                .foregroundStyle(.white.opacity(0.56))
                        }
                        Spacer(minLength: 0)
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.nvidia(size: 15, weight: .bold))
                                .foregroundStyle(.white.opacity(0.78))
                                .frame(width: 34, height: 34)
                                .background(Color.white.opacity(0.08))
                                .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close show all")
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.nvidia(size: 14, weight: .bold))
                            .foregroundStyle(Color.openNowGreen)
                        TextField("Search titles, genres, publishers, stores, controls, ratings, tags", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .font(.nvidia(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                        if !searchQuery.isEmpty {
                            Button("CLEAR") { searchQuery = "" }
                                .buttonStyle(.plain)
                                .font(.nvidia(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.64))
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(Color.black.opacity(0.34))
                    .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }

                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            ForEach(Array(filteredGames.enumerated()), id: \.offset) { _, game in
                                CatalogGameTile(
                                    game: game,
                                    imageURL: viewModel.optimizedImageURL(game.bestWideImageURL, width: 620),
                                    isSelected: isSelected(game),
                                    isSelectionActive: viewModel.selectedGame != nil,
                                    onSelect: { onSelect(game) },
                                    onPlay: { viewModel.launch(game: game) }
                                )
                            }
                        }
                        .padding(.bottom, 10)
                    }
                    .overlay {
                        if filteredGames.isEmpty {
                            CatalogShowAllEmptySearchView(query: searchQuery)
                        }
                    }
                }
                .padding(22)
                .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
                .background(Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255).opacity(0.96))
                .overlay { Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1) }
                .overlay { CatalogShowAllResizeZones(resizeAction: { edge in resizeGesture(edge: edge, containerSize: proxy.size, currentSize: panelSize) }) }
                .offset(panelOffset)
                .shadow(color: .black.opacity(0.46), radius: 28, x: 0, y: 18)
            }
        }
    }

    private var filteredGames: [OPNCatalogGameObject] {
        let terms = CatalogSearchQueryParser.terms(from: searchQuery)
        guard !terms.isEmpty else { return section.games }
        return section.games.filter { game in
            let searchableText = game.advancedSearchText
            return terms.allSatisfy { searchableText.contains($0) }
        }
    }

    private var resultSummary: String {
        let count = filteredGames.count
        let total = section.games.count
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "\(total) games" }
        return "\(count) of \(total) games"
    }

    private func isSelected(_ game: OPNCatalogGameObject) -> Bool {
        guard let selectedGame = viewModel.selectedGame else { return false }
        return CatalogViewModel.looseIdentityMatches(selectedGame, game)
    }

    private func overlaySize(for containerSize: CGSize) -> CGSize {
        let fallback = CGSize(width: containerSize.width * 0.72, height: containerSize.height * 0.72)
        let rawSize = userSize ?? fallback
        return CGSize(
            width: clamped(rawSize.width, minimum: minimumOverlayWidth(for: containerSize), maximum: maximumOverlayWidth(for: containerSize)),
            height: clamped(rawSize.height, minimum: minimumOverlayHeight(for: containerSize), maximum: maximumOverlayHeight(for: containerSize))
        )
    }

    private func resizeGesture(edge: CatalogShowAllResizeEdge, containerSize: CGSize, currentSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let startSize = resizeStartSize ?? currentSize
                let startOffset = resizeStartSize == nil ? userOffset : resizeStartOffset
                resizeStartSize = startSize
                resizeStartOffset = startOffset
                let widthDelta = edge.horizontalDelta(from: value.translation.width)
                let heightDelta = edge.verticalDelta(from: value.translation.height)
                let nextSize = CGSize(
                    width: clamped(startSize.width + widthDelta, minimum: minimumOverlayWidth(for: containerSize), maximum: maximumOverlayWidth(for: containerSize)),
                    height: clamped(startSize.height + heightDelta, minimum: minimumOverlayHeight(for: containerSize), maximum: maximumOverlayHeight(for: containerSize))
                )
                let nextOffset = CGSize(
                    width: startOffset.width + edge.horizontalOffsetDelta(sizeDelta: nextSize.width - startSize.width),
                    height: startOffset.height + edge.verticalOffsetDelta(sizeDelta: nextSize.height - startSize.height)
                )
                userSize = nextSize
                userOffset = clampedOffset(nextOffset, panelSize: nextSize, containerSize: containerSize)
            }
            .onEnded { _ in
                if let userSize { CatalogShowAllWindowPreferences.saveSize(userSize) }
                resizeStartSize = nil
                resizeStartOffset = .zero
            }
    }

    private func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }

    private func clampedOffset(_ offset: CGSize, panelSize: CGSize, containerSize: CGSize) -> CGSize {
        CGSize(
            width: clamped(offset.width, minimum: -maximumOffsetX(panelSize: panelSize, containerSize: containerSize), maximum: maximumOffsetX(panelSize: panelSize, containerSize: containerSize)),
            height: clamped(offset.height, minimum: -maximumOffsetY(panelSize: panelSize, containerSize: containerSize), maximum: maximumOffsetY(panelSize: panelSize, containerSize: containerSize))
        )
    }

    private func maximumOffsetX(panelSize: CGSize, containerSize: CGSize) -> CGFloat {
        max((containerSize.width - panelSize.width) / 2 - 32, 0)
    }

    private func maximumOffsetY(panelSize: CGSize, containerSize: CGSize) -> CGFloat {
        max((containerSize.height - panelSize.height) / 2 - 32, 0)
    }

    private func minimumOverlayWidth(for size: CGSize) -> CGFloat {
        min(max(size.width - 64, 360), 760)
    }

    private func maximumOverlayWidth(for size: CGSize) -> CGFloat {
        max(size.width - 64, minimumOverlayWidth(for: size))
    }

    private func minimumOverlayHeight(for size: CGSize) -> CGFloat {
        min(max(size.height - 64, 360), 520)
    }

    private func maximumOverlayHeight(for size: CGSize) -> CGFloat {
        max(size.height - 64, minimumOverlayHeight(for: size))
    }
}

private enum CatalogShowAllWindowPreferences {
    private static let widthKey = "OpenNOW.catalog.showAllWindow.width"
    private static let heightKey = "OpenNOW.catalog.showAllWindow.height"

    static func loadSize() -> CGSize? {
        let width = UserDefaults.standard.double(forKey: widthKey)
        let height = UserDefaults.standard.double(forKey: heightKey)
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    static func saveSize(_ size: CGSize) {
        UserDefaults.standard.set(Double(size.width), forKey: widthKey)
        UserDefaults.standard.set(Double(size.height), forKey: heightKey)
    }
}

private struct CatalogShowAllResizeZones<ResizeGesture: Gesture>: View {
    let resizeAction: (CatalogShowAllResizeEdge) -> ResizeGesture

    private let edgeThickness: CGFloat = 8
    private let cornerSize: CGFloat = 28

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                resizeZone(.top, height: edgeThickness)
                Spacer(minLength: 0)
                resizeZone(.bottom, height: edgeThickness)
            }
            HStack(spacing: 0) {
                resizeZone(.left, width: edgeThickness)
                Spacer(minLength: 0)
                resizeZone(.right, width: edgeThickness)
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    resizeZone(.topLeft, width: cornerSize, height: cornerSize)
                    Spacer(minLength: 0)
                    resizeZone(.topRight, width: cornerSize, height: cornerSize)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    resizeZone(.bottomLeft, width: cornerSize, height: cornerSize)
                    Spacer(minLength: 0)
                    ZStack(alignment: .bottomTrailing) {
                        resizeZone(.bottomRight, width: cornerSize, height: cornerSize)
                        VStack(alignment: .trailing, spacing: 4) {
                            Rectangle()
                                .fill(Color.white.opacity(0.28))
                                .frame(width: 9, height: 1)
                            Rectangle()
                                .fill(Color.white.opacity(0.42))
                                .frame(width: 15, height: 1)
                            Rectangle()
                                .fill(Color.openNowGreen.opacity(0.86))
                                .frame(width: 21, height: 1)
                        }
                        .rotationEffect(.degrees(-45))
                        .offset(x: -10, y: -10)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func resizeZone(_ edge: CatalogShowAllResizeEdge, width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(resizeAction(edge))
            .cursor(edge.cursor)
            .accessibilityLabel(edge.accessibilityLabel)
    }
}

private enum CatalogShowAllResizeEdge {
    case top
    case bottom
    case left
    case right
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var cursor: NSCursor {
        switch self {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .bottomRight: return .catalogDiagonalResizeForward
        case .topRight, .bottomLeft: return .catalogDiagonalResizeBackward
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .top: return "Resize show all window from top edge"
        case .bottom: return "Resize show all window from bottom edge"
        case .left: return "Resize show all window from left edge"
        case .right: return "Resize show all window from right edge"
        case .topLeft: return "Resize show all window from top left corner"
        case .topRight: return "Resize show all window from top right corner"
        case .bottomLeft: return "Resize show all window from bottom left corner"
        case .bottomRight: return "Resize show all window from bottom right corner"
        }
    }

    func horizontalDelta(from translation: CGFloat) -> CGFloat {
        switch self {
        case .left, .topLeft, .bottomLeft: return -translation
        case .right, .topRight, .bottomRight: return translation
        case .top, .bottom: return 0
        }
    }

    func verticalDelta(from translation: CGFloat) -> CGFloat {
        switch self {
        case .top, .topLeft, .topRight: return -translation
        case .bottom, .bottomLeft, .bottomRight: return translation
        case .left, .right: return 0
        }
    }

    func horizontalOffsetDelta(sizeDelta: CGFloat) -> CGFloat {
        switch self {
        case .left, .topLeft, .bottomLeft: return -sizeDelta / 2
        case .right, .topRight, .bottomRight: return sizeDelta / 2
        case .top, .bottom: return 0
        }
    }

    func verticalOffsetDelta(sizeDelta: CGFloat) -> CGFloat {
        switch self {
        case .top, .topLeft, .topRight: return -sizeDelta / 2
        case .bottom, .bottomLeft, .bottomRight: return sizeDelta / 2
        case .left, .right: return 0
        }
    }
}

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        modifier(CatalogCursorModifier(cursor: cursor))
    }
}

private struct CatalogCursorModifier: ViewModifier {
    let cursor: NSCursor
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, !isHovering {
                    cursor.push()
                    isHovering = true
                } else if !hovering, isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .onDisappear {
                guard isHovering else { return }
                NSCursor.pop()
                isHovering = false
            }
    }
}

private extension NSCursor {
    static let catalogDiagonalResizeForward = NSCursor.catalogDiagonalResize(angle: 45)
    static let catalogDiagonalResizeBackward = NSCursor.catalogDiagonalResize(angle: -45)

    private static func catalogDiagonalResize(angle: CGFloat) -> NSCursor {
        let size = CGSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        let transform = NSAffineTransform()
        transform.translateX(by: size.width / 2, yBy: size.height / 2)
        transform.rotate(byDegrees: angle)
        transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
        transform.concat()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 3, y: 9))
        path.line(to: CGPoint(x: 15, y: 9))
        path.move(to: CGPoint(x: 3, y: 9))
        path.line(to: CGPoint(x: 7, y: 5))
        path.move(to: CGPoint(x: 3, y: 9))
        path.line(to: CGPoint(x: 7, y: 13))
        path.move(to: CGPoint(x: 15, y: 9))
        path.line(to: CGPoint(x: 11, y: 5))
        path.move(to: CGPoint(x: 15, y: 9))
        path.line(to: CGPoint(x: 11, y: 13))
        path.lineWidth = 1.7
        NSColor.white.setStroke()
        path.stroke()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: CGPoint(x: size.width / 2, y: size.height / 2))
    }
}

private struct CatalogShowAllEmptySearchView: View {
    let query: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.nvidia(size: 34, weight: .bold))
                .foregroundStyle(Color.openNowGreen.opacity(0.84))
            Text("No matching games")
                .font(.nvidia(size: 18, weight: .bold))
                .foregroundStyle(.white.opacity(0.88))
            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Try searching by title, genre, store, publisher, input type, rating, or tag." : "No metadata matched \"\(query)\".")
                .font(.nvidia(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(28)
    }
}

private enum CatalogSearchQueryParser {
    static func terms(from query: String) -> [String] {
        var terms: [String] = []
        var current = ""
        var isQuoted = false
        for character in query.lowercased() {
            if character == "\"" {
                append(current, to: &terms)
                current = ""
                isQuoted.toggle()
            } else if character.isWhitespace && !isQuoted {
                append(current, to: &terms)
                current = ""
            } else {
                current.append(character)
            }
        }
        append(current, to: &terms)
        return terms
    }

    private static func append(_ value: String, to terms: inout [String]) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        terms.append(normalized)
    }
}

private struct CatalogGameTile: View {
    let game: OPNCatalogGameObject
    let imageURL: URL?
    let isSelected: Bool
    let isSelectionActive: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: onSelect) {
                tileContent
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .accessibilityLabel(game.title.isEmpty ? "Game tile" : game.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isSelected ? "Details open" : "")

            if isHovering {
                Button(action: onPlay) {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill")
                            .font(.nvidia(size: 10, weight: .bold))
                        Text("PLAY")
                            .font(.nvidia(size: 11, weight: .bold))
                            .tracking(0.9)
                    }
                    .foregroundStyle(.black.opacity(0.88))
                    .padding(.horizontal, 13)
                    .frame(height: 30)
                    .background(Color.openNowGreen)
                    .overlay { Rectangle().stroke(Color.openNowGreen, lineWidth: 1) }
                    .shadow(color: .black.opacity(0.38), radius: 9, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .frame(width: CatalogVendorLayout.wideTileWidth, height: CatalogVendorLayout.wideTileHeight)
                .padding(.leading, CatalogVendorLayout.tileHorizontalMargin)
                .padding(.top, CatalogVendorLayout.tileTopMargin)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(2)
                .accessibilityLabel("Play \(game.title.isEmpty ? "game" : game.title)")
            }
        }
        .onHover { isHovering = $0 }
        .openNowFocusRing(isFocused)
        .animation(.easeOut(duration: 0.16), value: isHovering)
    }

    private var tileContent: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                let isActive = isHovering || isSelected || isFocused
                CatalogRemoteImage(url: imageURL, contentMode: .fill)
                    .frame(width: CatalogVendorLayout.wideTileWidth, height: CatalogVendorLayout.wideTileHeight)
                    .clipped()
                if isActive {
                    Color.black.opacity(0.50)
                    LinearGradient(colors: [CatalogVendorLayout.tileTray, CatalogVendorLayout.tileTray.opacity(0)], startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.63))
                }
                if let badge = game.cardBadgeLabel {
                    CatalogGameCardBadge(label: badge)
                }
                if isActive {
                    VStack {
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
                            Text(game.title.isEmpty ? "GeForce NOW" : game.title)
                                .font(.nvidia(size: 12, weight: isSelected ? .medium : .regular))
                                .lineLimit(1)
                                .foregroundStyle(.white.opacity(0.90))
                            Spacer(minLength: 0)
                            Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                                .font(.nvidia(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.76))
                        }
                        .frame(width: CatalogVendorLayout.wideTileWidth - 32, height: CatalogVendorLayout.cardTrayHeight)
                        .padding(.horizontal, 16)
                        .background(CatalogVendorLayout.tileTray.opacity(1))
                        .frame(width: CatalogVendorLayout.wideTileWidth)
                    }
                    .frame(width: CatalogVendorLayout.wideTileWidth, height: CatalogVendorLayout.wideTileHeight)
                }
            }
        }
        .frame(width: CatalogVendorLayout.wideTileWidth, alignment: .top)
        .overlay(alignment: .top) {
            if isSelected {
                Rectangle()
                    .fill(Color.openNowGreen)
                    .frame(width: CatalogVendorLayout.wideTileWidth, height: 4)
                    .offset(y: CatalogVendorLayout.wideTileHeight - 4)
            }
        }
        .shadow(color: isSelected ? .black.opacity(0.28) : .clear, radius: 5, x: 0, y: 3)
        .scaleEffect(isHovering && !isSelectionActive ? CatalogVendorLayout.tileScaleFactor : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin)
        .padding(.top, CatalogVendorLayout.tileTopMargin)
        .frame(width: CatalogVendorLayout.wideTileWidth + CatalogVendorLayout.tileHorizontalMargin * 2, height: CatalogVendorLayout.wideTileHeight + CatalogVendorLayout.tileTopMargin, alignment: .top)
        .contentShape(Rectangle())
    }
}

private struct CatalogGameCardBadge: View {
    let label: String

    var body: some View {
        HStack(spacing: 0) {
            MallRibbonShape()
                .fill(Color.openNowGreen)
                .frame(width: 7, height: 24)
            Text(label)
                .font(.nvidia(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Color(red: 56 / 255, green: 56 / 255, blue: 56 / 255).opacity(0.94))
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private enum CatalogCardBadgeMapper {
    nonisolated static func label(promoTag: String, campaignIds: [String], skuTags: [String], genres: [String], featureLabels: [String]) -> String? {
        let normalizedPromoTag = normalizedValue(promoTag)
        if !normalizedPromoTag.isEmpty { return normalizedPromoTag }
        return label(campaignIds: campaignIds, skuTags: skuTags, genres: genres, featureLabels: featureLabels)
    }

    nonisolated static func label(campaignIds: [String], skuTags: [String], genres: [String], featureLabels: [String]) -> String? {
        let explicitValues = (skuTags + campaignIds).map(normalizedValue).filter { !$0.isEmpty }
        let taxonomyValues = (genres + featureLabels).map(normalizedValue).filter { !$0.isEmpty }
        let values = explicitValues + taxonomyValues
        for value in values {
            if let discount = discountLabel(value) { return discount }
        }
        if values.contains(where: isFree) { return "Free" }
        if values.contains(where: isNewSeason) { return "New Season" }
        if values.contains(where: isNewOnGFN) { return "New on GFN" }
        return explicitValues.compactMap(readableLabel).first
    }

    nonisolated private static func normalizedValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func discountLabel(_ value: String) -> String? {
        let lowercased = value.lowercased()
        guard lowercased.contains("discount") || lowercased.contains("off") || lowercased.contains("sale") || value.contains("%") else { return nil }
        guard let match = value.range(of: #"\d{1,2}"#, options: .regularExpression) else { return nil }
        return "-\(value[match])%"
    }

    nonisolated private static func isFree(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased == "free" || lowercased.contains("free_to_play") || lowercased.contains("free-to-play") || lowercased.contains("free2play")
    }

    nonisolated private static func isNewSeason(_ value: String) -> Bool {
        let lowercased = value.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return lowercased.contains("new season") || lowercased.contains("season launch")
    }

    nonisolated private static func isNewOnGFN(_ value: String) -> Bool {
        let lowercased = value.lowercased().replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return lowercased.contains("new on gfn") || lowercased.contains("new to gfn") || lowercased.contains("new release")
    }

    nonisolated private static func readableLabel(_ value: String) -> String? {
        let words = value
            .replacingOccurrences(of: #"^[A-Z]+_"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }
        let label = words.joined(separator: " ")
        guard !label.isEmpty, label.count <= 18 else { return nil }
        return label
    }
}

private struct MallRibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.28))
        path.closeSubpath()
        return path
    }
}

private struct GameDetailPanel: View {
    @ObservedObject var viewModel: CatalogViewModel
    @State private var activeImageIndex = 0
    @State private var isDescriptionExpanded = false
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let imageTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        if let game = viewModel.selectedGame {
            let imageURLs = game.detailImageURLs
            let imageIndex = imageURLs.indices.contains(activeImageIndex) ? activeImageIndex : 0
            let imageURL = imageURLs.indices.contains(imageIndex) ? imageURLs[imageIndex] : game.bestDetailImageURL
            GeometryReader { proxy in
                let panelWidth = max(1, proxy.size.width)
                let contentWidth = min(panelWidth * 0.43, 820)
                let imageWidth = max(panelWidth * 0.64, panelWidth - contentWidth * 0.52)
                ZStack(alignment: .topTrailing) {
                    CatalogRemoteImage(url: viewModel.optimizedImageURL(imageURL, width: 1600), contentMode: .fill)
                        .frame(width: imageWidth, height: CatalogVendorLayout.detailPanelHeight)
                        .clipped()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .id(imageURL)
                        .transition(.opacity.animation(.easeInOut(duration: 0.22)))
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 57 / 255, green: 57 / 255, blue: 59 / 255).opacity(0.99), location: 0.00),
                            .init(color: Color(red: 57 / 255, green: 57 / 255, blue: 59 / 255).opacity(0.98), location: 0.34),
                            .init(color: Color(red: 57 / 255, green: 57 / 255, blue: 59 / 255).opacity(0.84), location: 0.49),
                            .init(color: Color(red: 57 / 255, green: 57 / 255, blue: 59 / 255).opacity(0.22), location: 0.67),
                            .init(color: .clear, location: 1.00)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    LinearGradient(colors: [.black.opacity(0.04), .black.opacity(0.02), .black.opacity(0.22)], startPoint: .top, endPoint: .bottom)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            Text(game.title.isEmpty ? "Selected Game" : game.title)
                                .font(.nvidia(size: 30, weight: .bold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.82)
                                .foregroundStyle(.white.opacity(0.96))
                            Spacer(minLength: 20)
                            Button { viewModel.toggleFavoriteSelectedGame() } label: {
                                Image(systemName: viewModel.isFavorite(game) ? "heart.fill" : "heart")
                                    .font(.nvidia(size: 21, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.94))
                                    .frame(width: 36, height: 32)
                            }
                            .buttonStyle(.plain)
                        }

                        detailMetadataLine(game: game)
                        capabilityChips(game: game)
                        variantStatusRow(game: game)
                        detailActions(game: game)
                        accessMessage(game: game)
                        detailMetadataScrollArea(game: game)
                            .padding(.top, 4)
                        readMoreButton
                            .padding(.top, 2)
                    }
                    .frame(width: contentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 21)
                    .padding(.leading, 44)
                    .padding(.trailing, 28)

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
                            Spacer()
                                .frame(width: min(contentWidth + 42, max(24, panelWidth - 154)))
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
                        .padding(.leading, contentWidth + 54)
                        .padding(.bottom, 38)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let logoURL = viewModel.optimizedImageURL(game.bestLogoImageURL, width: 300) {
                        CatalogCachedImageView(url: logoURL, contentMode: .fit, placeholder: EmptyView(), failure: EmptyView())
                        .frame(width: 160, height: 70, alignment: .bottomTrailing)
                        .padding(.trailing, 42)
                        .padding(.bottom, 28)
                        .opacity(0.94)
                    }
                }
                .frame(width: panelWidth, height: CatalogVendorLayout.detailPanelHeight)
                .background(Color(red: 57 / 255, green: 57 / 255, blue: 59 / 255))
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, minHeight: CatalogVendorLayout.detailPanelHeight, maxHeight: CatalogVendorLayout.detailPanelHeight)
            .onHover { isHovering = $0 }
            .onReceive(imageTimer) { _ in
                guard !reduceMotion, !isHovering, game.detailImageURLs.count > 1 else { return }
                moveImage(delta: 1, count: game.detailImageURLs.count)
            }
            .onChange(of: game.catalogIdentity) { _, _ in
                activeImageIndex = 0
                isDescriptionExpanded = false
            }
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
                    .tracking(0.4)
                    .foregroundStyle(chip == "IN LIBRARY" ? .black.opacity(0.88) : .white.opacity(0.82))
                    .padding(.horizontal, 10)
                    .frame(height: 27)
                    .background(chip == "IN LIBRARY" ? Color.openNowGreen : Color.white.opacity(0.09))
                    .overlay { Rectangle().stroke(chip == "IN LIBRARY" ? Color.openNowGreen : Color.white.opacity(0.12), lineWidth: 1) }
            }
        }
    }

    private func detailMetadataLine(game: OPNCatalogGameObject) -> some View {
        HStack(spacing: 9) {
            if !game.ratingLabel.isEmpty {
                Text(game.ratingLabel.uppercased())
                    .font(.nvidia(size: 12, weight: .bold))
            }
            metadataSeparator
            if game.maxOnlinePlayers > 1 { Image(systemName: "person.3.fill") }
            if game.supportsKeyboard { Image(systemName: "keyboard") }
            if game.supportsGamepad { Image(systemName: "gamecontroller.fill") }
            metadataSeparator
            Text(game.genres.prefix(2).joined(separator: ", "))
                .lineLimit(1)
        }
        .font(.nvidia(size: 12, weight: .bold))
        .foregroundStyle(.white.opacity(0.86))
    }

    private var metadataSeparator: some View {
        Circle()
            .fill(Color.white.opacity(0.72))
            .frame(width: 3, height: 3)
    }

    private func capabilityChips(game: OPNCatalogGameObject) -> some View {
        FlowLayout(spacing: 5) {
            ForEach(capabilityLabels(game: game), id: \.self) { chip in
                HStack(spacing: 5) {
                    if chip == "For Premium Members" {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.nvidia(size: 10, weight: .bold))
                    }
                    Text(chip)
                        .font(.nvidia(size: 12, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.86))
                .padding(.horizontal, 9)
                .frame(height: 23)
                .background(chip == "For Premium Members" ? Color.white.opacity(0.22) : Color.black.opacity(0.18))
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func capabilityLabels(game: OPNCatalogGameObject) -> [String] {
        var labels: [String] = []
        if !game.membershipTierLabel.isEmpty { labels.append("For Premium Members") }
        for technology in supportedTechnologyLabels(game: game).prefix(2) { appendUnique(technology, to: &labels) }
        if labels.isEmpty { labels.append("Cloud Ready") }
        return labels
    }

    private func detailEyebrow(game: OPNCatalogGameObject) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(detailMetadata(game: game), id: \.self) { item in
                Text(item.uppercased())
                    .font(.nvidia(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
    }

    private func detailMetadata(game: OPNCatalogGameObject) -> [String] {
        var values: [String] = []
        appendUnique(game.primaryStoreLabel, to: &values)
        appendUnique(game.ratingLabel, to: &values)
        for genre in game.genres.prefix(2) { appendUnique(genre, to: &values) }
        return values
    }

    private func appendUnique(_ value: String, to values: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !values.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        values.append(trimmed)
    }

    private func detailActions(game: OPNCatalogGameObject) -> some View {
        HStack(spacing: 10) {
            Button { primaryAction(game: game) } label: {
                Text(primaryActionTitle(game: game))
                    .font(.nvidia(size: 15, weight: .bold))
                    .tracking(0.3)
                    .frame(width: primaryActionTitle(game: game) == "PLAY" ? 72 : 132, height: 40)
            }
            .buttonStyle(VendorGetInButtonStyle())
            .fixedSize()

            Menu {
                Button("Change game store") { viewModel.changeSelectedGameStore() }
                Button("Share") { viewModel.shareSelectedGame() }
                Button("Add shortcut") { viewModel.addShortcutForSelectedGame() }
                if selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true || game.isInLibrary {
                    Button("Unmark as owned") { viewModel.removeSelectedVariantOwned() }
                } else if selectedVariant != nil {
                    Button("Mark as owned") { viewModel.markSelectedVariantOwned() }
                }
                Button("Visit game store") { viewModel.openStoreForSelectedVariant() }
            } label: {
                Text("⋮")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                    .offset(y: -1)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func variantStatusRow(game: OPNCatalogGameObject) -> some View {
        HStack(spacing: 0) {
            if let variant = selectedVariant {
                Button { viewModel.changeSelectedGameStore() } label: {
                    HStack(spacing: 6) {
                        if !variant.appStoreSmallImageUrl.isEmpty {
                            CatalogStoreIconImage(url: URL(string: variant.appStoreSmallImageUrl), size: 16)
                                .frame(width: 16, height: 16)
                        }
                        Text(storePickerTitle(variant: variant))
                            .font(.nvidia(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(height: 30)
                    .padding(.horizontal, 0)
                }
                .buttonStyle(.plain)
            }
            Text((selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true || game.isInLibrary) ? "Owned" : "Not Owned")
                .font(.nvidia(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.black.opacity(0.14))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func accessMessage(game: OPNCatalogGameObject) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(accessBody(game: game))
                .font(.nvidia(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)
            Text("Configure stores from Connections.")
                .font(.nvidia(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.68))
            Spacer(minLength: 0)
        }
    }

    private func accessBody(game: OPNCatalogGameObject) -> String {
        if game.isInLibrary || selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true {
            return "Access unlocked with your membership. Game ownership required to play."
        }
        if let selectedVariant, !selectedVariant.appStore.isEmpty {
            return "Game ownership required on \(viewModel.displayName(forStore: selectedVariant.appStore)) to play."
        }
        return "Access requires a GeForce NOW membership and supported game ownership."
    }

    private func detailMetadataScrollArea(game: OPNCatalogGameObject) -> some View {
        ScrollView(.vertical, showsIndicators: isDescriptionExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                shortDescription(game: game)
                divider
                nvidiaTechRows(game: game)
                ratingBlock(game: game)
                detailRows(game: game)
                fullDescription(game: game)
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(.trailing, isDescriptionExpanded ? 8 : 0)
        }
        .scrollDisabled(!isDescriptionExpanded)
        .frame(maxWidth: 660, minHeight: 128, maxHeight: isDescriptionExpanded ? 248 : 128, alignment: .topLeading)
        .clipped()
    }

    private func shortDescription(game: OPNCatalogGameObject) -> some View {
        Text(detailShortDescription(game: game))
            .font(.nvidia(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.90))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 660, alignment: .leading)
    }

    private func fullDescription(game: OPNCatalogGameObject) -> some View {
        let description = detailLongDescription(game: game)
        return VStack(alignment: .leading, spacing: 8) {
            if !description.isEmpty {
                Text("FULL DESCRIPTION")
                    .font(.nvidia(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.56))
                Text(description)
                    .font(.nvidia(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 660, alignment: .leading)
    }

    private func detailShortDescription(game: OPNCatalogGameObject) -> String {
        let value = game.shortDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
        return "Play instantly through GeForce NOW cloud streaming."
    }

    private func detailLongDescription(game: OPNCatalogGameObject) -> String {
        let longDescription = game.longDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !longDescription.isEmpty { return longDescription }
        let gameDescription = game.gameDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return gameDescription == detailShortDescription(game: game) ? "" : gameDescription
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.24))
            .frame(height: 1)
    }

    private func nvidiaTechRows(game: OPNCatalogGameObject) -> some View {
        let technologies = nvidiaTechnologies(game: game)
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(technologies.prefix(2), id: \.self) { technology in
                CatalogFeatureAvailabilityRow(title: technology, message: featureMessage(technology), locked: featureIsLocked(technology))
            }
        }
        .padding(.vertical, technologies.isEmpty ? 0 : 2)
        .frame(maxWidth: 660, alignment: .leading)
    }

    private func nvidiaTechnologies(game: OPNCatalogGameObject) -> [String] {
        supportedTechnologyLabels(game: game)
    }

    private func supportedTechnologyLabels(game: OPNCatalogGameObject) -> [String] {
        var values: [String] = []
        for rawValue in game.nvidiaTech + game.featureLabels + game.skuTags {
            if let label = supportedTechnologyLabel(rawValue) { appendUnique(label, to: &values) }
        }
        return values
    }

    private func supportedTechnologyLabel(_ rawValue: String) -> String? {
        let value = rawValue.lowercased()
        if value.contains("reflex") { return "Reflex" }
        if value.contains("rtx") || value.contains("ray tracing") || value.contains("raytracing") { return "RTX" }
        return nil
    }

    private func featureMessage(_ feature: String) -> String {
        feature.localizedCaseInsensitiveContains("reflex") ? "Upgrade your membership to unlock" : "Ready - You may need to turn this on in-game"
    }

    private func featureIsLocked(_ feature: String) -> Bool {
        feature.localizedCaseInsensitiveContains("reflex")
    }

    private func ratingBlock(game: OPNCatalogGameObject) -> some View {
        HStack(alignment: .top, spacing: 18) {
            if !game.ratingLabel.isEmpty {
                CatalogRatingBadge(game: game, shortRating: esrbShortRating(game.ratingLabel))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(game.ratingLabel.isEmpty ? "CLOUD GAMING" : game.ratingLabel.uppercased())
                    .font(.nvidia(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                ForEach(ratingDescriptors(game: game), id: \.self) { descriptor in
                    Text(descriptor)
                        .font(.nvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.70))
                        .frame(maxWidth: 215, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.24)).frame(height: 1).offset(y: 5) }
                }
            }
        }
    }

    private var readMoreButton: some View {
        Button {
            isDescriptionExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(isDescriptionExpanded ? "READ LESS" : "READ MORE")
                Image(systemName: isDescriptionExpanded ? "chevron.up" : "chevron.down")
            }
            .font(.nvidia(size: 13, weight: .bold))
            .foregroundStyle(.white.opacity(0.95))
        }
        .buttonStyle(.plain)
    }

    private func esrbShortRating(_ rating: String) -> String {
        let uppercased = rating.uppercased()
        if uppercased.contains("EVERYONE 10") { return "E10" }
        if uppercased.contains("EVERYONE") { return "E" }
        if uppercased.contains("TEEN") { return "T" }
        if uppercased.contains("MATURE") { return "M" }
        if uppercased.contains("ADULT") { return "A" }
        return String(uppercased.prefix(1))
    }

    private func ratingDescriptors(game: OPNCatalogGameObject) -> [String] {
        var descriptors = game.ratingDescriptors + game.ratingInteractiveElements
        if descriptors.isEmpty { descriptors = game.contentRatings.filter { $0.caseInsensitiveCompare(game.ratingLabel) != .orderedSame } }
        descriptors.removeAll { ["ESRB", "PEGI", "USK", "CLASSIND", "GRAC", "IARC"].contains($0.uppercased()) }
        if descriptors.isEmpty { descriptors = game.genres.prefix(2).map { $0.capitalized } }
        return Array(descriptors.prefix(3))
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
        if !variant.appStoreLabel.isEmpty { return variant.appStoreLabel }
        return variant.appStore.isEmpty ? "GeForce NOW" : viewModel.displayName(forStore: variant.appStore)
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
        VStack(alignment: .leading, spacing: 8) {
            CatalogDetailRow(label: "Publisher", value: game.publisherName)
            CatalogDetailRow(label: "Developer", value: game.developerName)
            CatalogDetailRow(label: "Input", value: inputLine(game: game))
            CatalogDetailRow(label: "Players", value: playerLine(game: game))
            CatalogDetailRow(label: "Release Date", value: releaseDateLine(game: game))
            CatalogDetailRow(label: "Stores", value: game.storeLine)
            CatalogDetailRow(label: "Genres", value: game.genreLine)
        }
    }

    private func releaseDateLine(game: OPNCatalogGameObject) -> String {
        let value = game.releaseDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return value
    }

    private func inputLine(game: OPNCatalogGameObject) -> String {
        var labels: [String] = []
        for control in game.supportedControls { appendUnique(readableControlLabel(control), to: &labels) }
        return labels.joined(separator: ", ")
    }

    private func readableControlLabel(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "_", with: " ").lowercased()
        if normalized.contains("keyboard") || normalized.contains("mouse") { return "Keyboard & Mouse" }
        if normalized.contains("gamepad partial") { return "Partial Gamepad" }
        if normalized.contains("gamepad") || normalized.contains("controller") { return "Gamepad" }
        if normalized.contains("touch") { return "Touchscreen" }
        if normalized.contains("wheel") { return "Wheel" }
        if normalized.contains("flight") || normalized.contains("hotas") { return "Flight Controls" }
        return value.capitalized
    }

    private func playerLine(game: OPNCatalogGameObject) -> String {
        let local = game.maxLocalPlayers
        let online = game.maxOnlinePlayers
        guard local > 0 || online > 0 else { return "" }
        if online > 1, local > 1 { return "1-\(local) local, online multiplayer" }
        if online > 1 { return "Single player, online multiplayer" }
        if local > 1 { return "1-\(local) local players" }
        return "Single player"
    }
}

private struct CatalogDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(label.uppercased())
                    .font(.nvidia(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 112, alignment: .leading)
                Text(value)
                    .font(.nvidia(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct CatalogFeatureAvailabilityRow: View {
    let title: String
    let message: String
    let locked: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: locked ? "lock.fill" : "checkmark.circle.fill")
                .font(.nvidia(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 18)
            Text(title)
                .font(.nvidia(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 84, alignment: .leading)
                .lineLimit(1)
            Text(message)
                .font(.nvidia(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(1)
            Spacer(minLength: 0)
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
        if let cached = await CatalogImageCache.shared.image(for: url) {
            guard !Task.isCancelled else { return }
            image = cached.image
            hasFailed = false
            isLoading = false
            onScrimColorChange(CatalogHeroImageMetadata.scrimColor(from: cached.data) ?? .black)
        } else {
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
        CatalogCachedImageView(url: url, contentMode: contentMode, placeholder: CatalogImageFallback().overlay { ProgressView().controlSize(.small) }, failure: CatalogImageFallback())
    }
}

private struct CatalogCachedImageView<Placeholder: View, Failure: View>: View {
    let url: URL?
    let contentMode: ContentMode
    let placeholder: Placeholder
    let failure: Failure

    @State private var image: NSImage?
    @State private var hasFailed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if hasFailed {
                failure
            } else {
                placeholder
            }
        }
        .task(id: url) { await loadImage() }
    }

    @MainActor
    private func loadImage() async {
        image = nil
        hasFailed = false
        guard let url else {
            hasFailed = true
            return
        }
        guard let cached = await CatalogImageCache.shared.image(for: url), !Task.isCancelled else {
            hasFailed = !Task.isCancelled
            return
        }
        image = cached.image
        hasFailed = false
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
    @State private var copiedDetails = false

    var body: some View {
        let presentation = CatalogErrorPresentation(rawMessage: message)
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Rectangle()
                    .fill(Color.openNowGreen.opacity(0.13))
                Image(systemName: systemImage)
                    .font(.nvidia(size: 15, weight: .bold))
                    .foregroundStyle(Color.openNowGreen)
            }
            .frame(width: 36, height: 36)
            .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.30), lineWidth: 1) }

            VStack(alignment: .leading, spacing: 5) {
                Text(presentation.title)
                    .font(.nvidia(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.90))
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = presentation.hint {
                    Text(hint)
                        .font(.nvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.60))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if let details = presentation.technicalDetails {
                Button { copy(details) } label: {
                    Text(copiedDetails ? "COPIED" : "COPY DETAILS")
                        .font(.nvidia(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.76))
                        .tracking(0.7)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Color.white.opacity(0.065))
                        .overlay { Rectangle().stroke(Color.white.opacity(0.13), lineWidth: 1) }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.060))
        .overlay(alignment: .leading) { Rectangle().fill(Color.openNowGreen).frame(width: 3) }
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        copiedDetails = true
    }
}

private struct CatalogErrorPresentation {
    let title: String
    let hint: String?
    let technicalDetails: String?

    init(rawMessage: String) {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.looksLikeClaimFailure(message) {
            title = "GeForce NOW could not start this session."
            hint = Self.claimFailureHint(from: message)
            technicalDetails = message
            return
        }
        if Self.looksTechnical(message) {
            title = "OpenNOW received an unexpected service response."
            hint = "Try again in a moment. If it keeps happening, copy the details for diagnostics."
            technicalDetails = message
            return
        }
        title = message.isEmpty ? "Something went wrong." : message
        hint = nil
        technicalDetails = nil
    }

    private static func looksLikeClaimFailure(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("Claim HTTP") || message.localizedCaseInsensitiveContains("Claim API error")
    }

    private static func looksTechnical(_ message: String) -> Bool {
        message.count > 220 || message.contains("{\"") || message.contains("requestStatus") || message.contains("HTTP 400")
    }

    private static func claimFailureHint(from message: String) -> String {
        if message.localizedCaseInsensitiveContains("SESSION_NOT_PAUSED") {
            return "The existing cloud session is still shutting down. Wait a moment, then try again."
        }
        if message.localizedCaseInsensitiveContains("SESSION_LIMIT") {
            return "Your account appears to have reached the active session limit. End another session, then try again."
        }
        if let statusDescription = requestStatusDescription(from: message), !statusDescription.isEmpty {
            if statusDescription.localizedCaseInsensitiveContains("INTERNAL_ERROR_STATUS") {
                return "GeForce NOW returned an internal session error while claiming the launch slot. Try again, or switch server location if it repeats."
            }
            return "GeForce NOW rejected the launch request (\(statusDescription)). Try again or switch server location."
        }
        return "Try again in a moment. If it repeats, refresh your NVIDIA session or switch server location."
    }

    private static func requestStatusDescription(from message: String) -> String? {
        guard let json = jsonPayload(from: message),
              let requestStatus = json["requestStatus"] as? [String: Any] else { return nil }
        return requestStatus["statusDescription"] as? String
    }

    private static func jsonPayload(from message: String) -> [String: Any]? {
        guard let start = message.firstIndex(of: "{") else { return nil }
        let jsonString = String(message[start...])
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
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

private struct CatalogRatingBadge: View {
    let game: OPNCatalogGameObject
    let shortRating: String

    var body: some View {
        if let url = URL(string: game.ratingImageUrl), !game.ratingImageUrl.isEmpty {
            CatalogCachedImageView(url: url, contentMode: .fit, placeholder: fallbackBadge, failure: fallbackBadge)
                .frame(width: 58, height: 76)
                .background(.white)
        } else {
            fallbackBadge
        }
    }

    private var fallbackBadge: some View {
        VStack(spacing: 0) {
            Text(game.ratingLabel.uppercased())
                .font(.system(size: game.ratingLabel.count > 8 ? 7 : 8, weight: .black))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            Spacer(minLength: 0)
            Text(shortRating)
                .font(.system(size: shortRating.count > 2 ? 24 : 33, weight: .black, design: .default))
                .foregroundStyle(.black)
                .minimumScaleFactor(0.65)
            Spacer(minLength: 0)
            Text(game.ratingSystemName.isEmpty ? "CONTENT RATED" : "CONTENT RATED BY")
                .font(.system(size: 5.5, weight: .black))
                .foregroundStyle(.black)
                .lineLimit(1)
            Text(game.ratingSystemName.isEmpty ? "" : game.ratingSystemName.uppercased())
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.black)
                .padding(.bottom, 4)
        }
        .frame(width: 58, height: 76)
        .background(.white)
        .overlay { Rectangle().stroke(.black, lineWidth: 2) }
    }
}

private extension OPNCatalogGameObject {
    var catalogIdentity: String { CatalogViewModel.identity(for: self) }

    var cardBadgeLabel: String? {
        CatalogCardBadgeMapper.label(promoTag: promoTag, campaignIds: campaignIds, skuTags: skuTags, genres: genres, featureLabels: featureLabels)
    }

    var bestHeroImageURL: String {
        for key in ["MARQUEE_HERO_IMAGE", "HERO_IMAGE"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        if !heroImageUrl.isEmpty { return heroImageUrl }
        return bestTileImageURL
    }

    var bestMarqueeHeroImageURL: String {
        if let value = imageUrlsByType["MARQUEE_HERO_IMAGE"]?.first, !value.isEmpty { return value }
        if let value = imageUrlsByType["marquee_hero_image"]?.first, !value.isEmpty { return value }
        return bestHeroImageURL
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

    var bestStorePickerPosterURL: String {
        for key in ["GAME_BOX_ART", "BOX_ART", "BOXART", "KEY_ART", "KEY_IMAGE"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
            if let value = imageUrlsByType[key.lowercased()]?.first, !value.isEmpty { return value }
        }
        return bestTileImageURL
    }

    var bestWideImageURL: String {
        for key in ["TV_BANNER"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
            if let value = imageUrlsByType[key.lowercased()]?.first, !value.isEmpty { return value }
        }
        return bestTileImageURL
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
        if !ratingCategoryTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ratingCategoryTitle }
        return contentRatings.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    var supportsKeyboard: Bool {
        supportedControls.contains { control in
            let value = control.lowercased()
            return value.contains("keyboard") || value.contains("mouse")
        }
    }

    var supportsGamepad: Bool {
        supportedControls.contains { control in
            let value = control.lowercased()
            return value.contains("gamepad") || value.contains("controller")
        }
    }

    var genreLine: String { genres.prefix(3).joined(separator: " / ") }

    var storeLine: String {
        let stores = availableStores.isEmpty ? variants.map(\.appStore) : availableStores
        return stores.filter { !$0.isEmpty }.map { $0.uppercased() }.joined(separator: ", ")
    }

    var advancedSearchText: String {
        var values = [
            id,
            uuid,
            launchAppId,
            title,
            shortName,
            gameDescription,
            shortDescription,
            longDescription,
            developerName,
            publisherName,
            releaseDate,
            playType,
            membershipTierLabel,
            playabilityState,
            ratingSystemName,
            ratingCategoryKey,
            ratingCategoryTitle,
            promoTag,
            primaryStoreLabel,
            genreLine,
            storeLine
        ]
        values.append(contentsOf: genres)
        values.append(contentsOf: featureLabels)
        values.append(contentsOf: supportedControls)
        values.append(contentsOf: contentRatings)
        values.append(contentsOf: ratingDescriptors)
        values.append(contentsOf: ratingInteractiveElements)
        values.append(contentsOf: nvidiaTech)
        values.append(contentsOf: availableStores)
        values.append(contentsOf: campaignIds)
        values.append(contentsOf: skuTags)
        for variant in variants {
            values.append(contentsOf: [variant.id, variant.appStore, variant.appStoreLabel, variant.serviceStatus])
            if variant.inLibrary || variant.librarySelected { values.append("owned in library") }
        }
        if isInLibrary { values.append("owned in library") }
        return values.joined(separator: " ").lowercased()
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
