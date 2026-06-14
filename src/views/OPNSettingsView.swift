import Backend
import SwiftUI

import Common

@MainActor
private final class OPNSettingsModel: ObservableObject {
    let sectionNames = ["Stream", "Video", "Audio", "Input", "Interface", "About", "Thanks"]

    @Published var selectedSection: String
    @Published var profile: OPNStreamPreferenceProfile
    @Published var regions: [OPNStreamRegionOption]
    @Published var microphones: [OPNStreamMicrophoneDeviceOption]
    @Published var autoFullScreen: Bool
    @Published var appIconTheme: Int

    init(selectedSectionName: String?) {
        selectedSection = sectionNames.contains(selectedSectionName ?? "") ? selectedSectionName! : sectionNames[0]
        profile = OPNStreamPreferences.loadProfile()
        regions = OPNStreamPreferences.loadCachedRegions()
        microphones = OPNStreamPreferences.loadMicrophoneDeviceOptions()
        autoFullScreen = OPNUIHelpers.autoFullScreenEnabled()
        appIconTheme = OPNUIHelpers.appIconThemePreference()
    }

    func moveSelection(by delta: Int) {
        guard delta != 0, let index = sectionNames.firstIndex(of: selectedSection) else { return }
        selectedSection = sectionNames[min(max(0, index + delta), sectionNames.count - 1)]
    }

    func reload() {
        profile = OPNStreamPreferences.loadProfile()
        regions = OPNStreamPreferences.loadCachedRegions()
        microphones = OPNStreamPreferences.loadMicrophoneDeviceOptions()
        autoFullScreen = OPNUIHelpers.autoFullScreenEnabled()
        appIconTheme = OPNUIHelpers.appIconThemePreference()
    }

    func saveAspectIndex(_ value: Int) { OPNStreamPreferences.saveAspectIndex(value); reload() }
    func saveResolutionIndex(_ value: Int) { OPNStreamPreferences.saveResolutionIndex(value); reload() }
    func saveFpsIndex(_ value: Int) { OPNStreamPreferences.saveFpsIndex(value); reload() }
    func saveCodecIndex(_ value: Int) { OPNStreamPreferences.saveCodecIndex(value); reload() }
    func saveBitrateIndex(_ value: Int) { OPNStreamPreferences.saveBitrateIndex(value); reload() }
    func saveColorQualityIndex(_ value: Int) { OPNStreamPreferences.saveColorQualityIndex(value); reload() }
    func savePrefilterModeIndex(_ value: Int) { OPNStreamPreferences.savePrefilterModeIndex(value); reload() }
    func savePrefilterSharpness(_ value: Int) { OPNStreamPreferences.savePrefilterSharpness(value); reload() }
    func savePrefilterDenoise(_ value: Int) { OPNStreamPreferences.savePrefilterDenoise(value); reload() }
    func saveUpscalingModeIndex(_ value: Int) { OPNStreamPreferences.saveUpscalingModeIndex(value); reload() }
    func saveUpscalingSharpness(_ value: Int) { OPNStreamPreferences.saveUpscalingSharpness(value); reload() }
    func saveUpscalingDenoise(_ value: Int) { OPNStreamPreferences.saveUpscalingDenoise(value); reload() }
    func saveRecordingVideoBitrate(_ value: Int) { OPNStreamPreferences.saveRecordingVideoBitrateMbps(value); reload() }
    func saveRecordingAudioBitrate(_ value: Int) { OPNStreamPreferences.saveRecordingAudioBitrateKbps(value); reload() }
    func saveEnhancedRecording(_ value: Bool) { OPNStreamPreferences.saveRecordingEnhancedVideoEnabled(value); reload() }
    func saveL4S(_ value: Bool) { OPNStreamPreferences.saveL4SEnabled(value); reload() }
    func saveHDR(_ value: Bool) { OPNStreamPreferences.saveHDREnabled(value); reload() }
    func saveLowLatency(_ value: Bool) { OPNStreamPreferences.saveLowLatencyModeEnabled(value); reload() }
    func savePowerSaver(_ value: Bool) { OPNStreamPreferences.savePowerSaverEnabled(value); reload() }
    func saveSuppressInputWhenInactive(_ value: Bool) { OPNStreamPreferences.saveSuppressInputWhenInactive(value); reload() }
    func saveDirectMouseInput(_ value: Bool) { OPNStreamPreferences.saveDirectMouseInputEnabled(value); reload() }
    func saveGameVolume(_ value: Double) { OPNStreamPreferences.saveGameVolume(value); reload() }
    func saveMicrophoneVolume(_ value: Double) { OPNStreamPreferences.saveMicrophoneVolume(value); reload() }
    func saveMicrophoneMode(_ value: String) { OPNStreamPreferences.saveMicrophoneMode(value); reload() }
    func saveMicrophoneDevice(_ value: String) { OPNStreamPreferences.saveMicrophoneDeviceId(value); reload() }
    func saveMicrophoneShortcutEnabled(_ value: Bool) { OPNStreamPreferences.saveMicrophoneShortcutEnabled(value); reload() }
    func saveSelectedRegionUrl(_ value: String) { OPNStreamPreferences.saveSelectedRegionUrl(value); OPNGameServiceSwiftAdapter.setStreamingBaseUrl(OPNStreamPreferences.loadSelectedStreamingBaseUrl()); reload() }
    func saveAutoFullScreen(_ value: Bool) { OPNUIHelpers.setAutoFullScreenEnabled(value); reload() }
    func saveAppIconTheme(_ value: Int) { OPNUIHelpers.setAppIconThemePreference(value); reload() }
}

