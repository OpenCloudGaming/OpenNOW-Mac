import AppKit
import CoreAudio
import Metal

private let settingsNavHeight: CGFloat = 64.0
private let settingsTopInset: CGFloat = 72.0
private let settingsColumnGap: CGFloat = 28.0

private enum SettingsColor {
    static let surfaceRaised: UInt32 = 0x1D1E22
    static let panelBorder: UInt32 = 0x3A3C42
    static let textMuted: UInt32 = 0x787A82
    static let inputBackground: UInt32 = 0x24262B
    static let errorRed: UInt32 = 0xFF453A
}

private enum InterfaceDefaults {
    static let notification = Notification.Name("OpenNOW.InterfacePreferencesDidChange")
    static let autoFullScreen = "OpenNOW.Interface.AutoFullScreen"
    static let appIconTheme = "OpenNOW.Interface.AppIconTheme"
    static let discordPresenceMode = "OpenNOW.Discord.PresenceMode"
    static let discordClientId = "OpenNOW.Discord.ClientId"
    static let sessionReportDisplayMode = "OpenNOW.SessionReport.DisplayMode"
}

private final class OPNSettingsFlippedViewSwift: NSView {
    override var isFlipped: Bool { true }
}

private func settingsDisplayName(_ section: String) -> String {
    section == "Stream" ? "Network" : section
}

private func eventShortcutModifierMask(from flags: NSEvent.ModifierFlags) -> Int {
    var mask = 0
    if flags.contains(.shift) { mask |= 0x01 }
    if flags.contains(.control) { mask |= 0x02 }
    if flags.contains(.option) { mask |= 0x04 }
    if flags.contains(.command) { mask |= 0x08 }
    if flags.contains(.capsLock) { mask |= 0x10 }
    return mask
}

private func shortcutModifierBit(for keyCode: UInt16) -> Int {
    switch keyCode {
    case 55: return 0x08
    case 56, 60: return 0x01
    case 57: return 0x10
    case 58, 61: return 0x04
    case 59, 62: return 0x02
    default: return 0
    }
}

private final class OPNPushToTalkShortcutFieldSwift: NSTextField {
    var shortcutKeyCode = 0
    var shortcutModifierMask = 0
    var onShortcutChanged: ((Int, Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = NSFont.systemFont(ofSize: 14.0, weight: .medium)
        textColor = opnColor(OPNViewColor.textPrimary)
        alignment = .left
        wantsLayer = true
        layer?.backgroundColor = opnColor(0x090A0C, 0.72).cgColor
        layer?.cornerRadius = 11.0
        layer?.borderWidth = 1.0
        layer?.borderColor = opnColor(SettingsColor.panelBorder, 0.78).cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        layer?.borderColor = opnColor(OPNViewColor.brandGreen, 0.70).cgColor
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        layer?.borderColor = opnColor(SettingsColor.panelBorder, 0.78).cgColor
        return result
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    func configure(keyCode: Int, modifierMask: Int) {
        shortcutKeyCode = max(0, min(keyCode, 127))
        shortcutModifierMask = modifierMask & 0x1F
        stringValue = OPNStreamPreferences.microphonePushToTalkComboLabel(keyCode: shortcutKeyCode, modifierMask: shortcutModifierMask)
    }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        captureShortcut(from: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard event.keyCode <= 127 else { return }
        let modifierBit = shortcutModifierBit(for: event.keyCode)
        guard modifierBit != 0, eventShortcutModifierMask(from: event.modifierFlags) & modifierBit != 0 else { return }
        captureShortcut(from: event)
    }

    private func captureShortcut(from event: NSEvent) {
        guard event.keyCode <= 127 else { return }
        let keyCode = Int(event.keyCode)
        let modifierMask = eventShortcutModifierMask(from: event.modifierFlags)
        configure(keyCode: keyCode, modifierMask: modifierMask)
        onShortcutChanged?(keyCode, modifierMask)
    }
}

private func settingsAudioDevicesChanged(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let view = Unmanaged<OPNSettingsView>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async { view.audioDevicesChanged() }
    return noErr
}

@objc(OPNSettingsView)
final class OPNSettingsView: NSView {
    @objc var onBackRequested: (() -> Void)?
    @objc var onCheckForUpdatesRequested: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let shellView = OPNSettingsFlippedViewSwift()
    private let sidebarView = OPNSettingsFlippedViewSwift()
    private let sidebarTitleLabel = NSTextField(labelWithString: "SETTINGS")
    private let scrollView = NSScrollView()
    private let documentView = OPNSettingsFlippedViewSwift()
    private var sidebarButtons: [NSButton] = []
    private let sectionNames = ["Stream", "Video", "Audio", "Input", "Interface", "About", "Thanks"]
    private var selectedSection = 0
    private var contentAreaWidth: CGFloat = 720.0
    private var layoutRebuildTimer: Timer?
    private var audioDeviceListenerInstalled = false

    @objc override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        initialize(selectedSectionName: nil)
    }

    @objc(initWithFrame:selectedSectionName:)
    init(frame frameRect: NSRect, selectedSectionName: String?) {
        super.init(frame: frameRect)
        initialize(selectedSectionName: selectedSectionName)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        initialize(selectedSectionName: nil)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            layoutRebuildTimer?.invalidate()
            layoutRebuildTimer = nil
            stopAudioDeviceMonitoring()
            NotificationCenter.default.removeObserver(self)
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let outerMargin: CGFloat = width < 900.0 ? 24.0 : 64.0
        let contentWidth = min(1560.0, max(360.0, width - outerMargin * 2.0))
        let x = floor((width - contentWidth) / 2.0)
        let y = settingsNavHeight + settingsTopInset
        let shellHeight = max(360.0, bounds.height - y - 34.0)

        titleLabel.frame = NSRect(x: x, y: y - 48.0, width: 240.0, height: 34.0)
        shellView.frame = NSRect(x: x, y: y, width: contentWidth, height: shellHeight)
        let sidebarWidth = width < 900.0 ? 210.0 : min(300.0, max(240.0, contentWidth * 0.26))
        let columnGap = width < 900.0 ? 16.0 : settingsColumnGap
        sidebarView.frame = NSRect(x: 0.0, y: 0.0, width: sidebarWidth, height: shellHeight)
        sidebarTitleLabel.frame = NSRect(x: 24.0, y: 24.0, width: max(120.0, sidebarWidth - 48.0), height: 18.0)

        var buttonY: CGFloat = 62.0
        for button in sidebarButtons {
            button.frame = NSRect(x: 18.0, y: buttonY, width: max(160.0, sidebarWidth - 36.0), height: 46.0)
            buttonY += 54.0
        }

        let scrollX = sidebarWidth + columnGap
        let scrollWidth = max(260.0, contentWidth - scrollX - 28.0)
        scrollView.frame = NSRect(x: scrollX, y: 22.0, width: scrollWidth, height: shellHeight - 44.0)
        if abs(contentAreaWidth - scrollWidth) > 1.0 {
            contentAreaWidth = scrollWidth
            scheduleLayoutRebuildContent()
        }
        documentView.frame = NSRect(x: 0.0, y: 0.0, width: scrollView.frame.width, height: max(scrollView.frame.height, documentView.frame.height))
        layoutContentSubviews()
    }

    @objc func moveGamepadSelection(by delta: NSInteger) {
        guard delta != 0 else { return }
        let next = min(max(0, selectedSection + Int(delta)), sectionNames.count - 1)
        guard next != selectedSection else { return }
        selectedSection = next
        restyleSidebarButtons()
        rebuildContent()
        scrollContentToTop()
    }

    @objc func activateGamepadSelection() {
        restyleSidebarButtons()
    }

    fileprivate func audioDevicesChanged() {
        if sectionNames[selectedSection] == "Audio" { rebuildContent() }
    }

    private func initialize(selectedSectionName: String?) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        if let selectedSectionName, let index = sectionNames.firstIndex(of: selectedSectionName) {
            selectedSection = index
        }

        configureTitle()
        configureShell()
        buildSidebarButtons()
        configureScrollView()
        NotificationCenter.default.addObserver(self, selector: #selector(streamRegionsUpdated(_:)), name: Notification.Name("OpenNOW.StreamRegionsUpdated"), object: nil)
        startAudioDeviceMonitoring()
        rebuildContent()
    }

    private func configureTitle() {
        titleLabel.isHidden = true
        titleLabel.font = NSFont.systemFont(ofSize: 28.0, weight: .semibold)
        titleLabel.textColor = opnColor(OPNViewColor.textPrimary)
        addSubview(titleLabel)
    }

    private func configureShell() {
        shellView.wantsLayer = true
        shellView.layer?.backgroundColor = opnColor(0x0F1013, 0.58).cgColor
        shellView.layer?.cornerRadius = 18.0
        shellView.layer?.borderWidth = 1.0
        shellView.layer?.borderColor = opnColor(0xFFFFFF, 0.08).cgColor
        addSubview(shellView)

        sidebarView.wantsLayer = true
        sidebarView.layer?.backgroundColor = opnColor(0x08090B, 0.62).cgColor
        shellView.addSubview(sidebarView)

        sidebarTitleLabel.font = NSFont.systemFont(ofSize: 13.0, weight: .semibold)
        sidebarTitleLabel.textColor = opnColor(SettingsColor.textMuted)
        sidebarView.addSubview(sidebarTitleLabel)
    }

    private func configureScrollView() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        documentView.wantsLayer = true
        scrollView.documentView = documentView
        shellView.addSubview(scrollView)
    }

