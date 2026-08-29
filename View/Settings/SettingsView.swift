import AppKit
import CryptoKit
import SwiftUI

enum SettingsVendorLayout {
    static let surface = OpenNOWDesign.Surface.deep
    static let sidebar = Color(red: 31 / 255, green: 32 / 255, blue: 31 / 255)
    static let card = Color(red: 26 / 255, green: 27 / 255, blue: 26 / 255)
    static let cardRaised = Color(red: 34 / 255, green: 35 / 255, blue: 34 / 255)
    static let row = Color.white.opacity(0.045)
}

extension Font {
    static func settingsNvidia(size: CGFloat, weight: OpenNOWNVIDIAFont.Weight = .regular) -> Font {
        OpenNOWNVIDIAFont.font(size: size, weight: weight)
    }
}

extension Color {
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

struct SettingsAccountSnapshot: Sendable {
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

struct SettingsRouteSnapshot {
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

enum SettingsAppMetadata {
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

enum SettingsFormat {
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
    /// Set only when controller mode embeds this page; nil on the desktop surface.
    @Environment(\.controllerPageCommand) private var controllerPageCommand
    @StateObject private var focus = ControllerSettingsFocus()

    private static let tabBarFocusID = "settings-tabs"

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $viewModel.selectedSettingsGroup, uiScale: uiScale)
                .controllerFocusable(id: Self.tabBarFocusID, adjust: { moveGroup(delta: $0) })
            SettingsContent(viewModel: viewModel, uiScale: uiScale, focusedID: focus.focusedID)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.controllerSettingsFocus, focus)
        .environment(\.controllerFocusedRowID, focus.isActive ? focus.focusedID : nil)
        .environment(\.controllerFocusActive, focus.isActive)
        .environment(\.controllerRowCommand, focus.rowCommand)
        .coordinateSpace(name: controllerSettingsFocusSpace)
        .onPreferenceChange(ControllerFocusOrderKey.self) { entries in
            focus.setOrder(entries)
        }
        .onAppear { focus.setActive(controllerPageCommand != nil) }
        .onChange(of: controllerPageCommand) { _, pageCommand in
            guard let pageCommand else { return }
            focus.setActive(true)
            apply(pageCommand.command)
        }
        .onChange(of: viewModel.selectedSettingsGroup) { _, _ in focus.focus(Self.tabBarFocusID) }
    }

    /// Up/down walk the tab bar and the focusable rows as one list, left/right act on whatever is
    /// focused - switching tab on the bar, or adjusting a slider, option or toggle on a row - and
    /// confirm presses it.
    private func apply(_ command: ControllerInputCommand) {
        // The first press only takes focus, so nothing changes value before the user can see what
        // is selected.
        if focus.focusFirstIfNeeded() { return }
        switch command {
        case .move(.up):
            focus.move(delta: -1)
        case .move(.down):
            focus.move(delta: 1)
        case .move(.left), .move(.right), .confirm:
            focus.send(command)
        default:
            break
        }
    }

    private func moveGroup(delta: Int) {
        let groups = CatalogSettingsGroup.allCases
        let current = groups.firstIndex(of: viewModel.selectedSettingsGroup) ?? 0
        let next = min(max(current + delta, 0), groups.count - 1)
        guard next != current else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            viewModel.selectedSettingsGroup = groups[next]
        }
    }
}

struct SettingsSurfaceBackground: View {
    var body: some View {
        ZStack {
            SettingsVendorLayout.surface
            LinearGradient(colors: [OpenNOWDesign.accent.opacity(0.035), .clear], startPoint: .topLeading, endPoint: .center)
            LinearGradient(colors: [.black.opacity(0.22), .clear, .black.opacity(0.18)], startPoint: .leading, endPoint: .trailing)
        }
    }
}

struct SettingsTabBar: View {
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

struct SettingsTabItem: View {
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
                    .foregroundStyle(isSelected ? OpenNOWDesign.accent : .white.opacity(0.52))
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
                    .fill(isSelected ? OpenNOWDesign.accent : .clear)
                    .frame(width: 150 * uiScale, height: 3 * uiScale)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsContent: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    /// The row the pad currently has focus on; the page scrolls to keep it visible.
    var focusedID: String?

    var body: some View {
        ScrollViewReader { proxy in
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
        .onChange(of: focusedID) { _, id in
            guard let id else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsSurfaceBackground())
        }
    }

    @ViewBuilder private var page: some View {
        switch viewModel.selectedSettingsGroup {
        case .account:
            AccountSettingsPage(viewModel: viewModel)
        case .streaming:
            StreamingSettingsGroup(viewModel: viewModel)
        case .network:
            NetworkSettingsGroup(viewModel: viewModel)
        case .connections:
            ConnectionsSettingsGroup(viewModel: viewModel)
        case .controller:
            SteamControllerSettingsPage(uiScale: uiScale)
        case .general:
            GeneralSettingsGroup(viewModel: viewModel)
        case .experimental:
            ExperimentalFeaturesSettingsPage(viewModel: viewModel, uiScale: uiScale)
        case .about:
            AboutSettingsGroup(viewModel: viewModel, uiScale: uiScale)
        }
    }
}

struct SettingsHeader: View {
    let title: String
    let subtitle: String
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            HStack(alignment: .bottom, spacing: 18 * uiScale) {
                VStack(alignment: .leading, spacing: 8 * uiScale) {
                    Text(title.uppercased())
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.accent)
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
