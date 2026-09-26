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

    /// Written where a person can look at it; the assertions in each test are what gate it.
    @MainActor
    private func render(_ content: some View, name: String) throws -> NSImage {
        let renderer = ImageRenderer(content: content
            .frame(width: 320, alignment: .leading)
            .padding(10)
            .background(StreamHUDTheme.appBar)
            .frame(width: 340, height: 440, alignment: .top)
            .background(Color.black))
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "the panel did not render")
        writeSnapshot(image, name: name)
        return image
    }

    @MainActor
    private func writeSnapshot(_ image: NSImage, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"],
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    /// The AUDIO panel's rows, with the mode dropdown held open by the pad.
    @Test @MainActor func theAudioDropdownRendersOverTheSectionBeneathIt() throws {
        let model = seededModel()
        model.microphoneDeviceOptions = [
            OPNStreamMicrophoneDeviceOption(label: "Default Device", uniqueId: "", automatic: true),
            OPNStreamMicrophoneDeviceOption(label: "MacBook Microphone", uniqueId: "built-in"),
        ]
        model.isMicrophoneSectionNegotiated = true
        model.microphoneMode = "voice-activity"
        let modeDropdownID = NativeNVSTHostViewModel.microphoneModeDropdownID
        model.hudFocusID = modeDropdownID
        model.openHUDDropdownID = modeDropdownID
        model.hudDropdownHighlightedItemID = "push-to-talk"

        let content = VStack(alignment: .leading, spacing: 8) {
            section("AUDIO") {
                StreamHUDDropdown(
                    label: "Microphone Mode",
                    rows: model.padDropdownItems(modeDropdownID),
                    selection: model.microphoneMode,
                    isDisabled: false,
                    isFocused: true,
                    visibleItemCount: 6,
                    padDriver: model.padDropdown(dropdownID: modeDropdownID)
                )
                row("Microphone Device", "Default Device")
                row("Microphone Level", "0%")
            }
            section("INPUT") { row("Pointer", "Absolute") }
        }
        let image = try render(content, name: "hud-audio-dropdown-open.png")
        #expect(image.size.height > 400, "the section stack collapsed, leaving the open panel nowhere to draw")
    }

    /// The Remote Co-Op panel's per-guest quality dropdown, which is the case reported with the AUDIO
    /// one: it sits in the coop section with the sections below it to be painted over.
    @Test @MainActor func theCoOpQualityDropdownRendersOverTheSectionBeneathIt() throws {
        let model = seededModel()
        model.remoteCoOpPreferences.isEnabled = true
        let participant = OPNRemoteCoOpParticipant(displayName: "Guest", role: .guest, connectionState: .connected)
        model.remoteCoOpSnapshot = OPNRemoteCoOpHostSnapshot(preferences: model.remoteCoOpPreferences, invite: nil, participants: [participant])
        let qualityDropdownID = NativeNVSTHostViewModel.remoteCoOpQualityDropdownPrefix + participant.id.uuidString
        model.hudFocusID = qualityDropdownID
        model.openHUDDropdownID = qualityDropdownID
        model.hudDropdownHighlightedItemID = "720p 60 FPS"

        let content = VStack(alignment: .leading, spacing: 8) {
            section("REMOTE CO-OP") {
                row("Guest", "P1")
                StreamHUDDropdown(
                    label: "Guest quality",
                    rows: model.padDropdownItems(qualityDropdownID),
                    selection: "session-default",
                    isDisabled: false,
                    isFocused: true,
                    // Over the row count on purpose: `ImageRenderer` draws a `ScrollView`'s frame but
                    // not its content offscreen, and this snapshot is about the panel's fill and lift.
                    visibleItemCount: 12,
                    padDriver: model.padDropdown(dropdownID: qualityDropdownID)
                )
            }
            section("UPSCALING") { row("Upscaling", "MetalFX") }
        }
        let image = try render(content, name: "hud-coop-dropdown-open.png")
        #expect(image.size.height > 400, "the section stack collapsed, leaving the open panel nowhere to draw")
    }

    @MainActor
    private func section<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        StreamHUDSection(label: label, isCollapsed: false, isFocused: false, reorderPayload: nil, onToggle: {}) {
            VStack(alignment: .leading, spacing: 8) { content() }
        }
    }

    @MainActor
    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.streamFont(size: 11, weight: .medium))
                .foregroundStyle(StreamHUDTheme.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.streamFont(size: 12, weight: .bold))
                .foregroundStyle(StreamHUDTheme.textPrimary)
        }
    }
}
