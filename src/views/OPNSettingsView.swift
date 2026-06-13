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
        HStack(spacing: 24) {
            sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    content
                }
                .padding(.trailing, 44)
                .padding(.bottom, 40)
            }
        }
        .padding(.top, 104)
        .padding(.horizontal, 64)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SETTINGS")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            ForEach(model.sectionNames, id: \.self) { section in
                Button {
                    model.selectedSection = section
                } label: {
                    HStack {
                        Text(section == "Stream" ? "Network" : section)
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(model.selectedSection == section ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button("Back") { onBack() }
        }
        .frame(width: 240)
        .padding(18)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.selectedSection == "Stream" ? "Network" : model.selectedSection)
                .font(.system(size: 30, weight: .bold))
            Text(sectionDescription(model.selectedSection))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
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

    private var streamSection: some View {
        settingsPanel("Network") {
            pickerRow("Cloudmatch Region", selection: Binding(get: { model.profile.selectedRegionUrl }, set: { model.saveSelectedRegionUrl($0) })) {
                Text("Automatic").tag("")
                ForEach(model.regions, id: \.url) { region in
                    Text(region.label).tag(region.url)
                }
            }
            pickerRow("Max Bitrate", selection: Binding(get: { model.profile.bitrateIndex }, set: { model.saveBitrateIndex($0) })) {
                ForEach(OPNStreamPreferences.bitrateOptions.indices, id: \.self) { index in
                    Text(OPNStreamPreferences.bitrateOptions[index].label).tag(index)
                }
            }
            Toggle("Low latency mode", isOn: Binding(get: { model.profile.lowLatencyMode }, set: { model.saveLowLatency($0) }))
            Toggle("L4S when supported", isOn: Binding(get: { model.profile.enableL4S }, set: { model.saveL4S($0) }))
            Toggle("Power saver", isOn: Binding(get: { model.profile.enablePowerSaver }, set: { model.savePowerSaver($0) }))
        }
    }

    private var videoSection: some View {
        settingsPanel("Video") {
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
            Toggle("HDR when supported", isOn: Binding(get: { model.profile.enableHdr }, set: { model.saveHDR($0) }))
            Toggle("Record enhanced video", isOn: Binding(get: { model.profile.recordingEnhancedVideoEnabled }, set: { model.saveEnhancedRecording($0) }))
            intSlider("Recording Video Mbps", value: model.profile.recordingVideoBitrateMbps, range: 0...200, save: { model.saveRecordingVideoBitrate($0) })
            intSlider("Recording Audio Kbps", value: model.profile.recordingAudioBitrateKbps, range: 64...320, save: { model.saveRecordingAudioBitrate($0) })
        }
    }

    private var audioSection: some View {
        settingsPanel("Audio") {
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
            Toggle("Microphone shortcut enabled", isOn: Binding(get: { OPNStreamPreferences.loadMicrophoneShortcutEnabled() }, set: { model.saveMicrophoneShortcutEnabled($0) }))
            percentSlider("Game Volume", value: model.profile.gameVolume, save: { model.saveGameVolume($0) })
            percentSlider("Microphone Volume", value: model.profile.microphoneVolume, save: { model.saveMicrophoneVolume($0) })
            Text("Push-to-talk: \(model.profile.microphonePushToTalkComboLabel)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var inputSection: some View {
        settingsPanel("Input") {
            Toggle("Direct mouse input", isOn: Binding(get: { model.profile.directMouseInput }, set: { model.saveDirectMouseInput($0) }))
            Toggle("Suppress input when window is inactive", isOn: Binding(get: { model.profile.suppressInputWhenInactive }, set: { model.saveSuppressInputWhenInactive($0) }))
        }
    }

    private var interfaceSection: some View {
        settingsPanel("Interface") {
            Toggle("Enter full screen automatically when a stream starts", isOn: Binding(get: { model.autoFullScreen }, set: { model.saveAutoFullScreen($0) }))
            pickerRow("App Icon", selection: Binding(get: { model.appIconTheme }, set: { model.saveAppIconTheme($0) })) {
                Text("Black").tag(0)
                Text("Green").tag(1)
                Text("Sky Blue").tag(2)
            }
            Button("Check for Updates") { onCheckForUpdates() }
        }
    }

    private var aboutSection: some View {
        settingsPanel("About") {
            Text("OpenNOW")
                .font(.system(size: 22, weight: .bold))
            Text("Native macOS cloud gaming client with a SwiftUI-first interface and native WebRTC/Metal streaming islands.")
                .foregroundStyle(.secondary)
            Button("Check for Updates") { onCheckForUpdates() }
        }
    }

    private var thanksSection: some View {
        settingsPanel("Thanks") {
            Text("Thanks to the open-source projects and contributors that make OpenNOW possible.")
                .foregroundStyle(.secondary)
        }
    }

    private func settingsPanel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
            content()
        }
        .padding(22)
        .frame(maxWidth: 820, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private func pickerRow<Selection: Hashable, Content: View>(_ title: String, selection: Binding<Selection>, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Picker(title, selection: selection, content: content)
                .labelsHidden()
                .frame(width: 260)
        }
    }

    private func intSlider(_ title: String, value: Int, range: ClosedRange<Int>, save: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(value) }, set: { save(Int($0.rounded())) }), in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
            Text("\(value)")
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func percentSlider(_ title: String, value: Double, save: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { value }, set: { save($0) }), in: 0...1, step: 0.01)
            Text("\(Int((value * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func sectionDescription(_ section: String) -> String {
        switch section {
        case "Stream": return "Choose route, bitrate, and network behavior."
        case "Video": return "Tune resolution, codec, upscaling, HDR, and recording quality."
        case "Audio": return "Control microphone mode, input device, and stream volumes."
        case "Input": return "Configure keyboard and mouse behavior while streaming."
        case "Interface": return "Adjust app presentation and update behavior."
        case "About": return "Version and project information."
        default: return "Project acknowledgements."
        }
    }
}