    private func buildSidebarButtons() {
        for index in sectionNames.indices {
            let button = NSButton(frame: .zero)
            button.tag = index
            button.isBordered = false
            button.target = self
            button.action = #selector(sectionClicked(_:))
            button.wantsLayer = true
            sidebarButtons.append(button)
            sidebarView.addSubview(button)
        }
        restyleSidebarButtons()
    }

    private func restyleSidebarButtons() {
        for button in sidebarButtons {
            let selected = button.tag == selectedSection
            let section = sectionNames[button.tag]
            button.title = "  \(String(format: "%02d", button.tag + 1))  \(settingsDisplayName(section))"
            button.font = NSFont.systemFont(ofSize: 14.0, weight: selected ? .semibold : .regular)
            button.alignment = .left
            button.contentTintColor = selected ? opnColor(OPNViewColor.textPrimary) : opnColor(OPNViewColor.textSecondary)
            button.layer?.cornerRadius = 10.0
            button.layer?.borderWidth = selected ? 1.0 : 0.0
            button.layer?.borderColor = opnColor(OPNViewColor.brandGreen, selected ? 0.44 : 0.0).cgColor
            button.layer?.backgroundColor = selected ? opnColor(OPNViewColor.brandGreen, 0.14).cgColor : NSColor.clear.cgColor
        }
    }

    @objc private func sectionClicked(_ sender: NSButton) {
        selectedSection = sender.tag
        restyleSidebarButtons()
        rebuildContent()
        scrollContentToTop()
    }

    private func rebuildContent() {
        documentView.subviews.forEach { $0.removeFromSuperview() }
        let section = sectionNames[selectedSection]
        titleLabel.stringValue = ""
        documentView.addSubview(sectionHeader(for: section))
        switch section {
        case "Stream": buildStreamContent()
        case "Video": buildVideoContent()
        case "Audio": buildAudioContent()
        case "Input": buildInputContent()
        case "Interface": buildInterfaceContent()
        case "About": buildAboutContent()
        default: buildSimpleSectionContent(section)
        }
        needsLayout = true
    }

    private func sectionHeader(for section: String) -> NSView {
        let width = max(320.0, contentAreaWidth)
        let header = OPNSettingsFlippedViewSwift(frame: NSRect(x: 0.0, y: 0.0, width: width, height: 132.0))
        header.wantsLayer = true
        header.layer?.backgroundColor = opnColor(0x121418, 0.82).cgColor
        header.layer?.cornerRadius = 20.0
        header.layer?.borderWidth = 1.0
        header.layer?.borderColor = opnColor(0xFFFFFF, 0.09).cgColor
        let accent = accentColor(for: section)
        let accentBar = NSView(frame: NSRect(x: 0.0, y: 0.0, width: 5.0, height: 132.0))
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = accent.cgColor
        accentBar.layer?.cornerRadius = 2.5
        header.addSubview(accentBar)
        let displayName = settingsDisplayName(section)
        let eyebrow = opnLabel("\(displayName) Settings".uppercased(), NSRect(x: 28.0, y: 24.0, width: width - 56.0, height: 18.0), 12.0, accent, .semibold)
        header.addSubview(eyebrow)
        header.addSubview(opnLabel(displayName, NSRect(x: 28.0, y: 46.0, width: width - 56.0, height: 34.0), 26.0, opnColor(OPNViewColor.textPrimary), .semibold))
        let subtitle = opnLabel(subtitle(for: section), NSRect(x: 28.0, y: 84.0, width: max(260.0, width - 56.0), height: 34.0), 13.0, opnColor(OPNViewColor.textSecondary))
        subtitle.maximumNumberOfLines = 2
        header.addSubview(subtitle)
        return header
    }

    private func subtitle(for section: String) -> String {
        switch section {
        case "Stream": return "Choose the route and latency behavior OpenNOW uses when starting new cloud gaming sessions."
        case "Video": return "Tune stream quality, recording output, HDR, codecs, and local enhancement for this Mac."
        case "Audio": return "Control microphone mode, input device, push-to-talk, and in-stream mute behavior."
        case "Input": return "Decide how keyboard, mouse, and controller input behaves when the app loses focus."
        case "Interface": return "Customize app presentation, stream window behavior, Discord presence, and session reports."
        case "About": return "Review build details, runtime capability checks, updates, and local cache controls."
        default: return "Acknowledgements for the open-source work that helps make OpenNOW possible."
        }
    }

    private func accentColor(for section: String) -> NSColor {
        switch section {
        case "Video": return opnColor(0x64D2FF)
        case "Audio": return opnColor(0xBF5AF2)
        case "Input": return opnColor(0xFF9F0A)
        case "Interface": return opnColor(0x5E5CE6)
        case "About": return opnColor(0x0A84FF)
        case "Thanks": return opnColor(0xFF375F)
        default: return opnColor(OPNViewColor.brandGreen)
        }
    }

