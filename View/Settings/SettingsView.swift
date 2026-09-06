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
    @StateObject private var focus = ControllerSettingsFocusModel()
    @AppStorage(OpenNOWInterfacePreferences.controllerModeEnabledKey) private var controllerModeEnabled = false
    @State private var windowWidth: CGFloat = 0

    private static let tabBarFocusID = "settings-tabs"

    /// Read from the preference, not from having received a pad command: `controllerPageCommand` is
    /// nil until the first press, so keying the layout off it drew the desktop sidebar inside the
    /// controller shell and then swapped it out under the reader's first input.
    private var isPadDriven: Bool { controllerModeEnabled }

    var body: some View {
        Group {
            if isPadDriven {
                // Controller mode already stacks a header and a row of destination pills above this
                // page. A second, vertical list of destinations beside them would be a rail inside a
                // rail, and the pad's focus order is a single top-to-bottom list, so the strip is
                // both the lighter and the navigable choice there.
                VStack(spacing: 0) {
                    SettingsTabBar(selection: $viewModel.selectedSettingsGroup, groups: visibleGroups, uiScale: uiScale)
                        .controllerFocusable(id: Self.tabBarFocusID, adjust: { moveGroup(delta: $0) })
                    SettingsContent(viewModel: viewModel, uiScale: uiScale, focusedID: focus.focusedID)
                }
            } else {
                HStack(spacing: 0) {
                    SettingsSidebar(
                        selection: $viewModel.selectedSettingsGroup,
                        groups: visibleGroups,
                        uiScale: uiScale,
                        showsLabels: windowWidth <= 0 || windowWidth / max(uiScale, 0.01) >= SettingsSidebar.labelMinimumWidth,
                        onSelectSearchResult: { entry in
                            viewModel.selectedSettingsGroup = entry.group
                            viewModel.pendingSettingsSectionID = entry.sectionID
                        }
                    )
                    SettingsContent(viewModel: viewModel, uiScale: uiScale, focusedID: focus.focusedID)
                }
                .background {
                    GeometryReader { window in
                        Color.clear.preference(key: SettingsWindowWidthKey.self, value: window.size.width)
                    }
                }
                .onPreferenceChange(SettingsWindowWidthKey.self) { windowWidth = $0 }
            }
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
        .onChange(of: viewModel.selectedSettingsGroup) { _, _ in
            focus.focus(Self.tabBarFocusID)
            viewModel.didSwitchToCustomStreamingProfile = false
        }
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

    /// Excludes tabs the current configuration has no use for, so pad navigation and the tab bar
    /// agree on what exists. Iterating `allCases` in one place and a filtered list in the other
    /// would let the pad land on a tab that is not drawn.
    private var visibleGroups: [CatalogSettingsGroup] {
        CatalogSettingsGroup.visibleCases()
    }

    private func moveGroup(delta: Int) {
        let groups = visibleGroups
        let current = groups.firstIndex(of: viewModel.selectedSettingsGroup) ?? 0
        let next = min(max(current + delta, 0), groups.count - 1)
        guard next != current else { return }
        viewModel.selectedSettingsGroup = groups[next]
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
    let groups: [CatalogSettingsGroup]
    let uiScale: CGFloat

    @Namespace private var pill
    @State private var viewportWidth: CGFloat = 0
    @State private var fades = SettingsTabEdgeFades()

    private static let scrollSpace = "opn-settings-tabs-scroll"
    private static let slide = Animation.easeInOut(duration: 0.18)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4 * uiScale) {
                    ForEach(groups) { group in
                        SettingsTabItem(
                            title: group.title,
                            icon: group.icon,
                            isSelected: selection == group,
                            uiScale: uiScale,
                            showsBetaTag: Self.betaGroups.contains(group),
                            pill: pill
                        ) {
                            selection = group
                        }
                        .id(group)
                    }
                }
                .padding(.horizontal, 16 * uiScale)
                // Scoped to the bar. Animating the selection itself would put the whole settings
                // page - every row of the tab being left and the one being entered - inside the
                // same transaction, which is what makes a tab switch feel heavy.
                .animation(Self.slide, value: selection)
                .background { scrollProbe }
            }
            .coordinateSpace(name: Self.scrollSpace)
            .background {
                GeometryReader { viewport in
                    Color.clear.preference(key: SettingsTabViewportKey.self, value: viewport.size.width)
                }
            }
            .onPreferenceChange(SettingsTabViewportKey.self) { viewportWidth = $0 }
            .onPreferenceChange(SettingsTabEdgeFadesKey.self) { fades = $0 }
            .mask { edgeMask }
            .onChange(of: selection) { _, group in
                withAnimation(Self.slide) { proxy.scrollTo(group, anchor: .center) }
            }
        }
        .frame(height: 48 * uiScale)
        .background(SettingsVendorLayout.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    /// Publishes the two booleans the fades need rather than the raw offset. The offset changes on
    /// every scroll frame; the booleans flip twice in the life of the bar, and SwiftUI drops a
    /// preference update whose value is equal to the last one - so scrolling costs no state writes.
    private var scrollProbe: some View {
        GeometryReader { content in
            Color.clear.preference(
                key: SettingsTabEdgeFadesKey.self,
                value: SettingsTabEdgeFades(
                    offset: -content.frame(in: .named(Self.scrollSpace)).minX,
                    contentWidth: content.size.width,
                    viewportWidth: viewportWidth
                )
            )
        }
    }

    /// Tabs scrolled past the edge fade out instead of being cut mid-glyph. Each side is present
    /// only while there is something to scroll to on it, so a bar that fits shows no fade at all.
    private var edgeMask: some View {
        let fade = 26 * uiScale
        return HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: fades.leading ? fade : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: fades.trailing ? fade : 0)
        }
    }
}

