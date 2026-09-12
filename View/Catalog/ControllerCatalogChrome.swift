//  Controller-mode chrome: overlay headers, metadata pills, the hint bar and its glyphs, the
//  artwork backdrop and the keyboard input bridge.
//

import AppKit
import SwiftUI

struct ControllerOverlayHeader: View {
    let title: String
    let subtitle: String
    let glyphs: ControllerInputGlyphSet
    let close: () -> Void

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(alignment: .top, spacing: 16 * uiScale) {
            VStack(alignment: .leading, spacing: 6 * uiScale) {
                Text(title.uppercased())
                    .catalogFont(size: 27, weight: .bold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .catalogFont(size: 14, weight: .medium)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8 * uiScale) {
                ControllerGlyphPill(glyph: glyphs.back)
                Text("BACK")
                    .catalogFont(size: 11, weight: .bold)
                    .foregroundStyle(.white.opacity(0.62))
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .catalogFont(size: 16, weight: .bold)
                    .foregroundStyle(.white.opacity(0.80))
                    .frame(width: 38 * uiScale, height: 38 * uiScale)
                    .background(Color.white.opacity(0.08))
                    .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
            }
            .buttonStyle(.plain)
        }
    }
}

struct ControllerOverlaySectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .catalogFont(size: 12, weight: .bold)
            .tracking(1.1)
            .foregroundStyle(OpenNOWDesign.accent.opacity(0.86))
    }
}

struct ControllerMetadataPill: View {
    let text: String
    var highlighted = false

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        Text(text.uppercased())
            .catalogFont(size: 11, weight: .bold)
            .tracking(0.7)
            .foregroundStyle(highlighted ? .black.opacity(0.88) : .white.opacity(0.82))
            .padding(.horizontal, 10 * uiScale)
            .frame(height: 28 * uiScale)
            .background(highlighted ? OpenNOWDesign.accent : Color.white.opacity(0.075))
            .overlay { Rectangle().stroke(highlighted ? OpenNOWDesign.accent : OpenNOWDesign.Stroke.regular, lineWidth: 1) }
    }
}

enum ControllerHint: Equatable {
    case move
    case select
    case back
    case search
    case showAll
    case menu
    case clear
    case page
    case more
    /// Shown only while an `.account` row is focused in the controller actions menu, naming the
    /// secondary button that opens that account's Sign Out / Forget overlay.
    case accountOptions
}

struct ControllerHintBar: View {
    let hints: [ControllerHint]
    let glyphs: ControllerInputGlyphSet
    let layout: ControllerLayoutMetrics

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(spacing: 14 * uiScale) {
            ForEach(hints, id: \.self) { hint in
                ControllerHintItem(hint: hint, glyphs: glyphs)
            }
            Spacer(minLength: 0)
            Text(glyphs.usesControllerGlyphs ? "Controller mode" : "Keyboard fallback")
                .catalogFont(size: 11, weight: .bold)
                .foregroundStyle(.white.opacity(0.38))
                .tracking(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(width: layout.contentWidth, alignment: .leading)
        .frame(height: 46 * uiScale)
        .background(Color.black.opacity(0.36))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }
}

struct ControllerHintItem: View {
    let hint: ControllerHint
    let glyphs: ControllerInputGlyphSet

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(spacing: 6 * uiScale) {
            if hint == .move, !glyphs.usesControllerGlyphs {
                ControllerKeyboardMovePill(glyphs: glyphs)
            } else {
                ForEach(Array(glyphSet.enumerated()), id: \.offset) { _, glyph in
                    ControllerGlyphPill(glyph: glyph, compact: hint == .move)
                }
            }
            Text(title)
                .catalogFont(size: 10, weight: .bold)
                .foregroundStyle(.white.opacity(0.64))
                .tracking(0.5)
        }
    }

    private var glyphSet: [ControllerInputGlyph] {
        switch hint {
        case .move: return [glyphs.left, glyphs.up, glyphs.down, glyphs.right]
        case .select: return [glyphs.confirm]
        case .back: return [glyphs.back]
        case .search: return [glyphs.search]
        case .showAll: return [glyphs.actions]
        case .menu: return [glyphs.menu]
        case .clear: return [glyphs.actions]
        case .page: return [glyphs.pageLeft, glyphs.pageRight]
        case .more: return [glyphs.actions]
        case .accountOptions: return [glyphs.search]
        }
    }

