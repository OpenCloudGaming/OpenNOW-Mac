import SwiftUI

struct ScreenshotEditorView: View {
    @Bindable var model: ScreenshotEditorViewModel
    let onCancel: () -> Void
    let onSave: () -> Void

    @Environment(\.opnUIScale) private var uiScale
    @State private var loadAttempt = 0

    var body: some View {
        VStack(spacing: 0) {
            header
                .zIndex(1)
            canvas
                .padding(20 * uiScale)
            Text("Drag to select · Arrow keys to move · Option + arrows to resize · Shift for 10 px")
                .font(.opnUI(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22 * uiScale)
                .padding(.bottom, 16 * uiScale)
        }
        .background(OPNDesign.Surface.panel)
        .task(id: loadAttempt) { await model.load() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screenshot editor, beta")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12 * uiScale) {
            HStack(spacing: 8 * uiScale) {
                Text("QUICK EDIT")
                    .font(.opnUI(size: 10 * uiScale, weight: .bold))
                    .tracking(1.4 * uiScale)
                    .foregroundStyle(OPNDesign.accentInk)
                    .fixedSize()
                OPNBetaTag(uiScale: uiScale, prominent: true)
                Text(model.screenshot.title)
                    .font(.opnUI(size: 13 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
            }
            SettingsFlowLayout(spacing: 8 * uiScale) {
                selectionMenu
                Button { model.applyCrop() } label: { Label("Crop", systemImage: "crop") }
                    .disabled(!model.canCrop)
                    .help("Crop to the selected area (Return)")
                    .keyboardShortcut(.return, modifiers: [])
                Button("Undo", action: model.undo)
                    .disabled(!model.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo", action: model.redo)
                    .disabled(!model.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Button("Reset", action: model.reset)
                    .disabled(!model.canReset)
                    .help("Return to the full screenshot")
                Button("Cancel", action: onCancel)
                    .disabled(model.isSaving)
                    .keyboardShortcut(.cancelAction)
                Button(model.isSaving ? "Saving…" : "Save as New Screenshot", action: onSave)
                    .buttonStyle(ScreenshotEditorButtonStyle(tone: .primary))
                    .disabled(!model.canSave)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .buttonStyle(ScreenshotEditorButtonStyle(tone: .secondary))
            .zIndex(1)
            Text(statusMessage)
                .font(.opnUI(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(model.errorMessage == nil ? OPNDesign.Text.secondary : OPNDesign.Semantic.destructive)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22 * uiScale)
        .padding(.vertical, 16 * uiScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OPNDesign.Surface.deep)
        .overlay(alignment: .bottom) { Rectangle().fill(OPNDesign.Stroke.subtle).frame(height: 1) }
        .background {
            Button("Select All", action: model.selectAll)
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!model.isReady)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var selectionMenu: some View {
        OPNDropdownMenu(items: selectionItems, isDisabled: !model.isReady) {
            HStack(spacing: 6 * uiScale) {
                Image(systemName: "rectangle.dashed")
                Text("Select")
                Image(systemName: "chevron.down")
            }
            .font(.opnUI(size: 11 * uiScale, weight: .bold))
            .foregroundStyle(OPNDesign.Text.primary)
            .padding(.horizontal, 11 * uiScale)
            .frame(height: RecordingActionButtonStyle.height * uiScale)
            .background(OPNDesign.Fill.neutral(0.08))
            .overlay { Rectangle().strokeBorder(OPNDesign.Stroke.regular, lineWidth: 1) }
            .opacity(model.isReady ? 1 : 0.45)
        }
        .help("Drag on the screenshot, or select the whole image (⌘A)")
    }

    private var selectionItems: [OPNDropdownItem] {
        var items = [OPNDropdownItem(id: "all", title: "Select All", action: model.selectAll)]
        if model.selection != nil {
            items.append(OPNDropdownItem(id: "clear", title: "Clear Selection", action: model.clearSelection))
        }
        return items
    }

    private var statusMessage: String {
        if let error = model.errorMessage { return error }
        if model.isLoading { return "Loading screenshot…" }
        if model.isSaving { return "Saving \(model.dimensionsDescription) as a new screenshot…" }
        if model.selection != nil { return "Selection: \(model.dimensionsDescription). Apply Crop to use this area." }
        return "\(model.dimensionsDescription) · Drag on the image to select an area."
    }

    private var canvas: some View {
        ZStack {
            Color.black
            if let image = model.previewImage {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .overlay { ScreenshotSelectionOverlay(model: model) }
            }
            if model.isLoading {
                ProgressView("Loading screenshot…")
                    .font(.opnUI(size: 12 * uiScale, weight: .medium))
                    .tint(OPNDesign.accent)
            }
            if model.previewImage == nil, !model.isLoading, model.errorMessage != nil {
                Button("Retry") { loadAttempt += 1 }
                    .buttonStyle(ScreenshotEditorButtonStyle(tone: .secondary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private struct ScreenshotEditorButtonStyle: ButtonStyle {
    let tone: RecordingActionButtonStyle.Tone
    @Environment(\.opnUIScale) private var uiScale
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        RecordingActionButtonStyle(tone: tone, uiScale: uiScale)
            .makeBody(configuration: configuration)
            .opacity(isEnabled ? 1 : 0.45)
    }
}