/// Which edges of the tab strip still have tabs hidden behind them.
struct SettingsTabEdgeFades: Equatable {
    var leading = false
    var trailing = false

    init() {}

    init(offset: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat) {
        // A pixel of slack: the offset lands fractionally off zero during a rubber-band bounce, and
        // a bar that is not scrollable at all should never flash a fade.
        let slack: CGFloat = 1
        leading = offset > slack
        trailing = contentWidth - viewportWidth - offset > slack
    }
}

struct SettingsTabEdgeFadesKey: PreferenceKey {
    static let defaultValue = SettingsTabEdgeFades()

    static func reduce(value: inout SettingsTabEdgeFades, nextValue: () -> SettingsTabEdgeFades) {
        value = nextValue()
    }
}

struct SettingsTabViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension SettingsTabBar {
    /// A tab wears the tag only when everything on it is beta. Network no longer qualifies: its
    /// server location and transport rows are settled and only the session proxy card is still
    /// moving, so that card carries its own badge instead of tagging the whole destination.
    static let betaGroups: Set<CatalogSettingsGroup> = [.remoteCoOp]
}

struct SettingsTabItem: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let uiScale: CGFloat
    var showsBetaTag = false
    /// Shared so the selected pill slides between tabs rather than blinking from one to the next.
    let pill: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    /// Square, like every other selected control in Settings - the option chips, the cards and
    /// the BETA tag all use hard corners, and a capsule here read as a different design language.
    private var shape: Rectangle { Rectangle() }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8 * uiScale) {
                Image(systemName: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(isSelected ? OpenNOWDesign.accent : .white.opacity(isHovering ? 0.72 : 0.5))
                    .frame(width: 15 * uiScale, height: 15 * uiScale)
                Text(title)
                    .font(.settingsNvidia(size: 12.5 * uiScale, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? .white : .white.opacity(isHovering ? 0.85 : 0.58))
                    .lineLimit(1)
                    .fixedSize()
                if showsBetaTag { OpenNOWBetaTag(uiScale: uiScale * 0.85, compact: true) }
            }
            .padding(.horizontal, 14 * uiScale)
            .frame(height: 34 * uiScale)
            .background { background }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    @ViewBuilder private var background: some View {
        if isSelected {
            shape
                .fill(OpenNOWDesign.accent.opacity(0.14))
                .overlay(shape.strokeBorder(OpenNOWDesign.accent.opacity(0.34), lineWidth: 1))
                .matchedGeometryEffect(id: "settings-tab-pill", in: pill)
        } else if isHovering {
            shape.fill(Color.white.opacity(0.06))
        }
    }
}

struct SettingsContent: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    /// The row the pad currently has focus on; the page scrolls to keep it visible.
    var focusedID: String?

    @Environment(\.controllerFocusActive) private var isPadFocusActive
    @AppStorage(OpenNOWInterfacePreferences.controllerModeEnabledKey) private var controllerModeEnabled = false
    @State private var contentWidth: CGFloat = 0
    @State private var activeSectionID: String?

    var body: some View {
        if viewModel.selectedSettingsGroup.isEmptyStatePage {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsSurfaceBackground())
        } else {
            scrollingPage
        }
    }

    private var scrollingPage: some View {
        ScrollViewReader { proxy in
        ScrollView {
            SettingsStack(spacing: 22 * uiScale) {
                SettingsHeader(
                    title: viewModel.selectedSettingsGroup.title,
                    subtitle: viewModel.selectedSettingsGroup.subtitle,
                    uiScale: uiScale
                )
                if sections.count > 1 {
                    SettingsSectionBar(sections: sections, activeID: activeSectionID, uiScale: uiScale) { id in
                        withAnimation(.easeOut(duration: 0.20)) { proxy.scrollTo(id, anchor: .top) }
                    }
                }
                if !viewModel.errorMessage.isEmpty {
                    SettingsMessageView(message: viewModel.errorMessage, systemImage: "exclamationmark.triangle.fill", uiScale: uiScale)
                }
                if !viewModel.actionMessage.isEmpty {
                    SettingsMessageView(message: viewModel.actionMessage, systemImage: "checkmark.circle.fill", uiScale: uiScale)
                }
                // Preset-managed rows live on more than one destination, so the notice belongs to
                // the page frame rather than to Video: L4S is on Network, and an explanation the
                // reader has to go looking for on another tab explains nothing.
                if viewModel.didSwitchToCustomStreamingProfile {
                    SettingsMessageView(
                        message: "Switched to the Custom quality profile so your edit could apply. Pick a preset again to go back to its values.",
                        systemImage: "slider.horizontal.3",
                        uiScale: uiScale
                    )
                }
                page
            }
            .padding(.horizontal, 28 * uiScale)
            .padding(.top, 28 * uiScale)
            .padding(.bottom, 48 * uiScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Measured inside the padding, so this is the width a card actually gets - the scroll
            // view's own frame still carries the padding and, when scrollers are set to always
            // show, the width of the scroller too.
            .background {
                GeometryReader { cards in
                    Color.clear.preference(key: SettingsContentWidthKey.self, value: cards.size.width)
                }
            }
        }
        .coordinateSpace(name: settingsPageCoordinateSpace)
        .onPreferenceChange(SettingsContentWidthKey.self) { width in
            // A destination change rebuilds the measured subtree and republishes zero for a frame.
            // Taking it would collapse a wide page to one column and then reflow it back.
            guard width > 0 else { return }
            contentWidth = width
        }
        .onPreferenceChange(SettingsSectionMarksKey.self) { marks in
            activeSectionID = Self.activeSection(marks: marks, sections: sections) ?? activeSectionID
        }
        .onAppear { jumpToPendingSection(proxy) }
        .onChange(of: viewModel.pendingSettingsSectionID) { _, _ in jumpToPendingSection(proxy) }
        // A fresh scroll view per tab: the offset from a long page would otherwise
        // survive the switch and park a shorter page's viewport past its content.
        .id(viewModel.selectedSettingsGroup)
        .onChange(of: focusedID) { _, id in
            guard let id else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsSurfaceBackground())
        .environment(\.opnSettingsWideLayout, usesTwoColumns)
        .environment(\.opnSettingsNarrowRows, usesNarrowRows)
        .environment(\.opnSettingsCardWidth, contentWidth)
        }
    }

    /// Takes a search result to its card. Never waits for the card to report its position: a card
    /// below the fold has not been built, so it publishes nothing, and waiting on that mark is
    /// waiting forever for exactly the results worth searching for. `scrollTo` reaches a lazily
    /// built child by identity, which is what `.settingsSection(_:)` gives it.
    private func jumpToPendingSection(_ proxy: ScrollViewProxy) {
        guard let pending = viewModel.pendingSettingsSectionID else { return }
        guard sections.contains(where: { $0.id == pending }) else {
            // The destination changed but its page has not been swapped in yet; the new page's
            // `onAppear` picks the jump up.
            return
        }
        viewModel.pendingSettingsSectionID = nil
        activeSectionID = pending
        withAnimation(.easeOut(duration: 0.24)) { proxy.scrollTo(pending, anchor: .top) }
    }

    /// Two columns only when the page is genuinely wide for the reader's interface scale, and never
    /// under a gamepad: focus order is a single list sorted by vertical position, so a second column
    /// would interleave with the first and up/down would jump between them.
    private var usesTwoColumns: Bool {
        // Same signal the rail uses. Keying this off pad focus alone meant a controller-mode page
        // opened in two columns and reflowed to one on the reader's first press.
        guard !controllerModeEnabled, !isPadFocusActive else { return false }
        return SettingsLayoutMetrics.allowsTwoColumns(cardWidth: contentWidth, uiScale: uiScale)
    }

    /// At the window floor the 250pt label column leaves an option row's chips too little room and
    /// they wrap into three lines, so the control moves under its label instead. `SettingsColumns`
    /// raises this again for its own cards, which are half a page wide whatever the window is.
    private var usesNarrowRows: Bool {
        SettingsLayoutMetrics.usesNarrowRows(cardWidth: contentWidth, uiScale: uiScale)
    }

    /// The section the reader is in: the last one whose top has passed the top of the viewport,
    /// falling back to the first while the page is still at rest.
    static func activeSection(marks: [SettingsSectionMark], sections: [SettingsSection]) -> String? {
        guard !sections.isEmpty else { return nil }
        let order = sections.map(\.id)
        let passed = marks
            .filter { order.contains($0.id) && $0.minY <= 1 }
            .max { lhs, rhs in lhs.minY < rhs.minY }
        return passed?.id ?? marks.filter { order.contains($0.id) }.min { $0.minY < $1.minY }?.id
    }

    private var sections: [SettingsSection] {
        switch viewModel.selectedSettingsGroup {
        case .account: AccountSettingsGroup.sections
        case .video: VideoSettingsGroup.sections
        case .audio: AudioSettingsPage.sections
        case .input: InputSettingsGroup.sections
        case .recording: RecordingSettingsGroup.sections
        case .network: NetworkSettingsGroup.sections
        case .remoteCoOp: []
        case .general: GeneralSettingsGroup.sections
        case .labs: LabsSettingsPage.sections
        }
    }

    @ViewBuilder private var page: some View {
        switch viewModel.selectedSettingsGroup {
        case .account:
            AccountSettingsGroup(viewModel: viewModel)
        case .video:
            VideoSettingsGroup(viewModel: viewModel)
        case .audio:
            AudioSettingsPage(viewModel: viewModel, uiScale: uiScale)
        case .input:
            InputSettingsGroup(viewModel: viewModel)
        case .recording:
            RecordingSettingsGroup(viewModel: viewModel)
        case .network:
            NetworkSettingsGroup(viewModel: viewModel)
        case .remoteCoOp:
            RemoteCoOpSettingsPage(viewModel: viewModel, uiScale: uiScale)
        case .general:
            GeneralSettingsGroup(viewModel: viewModel)
        case .labs:
            LabsSettingsPage(uiScale: uiScale)
        }
    }
}

struct SettingsContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
