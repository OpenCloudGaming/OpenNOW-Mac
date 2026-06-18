import Common
import CoreText
import SwiftUI

private enum SettingsVendorLayout {
    static let surface = Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255)
    static let sidebar = Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255)
    static let card = Color(red: 28 / 255, green: 28 / 255, blue: 28 / 255)
}

private enum SettingsVendorFont {
    enum Weight: Hashable {
        case regular
        case medium
        case bold
    }

    static func font(size: CGFloat, weight: Weight = .regular) -> Font {
        Font(nsFont(size: size, weight: weight))
    }

    private static func nsFont(size: CGFloat, weight: Weight) -> NSFont {
        if let descriptor = descriptors[weight] ?? nil {
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
    static func settingsNvidia(size: CGFloat, weight: SettingsVendorFont.Weight = .regular) -> Font {
        SettingsVendorFont.font(size: size, weight: weight)
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
        .background(SettingsVendorLayout.surface)
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
                Text("GeForce NOW")
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
                        Text(page.title)
                            .font(.settingsNvidia(size: 14, weight: viewModel.selectedSettingsPage == page ? .bold : .medium))
                            .foregroundStyle(viewModel.selectedSettingsPage == page ? .white : .white.opacity(0.68))
                        Spacer(minLength: 0)
                    }
                    .frame(height: 48)
                    .background(viewModel.selectedSettingsPage == page ? Color.white.opacity(0.065) : .clear)
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
            .padding(22)
        }
        .frame(width: 256)
        .background(SettingsVendorLayout.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.black.opacity(0.38)).frame(width: 1) }
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
            .padding(.horizontal, 42)
            .padding(.top, 34)
            .padding(.bottom, 54)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.openNowGreen)
    }

    @ViewBuilder private var page: some View {
        switch viewModel.selectedSettingsPage {
        case .account:
            AccountSettingsPage(viewModel: viewModel)
        case .connections:
            ConnectionsSettingsPage(viewModel: viewModel)
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
        case .connections: return "Manage store accounts used for library sync and ownership detection."
        case .gameplay: return "Tune streaming quality, latency, input, audio, and microphone behavior."
        case .serverLocation: return "Select Automatic or a measured Cloudmatch region for launches."
        case .resolutionUpscaling: return "Control image enhancement, sharpening, denoise, and target quality."
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
    }
}

private struct AccountSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "NVIDIA Account") {
                HStack(alignment: .center, spacing: 18) {
                    VendorResourceImage(name: "avatar_generic_118", fileExtension: "svg")
                        .scaledToFit()
                        .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(viewModel.account.displayName)
                            .font(.settingsNvidia(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                        Text(viewModel.account.email)
                            .font(.settingsNvidia(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    Spacer()
                    Text((viewModel.account.membershipTier.isEmpty ? "Performance" : viewModel.account.membershipTier).uppercased())
                        .font(.settingsNvidia(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Color.openNowGreen)
                }
                SettingsDivider()
                SettingsInfoRow(label: "Provider", value: viewModel.account.providerName.isEmpty ? "NVIDIA" : viewModel.account.providerName)
                SettingsInfoRow(label: "Authorization", value: viewModel.account.authorizationState)
                SettingsInfoRow(label: "Status", value: viewModel.account.authStatus)
                SettingsInfoRow(label: "Preferred Region", value: viewModel.selectedSettingsRegionUrl.isEmpty ? "Automatic" : viewModel.selectedSettingsRegionUrl)
            }

            SettingsCard(title: "Playtime Statistics") {
                if viewModel.playtimeStatistics.sessionCount == 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No completed streams recorded yet.")
                            .font(.settingsNvidia(size: 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.86))
                        Text("OpenNOW will track local playtime after your next GeForce NOW session ends.")
                            .font(.settingsNvidia(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                    }
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
                        SettingsInfoRow(label: "Most Recent Game", value: viewModel.playtimeStatistics.lastPlayedTitle)
                    }
                }
            }
        }
    }

    private var lastPlayedText: String {
        guard let date = viewModel.playtimeStatistics.lastPlayedAt else { return "-" }
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

private struct ConnectionsSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        SettingsCard(title: "Store Connections") {
            if viewModel.storeDefinitions.isEmpty && viewModel.accountStores.isEmpty {
                SettingsInfoRow(label: "Stores", value: "No account providers returned by GeForce NOW.")
            } else {
                let stores = connectionStores
                ForEach(stores, id: \.self) { store in
                    StoreConnectionRow(viewModel: viewModel, store: store)
                    if store != stores.last { SettingsDivider() }
                }
            }
        }
    }

    private var connectionStores: [String] {
        var seen = Set<String>()
        var stores: [String] = []
        for store in viewModel.storeDefinitions.map(\.store) + viewModel.accountStores.map(\.store) where !store.isEmpty {
            let key = store.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            stores.append(store)
        }
        return stores.sorted { viewModel.displayName(forStore: $0) < viewModel.displayName(forStore: $1) }
    }
}

private struct StoreConnectionRow: View {
    @ObservedObject var viewModel: CatalogViewModel
    let store: String