@objc(OPNSettingsView)
@MainActor
final class OPNSettingsView: NSView {
    @objc var onBackRequested: (() -> Void)?
    @objc var onCheckForUpdatesRequested: (() -> Void)?

    private let model: OPNSettingsModel
    private var hostingView: NSHostingView<OPNSettingsSwiftUIView>?

    @objc override init(frame frameRect: NSRect) {
        model = OPNSettingsModel(selectedSectionName: nil)
        super.init(frame: frameRect)
        configure()
    }

    @objc(initWithFrame:selectedSectionName:)
    init(frame frameRect: NSRect, selectedSectionName: String?) {
        model = OPNSettingsModel(selectedSectionName: selectedSectionName)
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        model = OPNSettingsModel(selectedSectionName: nil)
        super.init(coder: coder)
        configure()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    @objc func moveGamepadSelection(by delta: NSInteger) {
        model.moveSelection(by: delta)
    }

    @objc func activateGamepadSelection() {}

    private func configure() {
        subviews.forEach { $0.removeFromSuperview() }
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let root = OPNSettingsSwiftUIView(
            model: model,
            onBack: { [weak self] in self?.onBackRequested?() },
            onCheckForUpdates: { [weak self] in self?.onCheckForUpdatesRequested?() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
    }
}

private struct OPNSettingsSwiftUIView: View {
    @ObservedObject var model: OPNSettingsModel
    let onBack: () -> Void
    let onCheckForUpdates: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 980
            HStack(alignment: .top, spacing: compact ? 16 : 24) {
                sidebar(compact: compact)
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        header
                        content
                    }
                    .padding(.trailing, compact ? 20 : 44)
                    .padding(.bottom, 40)
                }
            }
            .padding(.top, compact ? 72 : 104)
            .padding(.horizontal, compact ? 28 : 64)
        }
        .tint(settingsAccentColor)
    }

    private func sidebar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(settingsAccentColor)
                    .frame(width: 30, height: 30)
                    .background(settingsAccentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("SETTINGS")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.secondary)
                    Text("OpenNOW Control")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(.bottom, 10)
            ForEach(model.sectionNames, id: \.self) { section in
                let selected = model.selectedSection == section
                Button {
                    model.selectedSection = section
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: sectionDetail(section).symbol)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(selected ? Color.black.opacity(0.82) : sectionColor(section).opacity(0.92))
                            .frame(width: 26, height: 26)
                            .background(selected ? settingsAccentColor : sectionColor(section).opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sectionDetail(section).title)
                                .font(.system(size: 14, weight: .semibold))
                            Text(sectionDetail(section).shortDescription)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(selected ? Color.primary.opacity(0.78) : .secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if selected {
                            Circle()
                                .fill(settingsAccentColor)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .foregroundStyle(selected ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 54)
                    .background(selected ? .white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(selected ? settingsAccentColor.opacity(0.34) : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 18)
            Button { onBack() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                    Text("Back to Library")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .frame(width: compact ? 224 : 270)
        .padding(18)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: sectionDetail(model.selectedSection).symbol)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .frame(width: 54, height: 54)
                    .background(sectionColor(model.selectedSection), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: sectionColor(model.selectedSection).opacity(0.28), radius: 18, y: 8)
                VStack(alignment: .leading, spacing: 6) {
                    Text(sectionDetail(model.selectedSection).title)
                        .font(.system(size: 34, weight: .bold))
                    Text(sectionDetail(model.selectedSection).description)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
            }
            summaryStrip
        }
    }

    @ViewBuilder private var content: some View {
        switch model.selectedSection {
        case "Stream": streamSection
        case "Video": videoSection
        case "Audio": audioSection
        case "Input": inputSection
        case "Interface": interfaceSection
        case "About": aboutSection
        default: thanksSection
        }
    }

    private var summaryStrip: some View {
        HStack(spacing: 12) {
            summaryTile("Signal", value: "\(model.profile.resolution.label) @ \(model.profile.fps) FPS", symbol: "display")
            summaryTile("Codec", value: model.profile.codec.label, symbol: "video.fill")
            summaryTile("Network", value: model.profile.bitrate.label, symbol: "antenna.radiowaves.left.and.right")
        }
        .frame(maxWidth: 820)
    }

    private func summaryTile(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(settingsAccentColor)
                .frame(width: 28, height: 28)
                .background(settingsAccentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.09), lineWidth: 1))
    }

    private var streamSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsPanel("Connection", subtitle: "Choose where the stream starts and how much bandwidth it can use.") {
                pickerRow("Cloudmatch Region", subtitle: "Automatic picks the lowest measured region.", selection: Binding(get: { model.profile.selectedRegionUrl }, set: { model.saveSelectedRegionUrl($0) })) {
                    Text("Automatic").tag("")
                    ForEach(model.regions, id: \.url) { region in
                        Text(region.label).tag(region.url)
                    }
                }
                pickerRow("Max Bitrate", subtitle: "Caps video bandwidth before session negotiation.", selection: Binding(get: { model.profile.bitrateIndex }, set: { model.saveBitrateIndex($0) })) {
                    ForEach(OPNStreamPreferences.bitrateOptions.indices, id: \.self) { index in
                        Text(OPNStreamPreferences.bitrateOptions[index].label).tag(index)
                    }
                }
            }
            settingsPanel("Network Behavior", subtitle: "Prioritize latency, modern packet handling, or battery life.") {
                toggleRow("Low latency mode", subtitle: "Biases the session toward responsiveness.", isOn: Binding(get: { model.profile.lowLatencyMode }, set: { model.saveLowLatency($0) }))
                toggleRow("L4S when supported", subtitle: "Uses low-latency congestion signaling when available.", isOn: Binding(get: { model.profile.enableL4S }, set: { model.saveL4S($0) }))
                toggleRow("Power saver", subtitle: "Reduces stream pressure for longer unplugged sessions.", isOn: Binding(get: { model.profile.enablePowerSaver }, set: { model.savePowerSaver($0) }))
            }
        }
    }

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsPanel("Signal", subtitle: "Set the core stream shape before cloud negotiation.") {
                pickerRow("Aspect", selection: Binding(get: { model.profile.aspectIndex }, set: { model.saveAspectIndex($0) })) {
                    ForEach(OPNStreamPreferences.aspectOptions.indices, id: \.self) { index in
                        Text(OPNStreamPreferences.aspectOptions[index].label).tag(index)
                    }
                }
                pickerRow("Resolution", selection: Binding(get: { model.profile.resolutionIndex }, set: { model.saveResolutionIndex($0) })) {
                    ForEach(OPNStreamPreferences.resolutionOptions(forAspect: model.profile.aspectIndex).indices, id: \.self) { index in
                        Text(OPNStreamPreferences.resolutionOptions(forAspect: model.profile.aspectIndex)[index].label).tag(index)
                    }
                }
                pickerRow("Frame Rate", selection: Binding(get: { model.profile.fpsIndex }, set: { model.saveFpsIndex($0) })) {
                    ForEach(OPNStreamPreferences.fpsOptions.indices, id: \.self) { index in
                        Text("\(OPNStreamPreferences.fpsOptions[index]) FPS").tag(index)
                    }
                }
                pickerRow("Codec", selection: Binding(get: { model.profile.codecIndex }, set: { model.saveCodecIndex($0) })) {
                    ForEach(OPNStreamPreferences.codecOptions.indices, id: \.self) { index in
                        Text(OPNStreamPreferences.codecOptions[index].label).tag(index)
                    }
                }
                pickerRow("Color Quality", selection: Binding(get: { model.profile.colorQualityIndex }, set: { model.saveColorQualityIndex($0) })) {
                    ForEach(OPNStreamPreferences.colorQualityOptions.indices, id: \.self) { index in
                        Text(OPNStreamPreferences.colorQualityOptions[index].label).tag(index)
                    }
                }
                toggleRow("HDR when supported", subtitle: "Requests high dynamic range where cloud and display support it.", isOn: Binding(get: { model.profile.enableHdr }, set: { model.saveHDR($0) }))
            }
            settingsPanel("Enhancement", subtitle: "Sharpen, denoise, and upscale the stream after decode.") {
                pickerRow("Prefilter", selection: Binding(get: { model.profile.prefilterModeIndex }, set: { model.savePrefilterModeIndex($0) })) {
                    ForEach(OPNStreamPreferences.prefilterModeOptions.indices, id: \.self) { index in
                        Text(OPNStreamPreferences.prefilterModeOptions[index].label).tag(index)
                    }
                }
                intSlider("Prefilter Sharpness", value: model.profile.prefilterSharpness, range: 0...10, save: { model.savePrefilterSharpness($0) })
                intSlider("Prefilter Denoise", value: model.profile.prefilterDenoise, range: 0...10, save: { model.savePrefilterDenoise($0) })
                pickerRow("Upscaling", selection: Binding(get: { model.profile.upscalingModeIndex }, set: { model.saveUpscalingModeIndex($0) })) {
                    ForEach(OPNStreamPreferences.upscalingModeOptions.indices, id: \.self) { index in
                        Text(OPNStreamPreferences.upscalingModeOptions[index].label).tag(index)
                    }
                }
                intSlider("Upscaling Sharpness", value: model.profile.upscalingSharpness, range: 0...40, save: { model.saveUpscalingSharpness($0) })
                intSlider("Upscaling Denoise", value: model.profile.upscalingDenoise, range: 0...20, save: { model.saveUpscalingDenoise($0) })
            }
            settingsPanel("Recording", subtitle: "Control local capture quality independently from live playback.") {
                toggleRow("Record enhanced video", subtitle: "Applies enhancement output to recordings.", isOn: Binding(get: { model.profile.recordingEnhancedVideoEnabled }, set: { model.saveEnhancedRecording($0) }))
                intSlider("Recording Video Mbps", value: model.profile.recordingVideoBitrateMbps, range: 0...200, save: { model.saveRecordingVideoBitrate($0) })
                intSlider("Recording Audio Kbps", value: model.profile.recordingAudioBitrateKbps, range: 64...320, save: { model.saveRecordingAudioBitrate($0) })
            }
        }
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsPanel("Microphone", subtitle: "Choose when OpenNOW captures your mic and which device it uses.") {
                pickerRow("Microphone Mode", selection: Binding(get: { model.profile.microphoneMode }, set: { model.saveMicrophoneMode($0) })) {
                    ForEach(OPNStreamPreferences.microphoneModeOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                pickerRow("Microphone Device", selection: Binding(get: { model.profile.microphoneDeviceId }, set: { model.saveMicrophoneDevice($0) })) {
                    ForEach(model.microphones, id: \.uniqueId) { option in
                        Text(option.label).tag(option.uniqueId)
                    }
                }
                toggleRow("Microphone shortcut enabled", subtitle: "Allows push-to-talk capture while streaming.", isOn: Binding(get: { OPNStreamPreferences.loadMicrophoneShortcutEnabled() }, set: { model.saveMicrophoneShortcutEnabled($0) }))
                infoRow("Push-to-talk", value: model.profile.microphonePushToTalkComboLabel)
            }
            settingsPanel("Mix", subtitle: "Balance game audio and microphone gain before sending to the session.") {
                percentSlider("Game Volume", value: model.profile.gameVolume, save: { model.saveGameVolume($0) })
                percentSlider("Microphone Volume", value: model.profile.microphoneVolume, save: { model.saveMicrophoneVolume($0) })
            }
        }
    }

    private var inputSection: some View {
        settingsPanel("Input Capture", subtitle: "Make pointer and keyboard behavior predictable during play.") {
            toggleRow("Direct mouse input", subtitle: "Sends raw mouse movement to the active stream.", isOn: Binding(get: { model.profile.directMouseInput }, set: { model.saveDirectMouseInput($0) }))
            toggleRow("Suppress input when window is inactive", subtitle: "Prevents accidental remote input while OpenNOW is not focused.", isOn: Binding(get: { model.profile.suppressInputWhenInactive }, set: { model.saveSuppressInputWhenInactive($0) }))
        }
    }

    private var interfaceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsPanel("Presentation", subtitle: "Tune how OpenNOW enters and represents stream mode.") {
                toggleRow("Enter full screen automatically", subtitle: "Switches to full screen when a stream starts.", isOn: Binding(get: { model.autoFullScreen }, set: { model.saveAutoFullScreen($0) }))
                pickerRow("App Icon", selection: Binding(get: { model.appIconTheme }, set: { model.saveAppIconTheme($0) })) {
                    Text("Black").tag(0)
                    Text("Green").tag(1)
                    Text("Sky Blue").tag(2)
                }
            }
            settingsPanel("Maintenance", subtitle: "Keep the client current without leaving settings.") {
                actionRow("Check for Updates", subtitle: "Look for the latest OpenNOW release.", action: onCheckForUpdates)
            }
        }
    }

    private var aboutSection: some View {
        settingsPanel("About OpenNOW", subtitle: "Native macOS cloud gaming with WebRTC and Metal streaming islands.") {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .frame(width: 64, height: 64)
                    .background(settingsAccentColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text("OpenNOW")
                        .font(.system(size: 24, weight: .bold))
                    Text("A native macOS cloud gaming client focused on responsive streaming, clean library navigation, and native platform integration.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            actionRow("Check for Updates", subtitle: "Verify whether a newer build is available.", action: onCheckForUpdates)
        }
    }

    private var thanksSection: some View {
        settingsPanel("Thanks", subtitle: "OpenNOW builds on community tooling and open-source work.") {
            Text("Thanks to the open-source projects and contributors that make OpenNOW possible.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsPanel<Content: View>(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        }
        .padding(22)
        .frame(maxWidth: 820, alignment: .leading)
        .background(
            LinearGradient(colors: [.white.opacity(0.075), .white.opacity(0.038)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.11), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 10)
    }

    private func pickerRow<Selection: Hashable, Content: View>(_ title: String, subtitle: String? = nil, selection: Binding<Selection>, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 18) {
            rowTitle(title, subtitle: subtitle)
            Spacer()
            Picker(title, selection: selection, content: content)
                .labelsHidden()
                .frame(width: 260)
        }
        .settingsRowBackground()
    }

    private func toggleRow(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            rowTitle(title, subtitle: subtitle)
        }
        .toggleStyle(.switch)
        .settingsRowBackground()
    }

    private func intSlider(_ title: String, value: Int, range: ClosedRange<Int>, save: @escaping (Int) -> Void) -> some View {
        HStack(alignment: .center, spacing: 18) {
            rowTitle(title, subtitle: nil)
            Slider(value: Binding(get: { Double(value) }, set: { save(Int($0.rounded())) }), in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
            Text("\(value)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .settingsRowBackground()
    }

    private func percentSlider(_ title: String, value: Double, save: @escaping (Double) -> Void) -> some View {
        HStack(alignment: .center, spacing: 18) {
            rowTitle(title, subtitle: nil)
            Slider(value: Binding(get: { value }, set: { save($0) }), in: 0...1, step: 0.01)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .settingsRowBackground()
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack(spacing: 18) {
            rowTitle(title, subtitle: nil)
            Spacer(minLength: 16)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.white.opacity(0.08), in: Capsule())
        }
        .settingsRowBackground()
    }

    private func actionRow(_ title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 18) {
            rowTitle(title, subtitle: subtitle)
            Spacer(minLength: 16)
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.clockwise")
                    Text("Run")
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.84))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(settingsAccentColor, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .settingsRowBackground()
    }

    private func rowTitle(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 190, maxWidth: 330, alignment: .leading)
    }

    private var settingsAccentColor: Color { settingsColor(0x34C759, 1) }

    private func sectionColor(_ section: String) -> Color {
        settingsColor(sectionDetail(section).accent, 1)
    }

    private func settingsColor(_ rgb: UInt32, _ alpha: CGFloat) -> Color {
        Color(nsColor: OPNUIHelpers.color(rgb: rgb, alpha: alpha))
    }

    private func sectionDetail(_ section: String) -> (title: String, shortDescription: String, description: String, symbol: String, accent: UInt32) {
        switch section {
        case "Stream":
            return ("Network", "Route and bitrate", "Choose route, bitrate, and network behavior for new cloud sessions.", "network", 0x34C759)
        case "Video":
            return ("Video", "Signal and capture", "Tune resolution, codec, upscaling, HDR, and recording quality.", "sparkles.tv", 0x64D2FF)
        case "Audio":
            return ("Audio", "Mic and mix", "Control microphone mode, input device, and stream volumes.", "waveform", 0xBF5AF2)
        case "Input":
            return ("Input", "Mouse and focus", "Configure keyboard and mouse behavior while streaming.", "keyboard", 0xFF9F0A)
        case "Interface":
            return ("Interface", "Presentation", "Adjust app presentation, icon styling, and update behavior.", "macwindow", 0x0A84FF)
        case "About":
            return ("About", "Client details", "Version and project information for OpenNOW.", "info.circle", 0xF5F5F7)
        default:
            return ("Thanks", "Acknowledgements", "Project acknowledgements and contributor notes.", "heart", 0xFF375F)
        }
    }
}

private extension View {
    func settingsRowBackground() -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.07), lineWidth: 1))
    }
}
