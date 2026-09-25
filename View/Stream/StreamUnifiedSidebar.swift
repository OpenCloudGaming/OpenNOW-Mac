import Foundation
import SwiftUI

/// The unified HUD's leading dock: header (power, title, session time, close), the caller's section
/// stack, and a footer with the live clock and the Customize/Shortcuts entries.
struct StreamUnifiedSidebar<Content: View>: View {
    let title: String
    let closeAction: () -> Void
    let sessionLimit: StreamSessionSidebarLimit?
    let powerAction: (() -> Void)?
    let isPowerFocused: Bool
    let isClockVisible: Bool
    let customizeAction: (() -> Void)?
    let shortcutsHelpAction: (() -> Void)?
    let shortcutsHelpLabel: String?
    let content: Content

    init(
        title: String,
        closeAction: @escaping () -> Void,
        sessionLimit: StreamSessionSidebarLimit? = nil,
        powerAction: (() -> Void)? = nil,
        isPowerFocused: Bool = false,
        isClockVisible: Bool = true,
        customizeAction: (() -> Void)? = nil,
        shortcutsHelpAction: (() -> Void)? = nil,
        shortcutsHelpLabel: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.closeAction = closeAction
        self.sessionLimit = sessionLimit
        self.powerAction = powerAction
        self.isPowerFocused = isPowerFocused
        self.isClockVisible = isClockVisible
        self.customizeAction = customizeAction
        self.shortcutsHelpAction = shortcutsHelpAction
        self.shortcutsHelpLabel = shortcutsHelpLabel
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(StreamHUDTheme.divider).frame(height: 1)
                ScrollView(.vertical, showsIndicators: false) {
                    content
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                }
                Rectangle().fill(StreamHUDTheme.divider).frame(height: 1)
                footer
            }
            .frame(width: StreamHUDTheme.dockWidth(for: proxy.size.width), height: proxy.size.height, alignment: .topLeading)
            .background(StreamHUDTheme.panel.opacity(0.985))
            .overlay(alignment: .trailing) { Rectangle().fill(StreamHUDTheme.divider).frame(width: 1) }
            .overlay(alignment: .top) { Rectangle().fill(StreamHUDTheme.accent).frame(height: 2) }
            .shadow(color: .black.opacity(0.58), radius: 28, x: 14, y: 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let powerAction {
                sidebarIconButton(systemName: "power", label: "Stream menu", isFocused: isPowerFocused, action: powerAction)
            }
            // The game's name is what the dock is about, so it carries the weight; the eyebrow above
            // it says which panel this is, matching the stats panel's header.
            VStack(alignment: .leading, spacing: 1) {
                Text("STREAM HUD")
                    .font(.streamFont(size: 9, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(StreamHUDTheme.textTertiary)
                Text(title)
                    .font(.streamFont(size: 14, weight: .bold))
                    .foregroundStyle(StreamHUDTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let sessionLimit {
                sessionLimitPill(sessionLimit)
            }
            sidebarIconButton(systemName: "xmark", label: "Close stream HUD", isFocused: false, action: closeAction)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(StreamHUDTheme.appBar)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if isClockVisible { dockClock }
            Spacer(minLength: 0)
            footerActionButton(systemName: "slider.horizontal.3", title: "Customize", detail: nil, action: customizeAction)
            footerActionButton(systemName: "questionmark.circle", title: "Shortcuts", detail: shortcutsHelpLabel, action: shortcutsHelpAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var dockClock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(context.date, format: .dateTime.hour().minute())
                .font(.streamFont(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(StreamHUDTheme.textSecondary)
        }
        .accessibilityLabel("Current time")
    }

    /// The header's square icon buttons. The power button is the dock-wide stream action, out of
    /// INPUT where it never belonged.
    private func sidebarIconButton(systemName: String, label: String, isFocused: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.streamFont(size: 11, weight: .bold))
                .foregroundStyle(isFocused ? StreamHUDTheme.accent : .white.opacity(0.82))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(isFocused ? 0.14 : 0.08))
                .overlay { Rectangle().stroke(isFocused ? StreamHUDTheme.accent : Color.white.opacity(0.14), lineWidth: isFocused ? 2 : 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func footerActionButton(systemName: String, title: String, detail: String?, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.streamFont(size: 10, weight: .bold))
                Text(title)
                    .font(.streamFont(size: 10, weight: .bold))
                    .tracking(0.8)
                if let detail {
                    Text(detail)
                        .font(.streamFont(size: 10, weight: .bold).monospacedDigit())
                }
            }
            .foregroundStyle(StreamHUDTheme.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityLabel(title)
    }

    /// The remaining session time, moved up from the removed STATUS row so it stays visible even when
    /// every section is folded away.
    private func sessionLimitPill(_ limit: StreamSessionSidebarLimit) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let isHealthy = limit.isHealthy(at: context.date)
            HStack(spacing: 5) {
                Image(systemName: "timer")
                    .font(.streamFont(size: 9, weight: .bold))
                Text(limit.remainingTimeText(at: context.date))
                    .font(.streamFont(size: 11, weight: .bold).monospacedDigit())
            }
            .foregroundStyle(isHealthy ? StreamHUDTheme.accent : StreamHUDTheme.warning)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.white.opacity(0.08))
            .overlay { Rectangle().stroke(isHealthy ? StreamHUDTheme.divider : StreamHUDTheme.warning.opacity(0.5), lineWidth: 1) }
            .accessibilityLabel("Session time remaining \(limit.remainingTimeText(at: context.date))")
        }
    }
}