    var body: some View {
        let account = viewModel.accountStatus(forStore: store)
        let definition = viewModel.storeDefinitions.first { $0.store.caseInsensitiveCompare(store) == .orderedSame }
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(viewModel.displayName(forStore: store))
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(statusText(account))
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer()
            if account?.hasAccountSyncingData == true {
                SettingsActionButton(title: "SYNC") { viewModel.syncStoreAccount(store) }
            }
            if definition?.isAccountLinkingSupported == true || account?.hasAccountLinkingData == true {
                SettingsActionButton(title: account == nil ? "CONNECT" : "MANAGE") { viewModel.linkStoreAccount(store) }
            }
        }
    }

    private func statusText(_ account: CatalogStoreAccount?) -> String {
        guard let account else { return "Not connected" }
        if !account.userDisplayName.isEmpty { return "Connected as \(account.userDisplayName)" }
        if !account.userIdentifier.isEmpty { return "Connected as \(account.userIdentifier)" }
        if account.totalSyncedGames > 0 { return "\(account.totalSyncedGames) synced games" }
        if !account.syncState.isEmpty { return account.syncState.replacingOccurrences(of: "_", with: " ").capitalized }
        return "Connected"
    }
}

private struct GameplaySettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                SettingsToggleRow(title: "Direct Mouse Input", subtitle: "Send mouse input directly to the stream.", isOn: viewModel.streamProfile.directMouseInput, action: viewModel.setDirectMouseInputEnabled)
                SettingsDivider()
                SettingsToggleRow(title: "Suppress Input When Inactive", subtitle: "Avoid sending input while OpenNOW is not focused.", isOn: viewModel.streamProfile.suppressInputWhenInactive, action: viewModel.setSuppressInputWhenInactive)
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
        }
    }

    private var selectedMicrophoneModeIndex: Int {
        OPNStreamPreferences.microphoneModeOptions.firstIndex { $0.value == viewModel.streamProfile.microphoneMode } ?? 0
    }

    private var selectedMicrophoneDeviceIndex: Int {
        viewModel.microphoneDeviceOptions.firstIndex { $0.uniqueId == viewModel.streamProfile.microphoneDeviceId } ?? 0
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct ServerLocationSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        SettingsCard(title: "Server Location") {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cloudmatch Region")
                        .font(.settingsNvidia(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Automatic chooses the best measured GeForce NOW route.")
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
                SettingsActionButton(title: viewModel.isRefreshingSettingsRegions ? "PINGING" : "REFRESH") { viewModel.refreshSettingsRegions() }
                    .disabled(viewModel.isRefreshingSettingsRegions)
            }
            SettingsDivider()
            VStack(spacing: 8) {
                ForEach(viewModel.settingsRegionOptions, id: \.url) { option in
                    SettingsRegionRow(option: option, selected: option.url == viewModel.selectedSettingsRegionUrl) {
                        viewModel.selectSettingsRegion(option.url)
                    }
                }
            }
        }
    }
}

