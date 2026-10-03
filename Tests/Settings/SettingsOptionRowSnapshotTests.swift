import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// Renders `SettingsOptionRow`s inside their cards so the row can be looked at without a running
/// app. The thing to guard is visual: a row is just its title and chips, never a description line.
@Suite struct SettingsOptionRowSnapshotTests {
    @MainActor
    private func row(width: CGFloat, scale: CGFloat, subtitle: String, isNew: Bool = false) -> some View {
        SettingsCard(title: "Session Ready", uiScale: scale) {
            SettingsOptionRow(
                title: "When the Stream Is Ready",
                subtitle: subtitle,
                options: ["Off", "Notification", "Bring to Front", "Full Screen"],
                selectedIndex: 1,
                isNew: isNew,
                uiScale: scale
            ) { _ in }
        }
        .frame(width: width, alignment: .leading)
        .background(OPNDesign.Surface.panel)
        .environment(\.opnSettingsNarrowRows, false)
    }

    private static let longSubtitle = "While OpenNOW is in the background and a queued or provisioning session becomes ready: post a system notification, bring OpenNOW to the front automatically, bring it forward and put the stream in full screen, or do nothing."

    @MainActor
    private func appearanceCard(width: CGFloat, scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16 * scale) {
            SettingsCard(title: "Appearance", uiScale: scale) {
                SettingsOptionRow(
                    title: "Appearance",
                    subtitle: "Dark, light, or follow the macOS setting. The in-stream HUD and the sign-in screen stay dark either way.",
                    options: ["Match System", "Dark", "Light"],
                    selectedIndex: 1,
                    uiScale: scale
                ) { _ in }
            }
            SettingsCard(title: "Accent Colour", uiScale: scale) {
                SettingsOptionRow(
                    title: "Accent Colour",
                    subtitle: "The highlight colour used across buttons, selection, and focus throughout the app.",
                    options: ["Cloud Green", "Sky", "Violet", "Magenta", "Amber", "Coral"],
                    selectedIndex: 0,
                    swatchColors: [.green, .blue, .purple, .pink, .orange, .red],
                    uiScale: scale
                ) { _ in }
            }
        }
        .frame(width: width, alignment: .leading)
        .background(OPNDesign.Surface.panel)
        .environment(\.opnSettingsNarrowRows, false)
    }

    @MainActor
    private func shortRowsCard(width: CGFloat, scale: CGFloat) -> some View {
        SettingsCard(title: "Video", uiScale: scale) {
            SettingsOptionRow(
                title: "Aspect Ratio",
                subtitle: "Controls the available resolution list.",
                options: ["16:9", "16:10", "21:9"],
                selectedIndex: 0,
                uiScale: scale
            ) { _ in }
            SettingsDivider(uiScale: scale)
            SettingsOptionRow(
                title: "Frame Rate",
                subtitle: "Limited by the active display refresh rate.",
                options: ["30", "60", "120"],
                selectedIndex: 1,
                uiScale: scale
            ) { _ in }
        }
        .frame(width: width, alignment: .leading)
        .background(OPNDesign.Surface.panel)
        .environment(\.opnSettingsNarrowRows, false)
    }

    @MainActor
    private func windowRowsCard(width: CGFloat, scale: CGFloat) -> some View {
        SettingsCard(title: "Window & Menu Bar", uiScale: scale) {
            SettingsOptionRow(
                title: "When the Last Window Closes",
                subtitle: "What the close button does with the last window. Quit on Close ends the app with its window. Close, Keep Dock Icon leaves OpenNOW running with its Dock icon and no window, so the Dock brings it back. Close, Menu Bar Only hides the Dock icon and leaves only the menu bar item. Either way the window is hidden, not torn down, so a queue or stream in flight keeps running.",
                options: ["Quit", "Keep Dock Icon", "Menu Bar Only"],
                selectedIndex: 1,
                uiScale: scale
            ) { _ in }
            SettingsDivider(uiScale: scale)
            SettingsOptionRow(
                title: "At Launch, Show",
                subtitle: "Open the main window, or start with only the menu bar item and no window. Opening the window later is always one click away in the menu bar.",
                options: ["Main Window", "Menu Bar Only"],
                selectedIndex: 0,
                uiScale: scale
            ) { _ in }
        }
        .frame(width: width, alignment: .leading)
        .background(OPNDesign.Surface.panel)
        .environment(\.opnSettingsNarrowRows, false)
    }

    @MainActor
    private func toggleAndFieldCard(width: CGFloat, scale: CGFloat) -> some View {
        SettingsCard(title: "Input", uiScale: scale) {
            SettingsToggleRow(
                title: "Raw Mouse Input",
                subtitle: "Aim with unaccelerated HID deltas in relative mode instead of the pointer macOS has already accelerated.",
                isOn: true,
                isNew: true,
                uiScale: scale
            ) { _ in }
            SettingsDivider(uiScale: scale)
            SettingsTextFieldRow(
                title: "Relay URL",
                subtitle: "HTTPS address a tunnel exposes this Mac on.",
                text: "https://relay.example.com",
                placeholder: "https://…",
                uiScale: scale
            ) { _ in }
        }
        .frame(width: width, alignment: .leading)
        .background(OPNDesign.Surface.panel)
        .environment(\.opnSettingsNarrowRows, false)
    }

    @Test @MainActor func theOptionRowRenders() throws {
        let helpStrip = ImageRenderer(content: SettingsFocusedHelpStrip(
            text: Self.longSubtitle,
            uiScale: 1.0
        )
        .frame(width: 1200, alignment: .leading)
        .background(OPNDesign.Surface.panel))
        helpStrip.scale = 2
        let helpImage = try #require(helpStrip.nsImage, "no help-strip render")
        writeSnapshot(helpImage, name: "settings-focused-help-strip.png")
        for width in [1360, 1000, 760] {
            let renderer = ImageRenderer(content: row(width: CGFloat(width), scale: 1.0, subtitle: Self.longSubtitle))
            renderer.scale = 2
            let image = try #require(renderer.nsImage, "no render at width \(width)")
            #expect(image.size.width > 0)
            writeSnapshot(image, name: "settings-option-row-w\(width).png")
        }
        for scale in [1.25, 1.5] {
            let renderer = ImageRenderer(content: row(width: 1360 * scale, scale: scale, subtitle: Self.longSubtitle))
            renderer.scale = 2
            let image = try #require(renderer.nsImage, "no render at scale \(scale)")
            #expect(image.size.width > 0)
            writeSnapshot(image, name: "settings-option-row-s\(scale).png")
        }
        let shortRenderer = ImageRenderer(content: shortRowsCard(width: 1360, scale: 1.0))
        shortRenderer.scale = 2
        let shortImage = try #require(shortRenderer.nsImage, "no short-row render")
        writeSnapshot(shortImage, name: "settings-option-row-short.png")

        let appearanceRenderer = ImageRenderer(content: appearanceCard(width: 1360, scale: 1.0))
        appearanceRenderer.scale = 2
        let appearanceImage = try #require(appearanceRenderer.nsImage, "no appearance render")
        writeSnapshot(appearanceImage, name: "settings-option-row-appearance.png")

        let windowRenderer = ImageRenderer(content: windowRowsCard(width: 1360, scale: 1.0))
        windowRenderer.scale = 2
        let windowImage = try #require(windowRenderer.nsImage, "no window-row render")
        writeSnapshot(windowImage, name: "settings-option-row-window.png")

        let newRenderer = ImageRenderer(content: row(width: 1360, scale: 1.0, subtitle: Self.longSubtitle, isNew: true))
        newRenderer.scale = 2
        let newImage = try #require(newRenderer.nsImage, "no NEW-tag render")
        writeSnapshot(newImage, name: "settings-option-row-new.png")

        let toggleRenderer = ImageRenderer(content: toggleAndFieldCard(width: 1360, scale: 1.0))
        toggleRenderer.scale = 2
        let toggleImage = try #require(toggleRenderer.nsImage, "no toggle/field render")
        writeSnapshot(toggleImage, name: "settings-option-row-toggle-field.png")
    }

    /// The description is a tooltip, so it must not add a line: two rows differing only in
    /// description length render to the same height. An inline description fails this.
    @Test @MainActor func theDescriptionIsNotDrawnInline() throws {
        let long = try #require(ImageRenderer(content: row(width: 1360, scale: 1.0, subtitle: Self.longSubtitle)).nsImage)
        let short = try #require(ImageRenderer(content: row(width: 1360, scale: 1.0, subtitle: "Controls the available resolution list.")).nsImage)
        #expect(long.size.height == short.size.height, "the description is drawn inline again")
    }

    @MainActor
    private func writeSnapshot(_ image: NSImage, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"],
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