    private var title: String {
        switch hint {
        case .move: return "MOVE"
        case .select: return "SELECT"
        case .back: return "BACK"
        case .search: return "SEARCH"
        case .showAll: return "SHOW ALL"
        case .menu: return "MENU"
        case .clear: return "CLEAR"
        case .page: return "PAGE"
        case .more: return "MORE"
        case .accountOptions: return "OPTIONS"
        }
    }
}

struct ControllerGlyphPill: View {
    let glyph: ControllerInputGlyph
    var compact = false

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(spacing: (compact ? 0 : 5) * uiScale) {
            if !glyph.symbolName.isEmpty {
                Image(systemName: glyph.symbolName)
                    .catalogFont(size: compact ? 11 : 12, weight: .bold)
            }
            if shouldShowText {
                Text(glyph.fallbackText)
                    .catalogFont(size: compact ? 0 : 9, weight: .bold)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(OpenNOWDesign.accent)
        .padding(.horizontal, (compact ? 6 : 7) * uiScale)
        .frame(minWidth: (compact ? 25 : 0) * uiScale)
        .frame(height: 22 * uiScale)
        .background(OpenNOWDesign.accent.opacity(0.12))
        .overlay { Rectangle().stroke(OpenNOWDesign.accent.opacity(0.30), lineWidth: 1) }
        .accessibilityLabel(glyph.accessibilityLabel)
    }

    private var shouldShowText: Bool {
        guard !compact else { return false }
        guard !["↑", "↓", "←", "→"].contains(glyph.fallbackText) else { return false }
        return true
    }
}

struct ControllerKeyboardMovePill: View {
    let glyphs: ControllerInputGlyphSet

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(spacing: 5 * uiScale) {
            Image(systemName: glyphs.left.symbolName)
            Image(systemName: glyphs.up.symbolName)
            Image(systemName: glyphs.down.symbolName)
            Image(systemName: glyphs.right.symbolName)
        }
        .catalogFont(size: 11, weight: .bold)
        .foregroundStyle(OpenNOWDesign.accent)
        .padding(.horizontal, 8 * uiScale)
        .frame(height: 22 * uiScale)
        .background(OpenNOWDesign.accent.opacity(0.12))
        .overlay { Rectangle().stroke(OpenNOWDesign.accent.opacity(0.30), lineWidth: 1) }
        .accessibilityLabel("Arrow keys")
    }
}

struct ControllerCatalogBackground: View {
    let viewModel: CatalogViewModel
    let game: OPNCatalogGameObject?

    var body: some View {
        ZStack {
            OpenNOWDesign.Surface.app.ignoresSafeArea()
            if let game {
                CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestDetailImageURL, width: 1280), contentMode: .fill, maxPixelSize: 1280)
                    .ignoresSafeArea()
                    .blur(radius: 44)
                    .opacity(0.26)
            }
            LinearGradient(colors: [.black.opacity(0.84), .black.opacity(0.38), .black.opacity(0.82)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }
}

struct ControllerKeyboardInputBridge: NSViewRepresentable {
    let onCommand: (ControllerInputCommand) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommand: onCommand)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.installMonitor()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCommand = onCommand
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var onCommand: (ControllerInputCommand) -> Void
        private var monitor: Any?

        init(onCommand: @escaping (ControllerInputCommand) -> Void) {
            self.onCommand = onCommand
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard let command = Self.command(for: event) else { return event }
                if MainActor.assumeIsolated({ Self.isTextInputActive }) {
                    // A focused field owns the keyboard: letters are text, and left/right are
                    // caret moves inside the query. Up and down stay navigation so the row can
                    // still be left without reaching for a pad.
                    guard case .move(let direction) = command, direction == .up || direction == .down else {
                        return event
                    }
                }
                self.onCommand(command)
                return nil
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        /// Only an actually-editable responder counts. This used to also match on the responder's
        /// stringified type name containing "Text", which a SwiftUI hosting view's generic
        /// signature satisfies on its own — so every command except up/down was handed back to the
        /// responder chain and the arrows navigated nothing.
        @MainActor private static var isTextInputActive: Bool {
            guard let responder = NSApp.keyWindow?.firstResponder else { return false }
            if let textView = responder as? NSTextView { return textView.isEditable }
            return responder is NSTextField
        }

        private static func command(for event: NSEvent) -> ControllerInputCommand? {
            ControllerKeyboardCommandMap.command(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
        }
    }
}