private struct ResolutionUpscalingSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Resolution Upscaling") {
                SettingsOptionRow(title: "Upscaling Mode", subtitle: "Controls client-side presentation enhancement.", options: OPNStreamPreferences.upscalingModeOptions.map(\.label), selectedIndex: viewModel.streamProfile.upscalingModeIndex, action: viewModel.setUpscalingModeIndex)
                SettingsDivider()
                SettingsInfoRow(label: "Target", value: viewModel.streamProfile.upscalingTargetOption.label)
                SettingsDivider()
                SettingsSliderRow(title: "Sharpness", valueText: "\(viewModel.streamProfile.upscalingSharpness)", value: Double(viewModel.streamProfile.upscalingSharpness), range: 0...40, action: viewModel.setUpscalingSharpness)
                SettingsDivider()
                SettingsSliderRow(title: "Denoise", valueText: "\(viewModel.streamProfile.upscalingDenoise)", value: Double(viewModel.streamProfile.upscalingDenoise), range: 0...20, action: viewModel.setUpscalingDenoise)
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

    var body: some View {
        SettingsCard(title: "System") {
            SettingsInfoRow(label: "Display", value: "\(viewModel.streamCapabilities.maxDisplayWidth) x \(viewModel.streamCapabilities.maxDisplayHeight)")
            SettingsInfoRow(label: "Refresh Rate", value: viewModel.streamCapabilities.maxDisplayRefreshRate > 0 ? "\(viewModel.streamCapabilities.maxDisplayRefreshRate) Hz" : "Unknown")
            SettingsInfoRow(label: "DPI", value: "\(viewModel.streamCapabilities.displayDpi)")
            SettingsInfoRow(label: "HDR Display", value: viewModel.streamCapabilities.hdrDisplaySupported ? "Supported" : "Unavailable")
            SettingsDivider()
            SettingsInfoRow(label: "H.264 Decode", value: viewModel.streamCapabilities.h264HardwareDecodeSupported ? "Hardware" : "Software")
            SettingsInfoRow(label: "HEVC Decode", value: viewModel.streamCapabilities.h265HardwareDecodeSupported ? "Supported" : "Unavailable")
            SettingsInfoRow(label: "AV1 Decode", value: viewModel.streamCapabilities.av1HardwareDecodeSupported ? "Supported" : "Unavailable")
            SettingsDivider()
            SettingsInfoRow(label: "Device ID", value: viewModel.session.deviceId)
            SettingsInfoRow(label: "Current Region", value: viewModel.selectedSettingsRegionUrl.isEmpty ? "Automatic" : viewModel.selectedSettingsRegionUrl)
        }
    }
}

private struct AboutSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        SettingsCard(title: "About OpenNOW") {
            HStack(spacing: 18) {
                VendorResourceImage(name: "nv-gfn-logo_v3", fileExtension: "png")
                    .scaledToFit()
                    .frame(width: 132, height: 40, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Text("OpenNOW Mac")
                        .font(.settingsNvidia(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Vendor-style GeForce NOW client shell")
                        .font(.settingsNvidia(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
            SettingsDivider()
            SettingsInfoRow(label: "Version", value: appVersion)
            SettingsInfoRow(label: "Account", value: viewModel.account.displayName)
            SettingsInfoRow(label: "User ID", value: viewModel.session.userId.isEmpty ? viewModel.account.userId : viewModel.session.userId)
            SettingsInfoRow(label: "Streaming", value: "WebRTC")
            SettingsInfoRow(label: "Cloudmatch", value: viewModel.selectedSettingsRegionUrl.isEmpty ? "Automatic" : viewModel.selectedSettingsRegionUrl)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
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
            Text(title.uppercased())
                .font(.settingsNvidia(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.58))
                .tracking(1.1)
                .padding(.horizontal, 18)
                .padding(.top, 17)
                .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsVendorLayout.card)
        .overlay { Rectangle().stroke(Color.white.opacity(0.09), lineWidth: 1) }
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
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.settingsNvidia(size: 12, weight: .bold))
                .foregroundStyle(.black)
                .tracking(0.8)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Color.openNowGreen)
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsRegionRow: View {
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
                        .font(.settingsNvidia(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text(option.automatic ? "Best measured route" : "Cloudmatch region")
                        .font(.settingsNvidia(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                }
                Spacer()
                Text(option.latencyMs >= 0 ? "\(option.latencyMs) ms" : "Measuring")
                    .font(.settingsNvidia(size: 12, weight: .bold))
                    .foregroundStyle(selected ? Color.openNowGreen : .white.opacity(0.70))
            }
            .padding(12)
            .background(selected ? Color.openNowGreen.opacity(0.12) : Color.white.opacity(0.045))
            .overlay { Rectangle().stroke(selected ? Color.openNowGreen.opacity(0.72) : Color.white.opacity(0.08), lineWidth: 1) }
        }
        .buttonStyle(.plain)
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
