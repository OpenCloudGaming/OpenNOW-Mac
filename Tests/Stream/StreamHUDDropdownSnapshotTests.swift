import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// Renders a HUD dropdown open inside a section stack, with the section below it — the arrangement that
/// fails when the open panel is not lifted above its sibling.
///
/// `ImageRenderer` needs no screen and no live session, so this is the only way to look at an open HUD
/// dropdown without a seat. The failure it guards against is visual and compiles cleanly: a catalog
/// panel here reads as translucent text spilling across the rows beneath it.
///
/// The components are the real ones (`StreamHUDSection`, `StreamHUDDropdown`, the model's own rows);
/// the panel body around them is not, because a `@StateObject` model cannot be reached from outside a
/// render and the surface's panels read theirs.
@Suite struct StreamHUDDropdownSnapshotTests {
    @MainActor
    private func seededModel() -> NativeNVSTHostViewModel {
        NativeNVSTHostViewModel(
            configuration: StreamLaunchConfiguration(title: "Game", applicationID: "100", accessToken: "token", accountLinked: true, selectedStore: "steam"),
            sessionProvider: StubNativeNVSTSessionProvider(),
            preventDisplaySleep: false,
            onProgress: nil,
            onEnd: { _, _, _ in }
        )
    }

    @MainActor
    private func render(_ name: String) throws -> NSImage {
        let model = seededModel()
        model.microphoneDeviceOptions = [
            OPNStreamMicrophoneDeviceOption(label: "Default Device", uniqueId: "", automatic: true),
            OPNStreamMicrophoneDeviceOption(label: "MacBook Microphone", uniqueId: "built-in"),
        ]
        model.isMicrophoneSectionNegotiated = true
        model.microphoneMode = "voice-activity"
        let modeDropdownID = NativeNVSTHostViewModel.microphoneModeDropdownID
        let deviceDropdownID = NativeNVSTHostViewModel.microphoneDeviceDropdownID
        model.hudFocusID = modeDropdownID
        // The pad holds the panel open, which is what a controller's confirm does.
        model.openHUDDropdownID = modeDropdownID
        model.hudDropdownHighlightedItemID = "push-to-talk"

        let content = VStack(alignment: .leading, spacing: 8) {
            audioSection(model: model, modeDropdownID: modeDropdownID, deviceDropdownID: deviceDropdownID)
            inputSection
        }
        .frame(width: 320, alignment: .leading)
        .padding(10)
        .background(StreamHUDTheme.appBar)
        .frame(width: 340, height: 440, alignment: .top)
        .background(Color.black)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "the panel did not render")
        writeSnapshot(image, name: name)
        return image
    }

    /// The AUDIO panel's own arrangement: a grid above it in the real HUD, the two dropdown rows here.
    @MainActor
    private func audioSection(model: NativeNVSTHostViewModel, modeDropdownID: String, deviceDropdownID: String) -> some View {
        StreamHUDSection(label: "AUDIO", isCollapsed: false, isFocused: false, reorderPayload: nil, onToggle: {}) {
            VStack(alignment: .leading, spacing: 8) {
                StreamHUDDropdown(
                    label: "Microphone Mode",
                    rows: model.padDropdownItems(modeDropdownID),
                    selection: model.microphoneMode,
                    isDisabled: false,
                    isFocused: true,
                    visibleItemCount: 6,
                    padDriver: model.padDropdown(dropdownID: modeDropdownID)
                )
                StreamHUDDropdown(
                    label: "Microphone Device",
                    rows: model.padDropdownItems(deviceDropdownID),
                    selection: model.selectedMicrophoneDeviceUID,
                    isDisabled: false,
                    visibleItemCount: 6,
                    padDriver: model.padDropdown(dropdownID: deviceDropdownID)
                )
                Text("Microphone Level 0%")
                    .font(.streamFont(size: 11, weight: .bold))
                    .foregroundStyle(StreamHUDTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The section the open panel has to lift itself above.
    private var inputSection: some View {
        StreamHUDSection(label: "INPUT", isCollapsed: false, isFocused: false, reorderPayload: nil, onToggle: {}) {
            Text("Pointer \u{00b7} Cursor \u{00b7} Anti-AFK")
                .font(.streamFont(size: 11, weight: .bold))
                .foregroundStyle(StreamHUDTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Written where a person can look at it; the assertions in each test are what gate it.
    @MainActor
    private func writeSnapshot(_ image: NSImage, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"],
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @Test @MainActor func theHUDRendersWithItsDropdownOpen() throws {
        let image = try render("hud-audio-panel-dropdown-open.png")
        #expect(image.size.width > 300, "the panel collapsed horizontally")
        #expect(image.size.height > 400, "the section stack collapsed, leaving the open panel nowhere to draw")
    }
}