    private func panel(title: String, height: CGFloat) -> NSView {
        let width = max(320.0, contentAreaWidth)
        let panel = OPNSettingsFlippedViewSwift(frame: NSRect(x: 0.0, y: 0.0, width: width, height: height))
        panel.wantsLayer = true
        panel.layer?.backgroundColor = opnColor(SettingsColor.surfaceRaised, 0.66).cgColor
        panel.layer?.cornerRadius = 18.0
        panel.layer?.borderWidth = 1.0
        panel.layer?.borderColor = opnColor(0xFFFFFF, 0.08).cgColor
        panel.addSubview(opnLabel(title, NSRect(x: 24.0, y: 26.0, width: 300.0, height: 28.0), 19.0, opnColor(OPNViewColor.textPrimary), .semibold))
        let divider = NSView(frame: NSRect(x: 24.0, y: 72.0, width: max(120.0, width - 48.0), height: 1.0))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = opnColor(0xFFFFFF, 0.08).cgColor
        panel.addSubview(divider)
        return panel
    }

    private func buildStreamContent() {
        let profile = OPNStreamPreferences.loadProfile()
        let panelWidth = max(320.0, contentAreaWidth)
        let controlX = controlX(for: panelWidth)
        let controlWidth = controlWidth(for: panelWidth)
        let region = panel(title: "Region", height: 180.0)
        region.addSubview(rowLabel("Server", y: 108.0))
        region.addSubview(regionPopup(frame: NSRect(x: controlX, y: 96.0, width: controlWidth, height: 42.0)))
        let hint = opnLabel("Automatic uses the lowest measured region when available. Pick a region to override it.", NSRect(x: controlX, y: 144.0, width: controlWidth, height: 24.0), 12.0, opnColor(SettingsColor.textMuted))
        hint.lineBreakMode = .byTruncatingTail
        region.addSubview(hint)
        documentView.addSubview(region)

        let network = panel(title: "Network", height: 348.0)
        let selectedProfile = selectedPerformanceProfile(profile)
        network.addSubview(rowLabel("Profile", y: 108.0))
        addOptionGroup(to: network, group: 9, titles: ["Low Latency", "Quality", "Custom"], selected: selectedProfile, y: 98.0, widths: [126.0, 92.0, 92.0])
        let profileHintText = selectedProfile == 2 ? "Custom keeps your manual codec, FPS, and bitrate choices. Use a preset to quickly return to a known profile." : "Presets adjust codec, FPS, bitrate, and disable experimental L4S for new sessions. Manual controls can still override them."
        let profileHint = opnLabel(profileHintText, NSRect(x: controlX, y: 144.0, width: controlWidth, height: 36.0), 12.0, opnColor(SettingsColor.textMuted))
        profileHint.maximumNumberOfLines = 2
        network.addSubview(profileHint)
        network.addSubview(rowLabel("Low Latency", y: 204.0))
        network.addSubview(toggle(title: "Enable Low Latency Mode for new streams", frame: NSRect(x: controlX, y: 196.0, width: controlWidth, height: 28.0), isOn: profile.lowLatencyMode, action: #selector(lowLatencyModeToggleChanged(_:))))
        let lowLatencyHint = opnLabel("Reduces startup/input/render latency by preferring cached route data, disabling local enhancement, and minimizing frame buffering.", NSRect(x: controlX, y: 232.0, width: controlWidth, height: 34.0), 12.0, opnColor(SettingsColor.textMuted))
        lowLatencyHint.maximumNumberOfLines = 2
        network.addSubview(lowLatencyHint)
        network.addSubview(rowLabel("L4S Mode", y: 292.0))
        network.addSubview(toggle(title: "Enable experimental L4S requests", frame: NSRect(x: controlX, y: 284.0, width: controlWidth, height: 28.0), isOn: profile.enableL4S, action: #selector(l4sToggleChanged(_:))))
        documentView.addSubview(network)
        buildWebRTCDiagnostics()
    }

    private func buildVideoContent() {
        let profile = OPNStreamPreferences.loadProfile()
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        let effective = OPNStreamPreferences.effectiveProfile(profile, capabilities: capabilities)
        let panelWidth = max(320.0, contentAreaWidth)
        let controlX = controlX(for: panelWidth)
        let controlWidth = controlWidth(for: panelWidth)
        let video = panel(title: "Video", height: 1270.0)
        video.addSubview(rowLabel("Aspect Ratio", y: 112.0))
        addOptionGroup(to: video, group: 1, titles: OPNStreamPreferences.aspectOptions.map(\.label), selected: profile.aspectIndex, y: 102.0, widths: [86.0, 92.0, 86.0, 86.0])
        video.addSubview(rowLabel("Resolution", y: 188.0))
        video.addSubview(resolutionPopup(frame: NSRect(x: controlX, y: 176.0, width: controlWidth, height: 42.0)))
        video.addSubview(rowLabel("FPS", y: 264.0))
        addOptionGroup(to: video, group: 3, titles: OPNStreamPreferences.fpsOptions.map(String.init), selected: profile.fpsIndex, y: 254.0, widths: [62.0, 62.0, 62.0, 62.0], enabled: OPNStreamPreferences.fpsOptions.map { OPNStreamPreferences.fpsSupported($0, capabilities: capabilities) })
        video.addSubview(rowLabel("Bitrate", y: 340.0))
        addOptionGroup(to: video, group: 8, titles: OPNStreamPreferences.bitrateOptions.map(\.label), selected: profile.bitrateIndex, y: 330.0, widths: [86.0, 86.0, 86.0, 86.0, 94.0])
        video.addSubview(rowLabel("Recording Video", y: 416.0))
        video.addSubview(slider(frame: NSRect(x: controlX, y: 406.0, width: controlWidth, height: 24.0), min: 0.0, max: 200.0, value: Double(profile.recordingVideoBitrateMbps), action: #selector(recordingVideoBitrateSliderChanged(_:))))
        video.addSubview(opnLabel(profile.recordingVideoBitrateMbps <= 0 ? "Auto video bitrate (5-60 Mbps by capture resolution), or choose 5-200 Mbps" : "\(profile.recordingVideoBitrateMbps) Mbps recording video bitrate", NSRect(x: controlX, y: 438.0, width: controlWidth, height: 22.0), 12.0, opnColor(SettingsColor.textMuted)))
        video.addSubview(toggle(title: "Record enhanced output when local upscaling is active", frame: NSRect(x: controlX, y: 466.0, width: controlWidth, height: 28.0), isOn: profile.recordingEnhancedVideoEnabled, action: #selector(recordingEnhancedVideoToggleChanged(_:))))
        video.addSubview(rowLabel("Recording Audio", y: 548.0))
        video.addSubview(slider(frame: NSRect(x: controlX, y: 538.0, width: controlWidth, height: 24.0), min: 64.0, max: 320.0, value: Double(profile.recordingAudioBitrateKbps), action: #selector(recordingAudioBitrateSliderChanged(_:))))
        video.addSubview(opnLabel("\(profile.recordingAudioBitrateKbps) kbps recording audio bitrate", NSRect(x: controlX, y: 570.0, width: controlWidth, height: 22.0), 12.0, opnColor(SettingsColor.textMuted)))
        video.addSubview(rowLabel("Codec", y: 624.0))
        addOptionGroup(to: video, group: 4, titles: OPNStreamPreferences.codecOptions.map(\.label), selected: profile.codecIndex, y: 614.0, widths: [142.0, 116.0, 96.0, 70.0], enabled: OPNStreamPreferences.codecOptions.map { OPNStreamPreferences.codecSupported($0, capabilities: capabilities) })
        let colorCapabilityCodec = OPNStreamPreferences.codecSupported(profile.codec, capabilities: capabilities) ? profile.codec : effective.codec
        video.addSubview(rowLabel("Color Depth", y: 700.0))
        addOptionGroup(to: video, group: 7, titles: OPNStreamPreferences.colorQualityOptions.map(\.label), selected: profile.colorQualityIndex, y: 690.0, widths: [112.0, 112.0, 124.0, 124.0], enabled: OPNStreamPreferences.colorQualityOptions.map { OPNStreamPreferences.colorQualitySupported($0, codec: colorCapabilityCodec, capabilities: capabilities) })
        let hdrToggle = toggle(title: capabilities.hdrDisplaySupported ? "Request HDR when available" : "Request HDR when available (display unsupported)", frame: NSRect(x: controlX, y: 756.0, width: controlWidth, height: 28.0), isOn: profile.enableHdr, action: #selector(hdrToggleChanged(_:)))
        hdrToggle.isEnabled = capabilities.hdrDisplaySupported
        video.addSubview(hdrToggle)
        let capabilitySummary = "Hardware decode: H264 \(capabilities.h264HardwareDecodeSupported ? "on" : "off") · H265 \(capabilities.h265HardwareDecodeSupported ? "on" : "off") · AV1 \(capabilities.av1HardwareDecodeSupported ? "on" : "off"). Display: \(capabilities.maxDisplayWidth)x\(capabilities.maxDisplayHeight)\(capabilities.hdrDisplaySupported ? " · HDR display" : "")."
        let capabilityLabel = opnLabel(capabilitySummary, NSRect(x: controlX, y: 802.0, width: controlWidth, height: 36.0), 12.0, opnColor(SettingsColor.textMuted))
        capabilityLabel.maximumNumberOfLines = 2
        video.addSubview(capabilityLabel)
        let willAdjust = profile.codec.value != effective.codec.value || profile.fps != effective.fps || profile.colorQuality.value != effective.colorQuality.value
        let adjustmentLabel = opnLabel(willAdjust ? "Saved profile will launch as \(effective.codec.label), \(effective.fps)fps, \(effective.colorQuality.label) on this Mac." : "Unsupported codec, color, and FPS options are disabled to match this Mac's playback capabilities.", NSRect(x: controlX, y: 848.0, width: controlWidth, height: 42.0), 12.0, willAdjust ? opnColor(0xFFD166) : opnColor(SettingsColor.textMuted))
        adjustmentLabel.maximumNumberOfLines = 2
        video.addSubview(adjustmentLabel)
        video.addSubview(rowLabel("Resolution Upscaling", y: 934.0))
        addOptionGroup(to: video, group: 12, titles: OPNStreamPreferences.upscalingModeOptions.map(\.label), selected: profile.upscalingModeIndex, y: 924.0, widths: [64.0, 70.0, 84.0, 84.0, 96.0])
        video.addSubview(opnLabel("Local Sharpness", NSRect(x: controlX, y: 974.0, width: 160.0, height: 18.0), 11.0, opnColor(SettingsColor.textMuted), .medium))
        video.addSubview(integerPopup(frame: NSRect(x: controlX, y: 994.0, width: min(120.0, controlWidth), height: 38.0), value: profile.upscalingSharpness, maxValue: 40, action: #selector(upscalingSharpnessPopupChanged(_:))))
        let denoiseX = controlX + min(160.0, controlWidth * 0.5)
        video.addSubview(opnLabel("Local Denoise", NSRect(x: denoiseX, y: 974.0, width: 160.0, height: 18.0), 11.0, opnColor(SettingsColor.textMuted), .medium))
        video.addSubview(integerPopup(frame: NSRect(x: denoiseX, y: 994.0, width: min(120.0, controlWidth), height: 38.0), value: profile.upscalingDenoise, maxValue: 20, action: #selector(upscalingDenoisePopupChanged(_:))))
        let upscalingHint = opnLabel("Auto chooses Temporal when available, then MetalFX, then Spatial. Explicit selections are forced; Temporal uses motion-guided frame history.", NSRect(x: controlX, y: 1042.0, width: controlWidth, height: 42.0), 12.0, opnColor(SettingsColor.textMuted))
        upscalingHint.maximumNumberOfLines = 2
        video.addSubview(upscalingHint)
        video.addSubview(rowLabel("AI Filter", y: 1104.0))
        addOptionGroup(to: video, group: 10, titles: OPNStreamPreferences.prefilterModeOptions.map(\.label), selected: profile.prefilterModeIndex, y: 1094.0, widths: [72.0, 72.0, 96.0])
        video.addSubview(rowLabel("Custom Levels", y: 1160.0))
        video.addSubview(opnLabel("Sharpness", NSRect(x: controlX, y: 1128.0, width: 120.0, height: 18.0), 11.0, opnColor(SettingsColor.textMuted), .medium))
        video.addSubview(integerPopup(frame: NSRect(x: controlX, y: 1148.0, width: min(120.0, controlWidth), height: 38.0), value: profile.prefilterSharpness, maxValue: 10, action: #selector(prefilterSharpnessPopupChanged(_:))))
        video.addSubview(opnLabel("Denoise", NSRect(x: denoiseX, y: 1128.0, width: 120.0, height: 18.0), 11.0, opnColor(SettingsColor.textMuted), .medium))
        video.addSubview(integerPopup(frame: NSRect(x: denoiseX, y: 1148.0, width: min(120.0, controlWidth), height: 38.0), value: profile.prefilterDenoise, maxValue: 10, action: #selector(prefilterDenoisePopupChanged(_:))))
        documentView.addSubview(video)
    }

    private func buildWebRTCDiagnostics() {
        let panel = panel(title: "WebRTC Backend", height: 354.0)
        let panelWidth = max(320.0, panel.frame.width)
        let controlWidth = controlWidth(for: panelWidth)
        let description = opnLabel("OpenNOW streams through libwebrtc only. New sessions fail fast if the libwebrtc framework is unavailable in this build.", NSRect(x: 24.0, y: 92.0, width: max(260.0, panelWidth - 48.0), height: 38.0), 12.0, opnColor(SettingsColor.textMuted))
        description.maximumNumberOfLines = 2
        panel.addSubview(description)
        addInfoRow(to: panel, title: "Status", value: "Using libwebrtc", y: 146.0, valueWidth: controlWidth)
        addInfoRow(to: panel, title: "Active", value: "libwebrtc", y: 198.0, valueWidth: controlWidth)
        addInfoRow(to: panel, title: "Codec", value: OPNStreamPreferences.loadProfile().codec.label, y: 250.0, valueWidth: controlWidth)
        addInfoRow(to: panel, title: "libwebrtc", value: "Checked when a stream starts", y: 302.0, valueWidth: controlWidth)
        documentView.addSubview(panel)
    }

    private func buildAudioContent() {
        let profile = OPNStreamPreferences.loadProfile()
        let microphoneEnabled = profile.microphoneMode != "disabled"
        let shortcutY: CGFloat = microphoneEnabled ? 304.0 : 204.0
        let panel = panel(title: "Audio", height: microphoneEnabled ? 506.0 : 420.0)
        let panelWidth = max(320.0, panel.frame.width)
        let controlX = controlX(for: panelWidth)
        let controlWidth = controlWidth(for: panelWidth)
        panel.addSubview(rowLabel("Microphone", y: 104.0))
        panel.addSubview(microphoneModePopup(frame: NSRect(x: controlX, y: 96.0, width: controlWidth, height: 38.0), profile: profile))
        let modeHint = opnLabel("Open Mic is always live. Push-to-Talk only sends audio while the configured shortcut is held.", NSRect(x: controlX, y: 140.0, width: controlWidth, height: 38.0), 12.0, opnColor(SettingsColor.textMuted))
        modeHint.maximumNumberOfLines = 2
        panel.addSubview(modeHint)
        if microphoneEnabled {
            panel.addSubview(rowLabel("Input Device", y: 204.0))
            panel.addSubview(microphoneDevicePopup(frame: NSRect(x: controlX, y: 196.0, width: controlWidth, height: 38.0), profile: profile))
            let deviceHint = opnLabel("macOS may ask for microphone permission the first time a stream starts with mic enabled.", NSRect(x: controlX, y: 240.0, width: controlWidth, height: 38.0), 12.0, opnColor(SettingsColor.textMuted))
            deviceHint.maximumNumberOfLines = 2
            panel.addSubview(deviceHint)
        }
        panel.addSubview(rowLabel("Push-to-Talk", y: shortcutY + 8.0))
        let shortcutField = OPNPushToTalkShortcutFieldSwift(frame: NSRect(x: controlX, y: shortcutY, width: controlWidth, height: 38.0))
        shortcutField.configure(keyCode: profile.microphonePushToTalkKeyCode, modifierMask: profile.microphonePushToTalkModifierMask)
        shortcutField.onShortcutChanged = { keyCode, modifierMask in
            OPNStreamPreferences.saveMicrophonePushToTalkKeyCode(keyCode)
            OPNStreamPreferences.saveMicrophonePushToTalkModifierMask(modifierMask)
        }
        panel.addSubview(shortcutField)
        let hint = opnLabel("Click the box, hold any modifiers, then press the final key. Used when Microphone is Push-to-Talk and not sent to the game while streaming.", NSRect(x: controlX, y: shortcutY + 52.0, width: controlWidth, height: 54.0), 12.0, opnColor(SettingsColor.textMuted))
        hint.maximumNumberOfLines = 3
        panel.addSubview(hint)
        let toggleY = shortcutY + 124.0
        panel.addSubview(rowLabel("Mic Toggle", y: toggleY + 8.0))
        let toggleShortcut = opnLabel("Command-M", NSRect(x: controlX, y: toggleY, width: min(180.0, controlWidth), height: 32.0), 13.0, opnColor(OPNViewColor.textPrimary), .semibold, .center)
        toggleShortcut.wantsLayer = true
        toggleShortcut.layer?.cornerRadius = 10.0
        toggleShortcut.layer?.borderWidth = 1.0
        toggleShortcut.layer?.borderColor = opnColor(SettingsColor.panelBorder, 0.78).cgColor
        toggleShortcut.layer?.backgroundColor = opnColor(SettingsColor.inputBackground, 0.72).cgColor
        panel.addSubview(toggleShortcut)
        documentView.addSubview(panel)
    }

    private func buildInputContent() {
        let profile = OPNStreamPreferences.loadProfile()
        let panel = panel(title: "Input", height: 252.0)
        let panelWidth = max(320.0, panel.frame.width)
        let controlX = controlX(for: panelWidth)
        let controlWidth = controlWidth(for: panelWidth)
        panel.addSubview(rowLabel("Window Focus", y: 104.0))
        panel.addSubview(toggle(title: "Block game input when OpenNOW is inactive", frame: NSRect(x: controlX, y: 96.0, width: controlWidth, height: 28.0), isOn: profile.suppressInputWhenInactive, action: #selector(suppressInputWhenInactiveToggleChanged(_:))))
        let hint = opnLabel("When enabled, keyboard, mouse, push-to-talk, and gamepad events are ignored unless the stream window is active.", NSRect(x: controlX, y: 136.0, width: controlWidth, height: 54.0), 12.0, opnColor(SettingsColor.textMuted))
        hint.maximumNumberOfLines = 3
        panel.addSubview(hint)
        documentView.addSubview(panel)
    }

    private func buildInterfaceContent() {
        let profile = OPNStreamPreferences.loadProfile()
        let panel = panel(title: "Interface", height: 672.0)
        let panelWidth = max(320.0, panel.frame.width)
        let controlX = controlX(for: panelWidth)
        let controlWidth = controlWidth(for: panelWidth)
        panel.addSubview(rowLabel("App Icon", y: 104.0))
        addOptionGroup(to: panel, group: 11, titles: ["Black", "GFN Green", "Sky Blue"], selected: selectedAppIconIndex(), y: 96.0, widths: [82.0, 112.0, 94.0])
        panel.addSubview(opnLabel("Changes the Dock icon and OpenNOW logo immediately. Black is the default app icon.", NSRect(x: controlX, y: 146.0, width: controlWidth, height: 36.0), 12.0, opnColor(SettingsColor.textMuted)))
        panel.addSubview(rowLabel("Direct Mouse Input", y: 216.0))
        panel.addSubview(toggle(title: "Use raw relative mouse movement while streaming", frame: NSRect(x: controlX, y: 208.0, width: controlWidth, height: 28.0), isOn: profile.directMouseInput, action: #selector(directMouseInputToggleChanged(_:))))
        let directMouseHint = opnLabel("Bypasses desktop cursor position and acceleration by locking the pointer and sending hardware-relative deltas to the stream.", NSRect(x: controlX, y: 244.0, width: controlWidth, height: 50.0), 12.0, opnColor(SettingsColor.textMuted))
        directMouseHint.maximumNumberOfLines = 3
        panel.addSubview(directMouseHint)
        panel.addSubview(rowLabel("Auto Full Screen", y: 334.0))
        panel.addSubview(toggle(title: "Enter full screen automatically when a stream starts", frame: NSRect(x: controlX, y: 326.0, width: controlWidth, height: 28.0), isOn: UserDefaults.standard.bool(forKey: InterfaceDefaults.autoFullScreen), action: #selector(autoFullScreenToggleChanged(_:))))
        panel.addSubview(rowLabel("Discord Presence", y: 410.0))
        addOptionGroup(to: panel, group: 13, titles: ["Off", "Status Only", "Full Details"], selected: discordPresenceMode(), y: 402.0, widths: [64.0, 118.0, 112.0])
        let clientHint = discordClientId().isEmpty ? "Requires OPN_DISCORD_CLIENT_ID or OPNDiscordClientID in the app bundle before Discord can show activity. Status Only hides game titles." : "Updates Discord while browsing, launching, and streaming. Status Only hides game titles; Full Details includes title and stream quality."
        let discordHint = opnLabel(clientHint, NSRect(x: controlX, y: 452.0, width: controlWidth, height: 54.0), 12.0, opnColor(SettingsColor.textMuted))
        discordHint.maximumNumberOfLines = 3
        panel.addSubview(discordHint)
        panel.addSubview(rowLabel("Session Reports", y: 542.0))
        addOptionGroup(to: panel, group: 14, titles: ["Automatic", "Always", "Important Only", "Off"], selected: sessionReportDisplayMode(), y: 534.0, widths: [104.0, 78.0, 128.0, 64.0])
        let sessionHint = opnLabel("Automatic shows reports only for failures, recovery, network warnings, guardrails, or poor stream quality. Important Only ignores soft quality-only signals.", NSRect(x: controlX, y: 584.0, width: controlWidth, height: 54.0), 12.0, opnColor(SettingsColor.textMuted))
        sessionHint.maximumNumberOfLines = 3
        panel.addSubview(sessionHint)
        documentView.addSubview(panel)
    }

    private func buildAboutContent() {
        let panel = panel(title: "About", height: 596.0)
        let panelWidth = max(320.0, panel.frame.width)
        let controlX = controlX(for: panelWidth)
        let controlWidth = controlWidth(for: panelWidth)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "Unavailable"
        let enhancements = localEnhancementRuntimeInfo()
        let summary = opnLabel("OpenNOW is an open-source macOS client for launching and streaming cloud games.", NSRect(x: 24.0, y: 92.0, width: max(260.0, panelWidth - 48.0), height: 38.0), 13.0, opnColor(OPNViewColor.textSecondary))
        summary.maximumNumberOfLines = 2
        panel.addSubview(summary)
        addInfoRow(to: panel, title: "Version", value: "\(version) (\(build))", y: 154.0, valueWidth: controlWidth)
        addInfoRow(to: panel, title: "Bundle ID", value: bundleIdentifier, y: 206.0, valueWidth: controlWidth, monospace: true)
        addInfoRow(to: panel, title: "System GPU", value: enhancements.gpu, y: 258.0, valueWidth: controlWidth)
        panel.addSubview(rowLabel("Compatible Enhancements", y: 318.0))
        let enhancementLabel = opnLabel(enhancements.summary, NSRect(x: controlX, y: 316.0, width: controlWidth, height: 94.0), 12.0, opnColor(OPNViewColor.textSecondary))
        enhancementLabel.maximumNumberOfLines = 4
        panel.addSubview(enhancementLabel)
        let updateButton = opnButton("Check for Updates", NSRect(x: controlX, y: 434.0, width: min(210.0, controlWidth), height: 40.0), opnColor(OPNViewColor.brandGreen, 0.18), opnColor(OPNViewColor.brandGreen))
        updateButton.target = self
        updateButton.action = #selector(checkForUpdatesClicked(_:))
        panel.addSubview(updateButton)
        addInfoRow(to: panel, title: "Cache", value: "Catalog data, downloaded artwork, image memory cache, and URL cache", y: 492.0, valueWidth: controlWidth)
        let clearButton = opnButton("Clear All Caches", NSRect(x: controlX, y: 532.0, width: min(210.0, controlWidth), height: 40.0), opnColor(SettingsColor.errorRed, 0.14), opnColor(SettingsColor.errorRed))
        clearButton.target = self
        clearButton.action = #selector(clearCachesClicked(_:))
        panel.addSubview(clearButton)
        documentView.addSubview(panel)
    }

    private func buildSimpleSectionContent(_ section: String) {
        let panel = panel(title: section, height: 220.0)
        let message = section == "Thanks" ? "Thanks to the open-source projects and contributors that make this client possible." : "Settings are managed automatically for this section."
        let label = opnLabel(message, NSRect(x: 24.0, y: 104.0, width: 560.0, height: 44.0), 14.0, opnColor(OPNViewColor.textSecondary))
        label.maximumNumberOfLines = 2
        panel.addSubview(label)
        documentView.addSubview(panel)
    }

    private func addInfoRow(to panel: NSView, title: String, value: String, y: CGFloat, valueWidth: CGFloat, monospace: Bool = false) {
        panel.addSubview(rowLabel(title, y: y))
        let valueLabel = opnLabel(value.isEmpty ? "Unavailable" : value, NSRect(x: controlX(for: panel.frame.width), y: y - 2.0, width: valueWidth, height: 44.0), 12.0, opnColor(OPNViewColor.textSecondary))
        valueLabel.maximumNumberOfLines = 2
        valueLabel.lineBreakMode = .byTruncatingMiddle
        if monospace { valueLabel.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular) }
        panel.addSubview(valueLabel)
    }

    private func rowLabel(_ text: String, y: CGFloat) -> NSTextField {
        opnLabel(text, NSRect(x: 24.0, y: y, width: 160.0, height: 24.0), 14.0, opnColor(OPNViewColor.textSecondary), .medium)
    }

    private func controlX(for panelWidth: CGFloat) -> CGFloat { panelWidth < 620.0 ? 150.0 : 220.0 }
    private func controlWidth(for panelWidth: CGFloat) -> CGFloat { max(120.0, panelWidth - controlX(for: panelWidth) - 24.0) }

    private func popup(frame: NSRect, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: frame, pullsDown: false)
        popup.target = self
        popup.action = action
        popup.isBordered = false
        popup.font = NSFont.systemFont(ofSize: 14.0)
        popup.contentTintColor = opnColor(OPNViewColor.textPrimary)
        popup.wantsLayer = true
        popup.layer?.backgroundColor = opnColor(0x090A0C, 0.72).cgColor
        popup.layer?.cornerRadius = 11.0
        popup.layer?.borderWidth = 1.0
        popup.layer?.borderColor = opnColor(SettingsColor.panelBorder, 0.78).cgColor
        return popup
    }

    private func resolutionPopup(frame: NSRect) -> NSPopUpButton {
        let profile = OPNStreamPreferences.loadProfile()
        let resolutions = OPNStreamPreferences.resolutionOptions(forAspect: profile.aspectIndex)
        let popup = popup(frame: frame, action: #selector(resolutionPopupChanged(_:)))
        resolutions.forEach { popup.addItem(withTitle: $0.label) }
        if !resolutions.isEmpty { popup.selectItem(at: min(max(profile.resolutionIndex, 0), resolutions.count - 1)) }
        return popup
    }

    private func regionPopup(frame: NSRect) -> NSPopUpButton {
        let regions = OPNStreamPreferences.loadCachedRegions()
        let selectedUrl = OPNStreamPreferences.loadSelectedRegionUrl()
        let popup = popup(frame: frame, action: #selector(regionPopupChanged(_:)))
        popup.addItem(withTitle: "Automatic (lowest latency)")
        var selectedIndex = 0
        for (index, region) in regions.enumerated() {
            popup.addItem(withTitle: region.label)
            if !selectedUrl.isEmpty && region.url == selectedUrl { selectedIndex = index + 1 }
        }
        if regions.isEmpty {
            popup.addItem(withTitle: "Discovering regions...")
            popup.item(at: 1)?.isEnabled = false
        }
        popup.selectItem(at: selectedIndex)
        return popup
    }

    private func integerPopup(frame: NSRect, value: Int, maxValue: Int, action: Selector) -> NSPopUpButton {
        let popup = popup(frame: frame, action: action)
        for index in 0...max(0, maxValue) { popup.addItem(withTitle: "\(index)") }
        popup.selectItem(at: min(max(value, 0), max(0, maxValue)))
        return popup
    }

    private func microphoneModePopup(frame: NSRect, profile: OPNStreamPreferenceProfile) -> NSPopUpButton {
        let popup = popup(frame: frame, action: #selector(microphoneModePopupChanged(_:)))
        let modes = OPNStreamPreferences.microphoneModeOptions
        modes.forEach { popup.addItem(withTitle: $0.label) }
        popup.selectItem(at: modes.firstIndex { $0.value == profile.microphoneMode } ?? 0)
        return popup
    }

    private func microphoneDevicePopup(frame: NSRect, profile: OPNStreamPreferenceProfile) -> NSPopUpButton {
        let popup = popup(frame: frame, action: #selector(microphoneDevicePopupChanged(_:)))
        let devices = OPNStreamPreferences.loadMicrophoneDeviceOptions()
        devices.forEach { popup.addItem(withTitle: $0.label) }
        popup.selectItem(at: devices.firstIndex { $0.uniqueId == profile.microphoneDeviceId } ?? 0)
        return popup
    }

    private func toggle(title: String, frame: NSRect, isOn: Bool, action: Selector) -> NSButton {
        let button = NSButton(frame: frame)
        button.setButtonType(.switch)
        button.title = title
        button.font = NSFont.systemFont(ofSize: 13.0, weight: .medium)
        button.contentTintColor = opnColor(OPNViewColor.brandGreen)
        button.state = isOn ? .on : .off
        button.target = self
        button.action = action
        return button
    }

    private func slider(frame: NSRect, min: Double, max: Double, value: Double, action: Selector) -> NSSlider {
        let slider = NSSlider(frame: frame)
        slider.minValue = min
        slider.maxValue = max
        slider.doubleValue = value
        slider.numberOfTickMarks = 7
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = false
        slider.target = self
        slider.action = action
        return slider
    }

    private func addOptionGroup(to parent: NSView, group: Int, titles: [String], selected: Int, y: CGFloat, widths: [CGFloat], enabled: [Bool]? = nil) {
        let panelWidth = max(320.0, parent.frame.width)
        var x = controlX(for: panelWidth)
        let availableWidth = max(80.0, panelWidth - x - 24.0)
        let requestedWidth = widths.reduce(0.0, +) + CGFloat(max(0, titles.count - 1)) * 8.0
        let scale = requestedWidth > availableWidth ? availableWidth / requestedWidth : 1.0
        for index in titles.indices {
            let width = max(48.0, floor(widths[min(index, widths.count - 1)] * scale))
            let button = NSButton(frame: NSRect(x: x, y: y, width: width, height: 38.0))
            button.title = titles[index]
            button.tag = group * 100 + index
            button.target = self
            button.action = #selector(optionClicked(_:))
            button.isBordered = false
            button.wantsLayer = true
            let optionEnabled = enabled?[index] ?? true
            button.isEnabled = optionEnabled
            styleOptionButton(button, selected: index == selected, enabled: optionEnabled)
            parent.addSubview(button)
            x += width + 8.0
        }
    }

    private func styleOptionButton(_ button: NSButton, selected: Bool, enabled: Bool) {
        button.font = NSFont.systemFont(ofSize: 13.0, weight: selected ? .semibold : .regular)
        button.contentTintColor = enabled ? (selected ? opnColor(OPNViewColor.brandGreen) : opnColor(SettingsColor.textMuted)) : opnColor(SettingsColor.textMuted, 0.42)
        button.layer?.cornerRadius = 10.0
        button.layer?.borderWidth = 1.0
        button.layer?.borderColor = (enabled ? (selected ? opnColor(OPNViewColor.brandGreen, 0.50) : opnColor(SettingsColor.panelBorder, 0.72)) : opnColor(SettingsColor.panelBorder, 0.34)).cgColor
        button.layer?.backgroundColor = (enabled ? (selected ? opnColor(OPNViewColor.brandGreen, 0.16) : opnColor(SettingsColor.inputBackground, 0.58)) : opnColor(SettingsColor.inputBackground, 0.26)).cgColor
    }

    @objc private func optionClicked(_ sender: NSButton) {
        let group = sender.tag / 100
        let index = sender.tag % 100
        switch group {
        case 1: OPNStreamPreferences.saveAspectIndex(index)
        case 3: OPNStreamPreferences.saveFpsIndex(index)
        case 4: OPNStreamPreferences.saveCodecIndex(index)
        case 7: OPNStreamPreferences.saveColorQualityIndex(index)
        case 8: OPNStreamPreferences.saveBitrateIndex(index)
        case 9: applyPerformanceProfile(index)
        case 10: OPNStreamPreferences.savePrefilterModeIndex(index)
        case 11: setAppIconTheme(index)
        case 12: OPNStreamPreferences.saveUpscalingModeIndex(index)
        case 13: saveDiscordPresenceMode(index)
        case 14: saveSessionReportDisplayMode(index)
        default: break
        }
        rebuildContent()
    }

    private func applyPerformanceProfile(_ index: Int) {
        switch index {
        case 0:
            OPNStreamPreferences.saveCodecIndex(0)
            OPNStreamPreferences.saveFpsIndex(1)
            OPNStreamPreferences.saveBitrateIndex(2)
            OPNStreamPreferences.savePowerSaverEnabled(false)
            OPNStreamPreferences.saveL4SEnabled(false)
        case 1:
            OPNStreamPreferences.saveCodecIndex(1)
            OPNStreamPreferences.saveFpsIndex(1)
            OPNStreamPreferences.saveBitrateIndex(4)
            OPNStreamPreferences.savePowerSaverEnabled(false)
            OPNStreamPreferences.saveL4SEnabled(false)
        default: break
        }
    }

    private func selectedPerformanceProfile(_ profile: OPNStreamPreferenceProfile) -> Int {
        if !profile.enableL4S && !profile.enablePowerSaver && profile.codecIndex == 0 && profile.fpsIndex == 1 && profile.bitrateIndex == 2 { return 0 }
        if !profile.enableL4S && !profile.enablePowerSaver && profile.codecIndex == 1 && profile.fpsIndex == 1 && profile.bitrateIndex == 4 { return 1 }
        return 2
    }

    @objc private func resolutionPopupChanged(_ sender: NSPopUpButton) { OPNStreamPreferences.saveResolutionIndex(sender.indexOfSelectedItem); rebuildContent() }
    @objc private func regionPopupChanged(_ sender: NSPopUpButton) {
        let regions = OPNStreamPreferences.loadCachedRegions()
        let index = sender.indexOfSelectedItem
        if index <= 0 { OPNStreamPreferences.saveSelectedRegionUrl("") } else if index - 1 < regions.count { OPNStreamPreferences.saveSelectedRegionUrl(regions[index - 1].url) }
        OPNGameServiceSwiftAdapter.setStreamingBaseUrl(OPNStreamPreferences.loadSelectedStreamingBaseUrl())
        rebuildContent()
    }
    @objc private func l4sToggleChanged(_ sender: NSButton) { OPNStreamPreferences.saveL4SEnabled(sender.state == .on); rebuildContent() }
    @objc private func hdrToggleChanged(_ sender: NSButton) { OPNStreamPreferences.saveHDREnabled(sender.state == .on); rebuildContent() }
    @objc private func lowLatencyModeToggleChanged(_ sender: NSButton) { OPNStreamPreferences.saveLowLatencyModeEnabled(sender.state == .on); rebuildContent() }
    @objc private func prefilterSharpnessPopupChanged(_ sender: NSPopUpButton) { OPNStreamPreferences.savePrefilterSharpness(sender.indexOfSelectedItem); rebuildContent() }
    @objc private func prefilterDenoisePopupChanged(_ sender: NSPopUpButton) { OPNStreamPreferences.savePrefilterDenoise(sender.indexOfSelectedItem); rebuildContent() }
    @objc private func upscalingSharpnessPopupChanged(_ sender: NSPopUpButton) { OPNStreamPreferences.saveUpscalingSharpness(sender.indexOfSelectedItem); rebuildContent() }
    @objc private func upscalingDenoisePopupChanged(_ sender: NSPopUpButton) { OPNStreamPreferences.saveUpscalingDenoise(sender.indexOfSelectedItem); rebuildContent() }
    @objc private func recordingEnhancedVideoToggleChanged(_ sender: NSButton) { OPNStreamPreferences.saveRecordingEnhancedVideoEnabled(sender.state == .on); rebuildContent() }
    @objc private func recordingVideoBitrateSliderChanged(_ sender: NSSlider) {
        let bitrateMbps = Int(sender.doubleValue.rounded())
        OPNStreamPreferences.saveRecordingVideoBitrateMbps(bitrateMbps > 0 ? max(5, bitrateMbps) : 0)
        rebuildContent()
    }
    @objc private func recordingAudioBitrateSliderChanged(_ sender: NSSlider) { OPNStreamPreferences.saveRecordingAudioBitrateKbps(Int(sender.doubleValue.rounded())); rebuildContent() }
    @objc private func suppressInputWhenInactiveToggleChanged(_ sender: NSButton) { OPNStreamPreferences.saveSuppressInputWhenInactive(sender.state == .on); rebuildContent() }
    @objc private func directMouseInputToggleChanged(_ sender: NSButton) { OPNStreamPreferences.saveDirectMouseInputEnabled(sender.state == .on); rebuildContent() }
    @objc private func microphoneModePopupChanged(_ sender: NSPopUpButton) {
        let modes = OPNStreamPreferences.microphoneModeOptions
        let index = min(max(sender.indexOfSelectedItem, 0), max(0, modes.count - 1))
        if !modes.isEmpty { OPNStreamPreferences.saveMicrophoneMode(modes[index].value) }
        rebuildContent()
    }
    @objc private func microphoneDevicePopupChanged(_ sender: NSPopUpButton) {
        let devices = OPNStreamPreferences.loadMicrophoneDeviceOptions()
        let index = min(max(sender.indexOfSelectedItem, 0), max(0, devices.count - 1))
        if !devices.isEmpty { OPNStreamPreferences.saveMicrophoneDeviceId(devices[index].uniqueId) }
        rebuildContent()
    }
    @objc private func autoFullScreenToggleChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: InterfaceDefaults.autoFullScreen)
        UserDefaults.standard.synchronize()
        NotificationCenter.default.post(name: InterfaceDefaults.notification, object: nil)
    }
    @objc private func checkForUpdatesClicked(_ sender: NSButton) { onCheckForUpdatesRequested?() }
    @objc private func clearCachesClicked(_ sender: NSButton) {
        sender.isEnabled = false
        URLCache.shared.removeAllCachedResponses()
        let clearedDiskCaches = OPNGameDataCache.shared.clearAllCaches()
        sender.isEnabled = true
        let alert = NSAlert()
        alert.messageText = clearedDiskCaches ? "Caches Cleared" : "Some Caches Could Not Be Cleared"
        alert.informativeText = clearedDiskCaches ? "OpenNOW cleared cached catalog data, artwork, decoded images, and URL responses. Restart or refresh the catalog to re-download fresh assets." : "OpenNOW cleared memory caches, but one or more disk cache files could not be removed. Check the logs for details."
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    @objc private func streamRegionsUpdated(_ notification: Notification) {
        if sectionNames[selectedSection] == "Stream" { rebuildContent() }
    }

    private func scheduleLayoutRebuildContent() {
        layoutRebuildTimer?.invalidate()
        layoutRebuildTimer = Timer.scheduledTimer(timeInterval: 0.16, target: self, selector: #selector(layoutRebuildTimerFired(_:)), userInfo: nil, repeats: false)
    }

    @objc private func layoutRebuildTimerFired(_ timer: Timer) {
        layoutRebuildTimer = nil
        rebuildContent()
    }

    private func layoutContentSubviews() {
        let width = documentView.bounds.width
        var y: CGFloat = 0.0
        for subview in documentView.subviews {
            subview.frame = NSRect(x: 0.0, y: y, width: width, height: subview.frame.height)
            y += subview.frame.height + 24.0
        }
        documentView.frame = NSRect(x: 0.0, y: 0.0, width: width, height: max(y, scrollView.contentView.bounds.height))
    }

    private func scrollContentToTop() {
        scrollView.contentView.scroll(to: NSPoint(x: 0.0, y: 0.0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func startAudioDeviceMonitoring() {
        guard !audioDeviceListenerInstalled else { return }
        var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var defaultInputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let devicesStatus = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, settingsAudioDevicesChanged, pointer)
        let inputStatus = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, settingsAudioDevicesChanged, pointer)
        audioDeviceListenerInstalled = devicesStatus == noErr || inputStatus == noErr
    }

    private func stopAudioDeviceMonitoring() {
        guard audioDeviceListenerInstalled else { return }
        var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var defaultInputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, settingsAudioDevicesChanged, pointer)
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, settingsAudioDevicesChanged, pointer)
        audioDeviceListenerInstalled = false
    }

    private func selectedAppIconIndex() -> Int {
        switch UserDefaults.standard.string(forKey: InterfaceDefaults.appIconTheme) {
        case "green": return 1
        case "blue": return 2
        default: return 0
        }
    }

    private func setAppIconTheme(_ index: Int) {
        let value = index == 1 ? "green" : (index == 2 ? "blue" : "black")
        UserDefaults.standard.set(value, forKey: InterfaceDefaults.appIconTheme)
        UserDefaults.standard.synchronize()
        NotificationCenter.default.post(name: InterfaceDefaults.notification, object: nil)
    }

    private func discordPresenceMode() -> Int {
        let stored = UserDefaults.standard.integer(forKey: InterfaceDefaults.discordPresenceMode)
        return stored == 1 || stored == 2 ? stored : 0
    }

    private func saveDiscordPresenceMode(_ index: Int) {
        OPNDiscordPresence.saveMode(index == 1 ? 1 : (index == 2 ? 2 : 0))
    }

    private func sessionReportDisplayMode() -> Int {
        let stored = UserDefaults.standard.integer(forKey: InterfaceDefaults.sessionReportDisplayMode)
        return stored >= 1 && stored <= 3 ? stored : 0
    }

    private func saveSessionReportDisplayMode(_ index: Int) {
        UserDefaults.standard.set(index >= 1 && index <= 3 ? index : 0, forKey: InterfaceDefaults.sessionReportDisplayMode)
        UserDefaults.standard.synchronize()
    }

    private func discordClientId() -> String {
        if let defaultsValue = UserDefaults.standard.string(forKey: InterfaceDefaults.discordClientId), !defaultsValue.isEmpty { return defaultsValue }
        if let plistValue = Bundle.main.object(forInfoDictionaryKey: "OPNDiscordClientID") as? String, !plistValue.isEmpty { return plistValue }
        return ProcessInfo.processInfo.environment["OPN_DISCORD_CLIENT_ID"] ?? ""
    }

    private func localEnhancementRuntimeInfo() -> (gpu: String, summary: String) {
        let device = MTLCreateSystemDefaultDevice()
        let metalAvailable = device != nil
        let gpuName = device?.name.isEmpty == false ? device!.name : (metalAvailable ? "Metal GPU" : "No Metal device detected")
        let metalSpatial = metalAvailable ? "Supported on \(gpuName)" : "Unavailable: this Mac does not expose a Metal device"
        let temporal = metalAvailable ? "Supported on \(gpuName)" : "Unavailable: temporal reconstruction requires Metal"
        let enhancedRecording = metalAvailable ? "Supported while local upscaling is active; raw recording remains fallback" : "Unavailable: enhanced capture requires Metal; raw recording remains fallback"
        return (gpuName, "Metal spatial upscaling: \(metalSpatial)\nTemporal reconstruction: \(temporal)\nMetalFX spatial upscaling: Checked at runtime\nEnhanced recording output: \(enhancedRecording)\nNative fallback renderer: Checked when libwebrtc starts")
    }
}
