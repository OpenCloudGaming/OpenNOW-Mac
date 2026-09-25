import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    var nativeHUDCustomizeOverlay: some View {
        ZStack {
            StreamHUDTheme.scrim
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                .onTapGesture { model.setHUDCustomizeVisible(false) }
            nativeHUDCustomizePanel
        }
    }

    private var nativeHUDCustomizePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("HUD LAYOUT")
                    .font(.streamFont(size: 10, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(StreamHUDTheme.accent)
                Text("Sections")
                    .font(.streamFont(size: 20, weight: .bold))
                    .foregroundStyle(StreamHUDTheme.textPrimary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StreamHUDTheme.appBar)
            Rectangle().fill(StreamHUDTheme.divider).frame(height: 1)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.hudSectionOrder, id: \.self) { section in
                        nativeHUDCustomizeRow(title: section.title, subtitle: nil, isVisible: !model.isHUDSectionHidden(section)) {
                            model.toggleHUDSectionHidden(section)
                        }
                        Rectangle().fill(StreamHUDTheme.divider).frame(height: 1)
                    }
                    nativeHUDCustomizeRow(title: "CLOCK", subtitle: "Live time in the dock footer", isVisible: model.isHUDClockVisible) {
                        model.toggleHUDClock()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 360)
            Rectangle().fill(StreamHUDTheme.divider).frame(height: 1)
            HStack(spacing: 12) {
                Button { model.resetHUDLayout() } label: {
                    Text("Reset layout")
                        .font(.streamFont(size: 11, weight: .bold))
                        .foregroundStyle(model.hasCustomHUDLayout ? StreamHUDTheme.textSecondary : StreamHUDTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(!model.hasCustomHUDLayout)
                Spacer(minLength: 0)
                Button { model.setHUDCustomizeVisible(false) } label: {
                    Text("Done")
                        .font(.streamFont(size: 11, weight: .bold))
                        .foregroundStyle(.black.opacity(0.86))
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(StreamHUDTheme.accent)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(width: 460)
        .background(StreamHUDTheme.panel.opacity(0.985))
        .overlay { Rectangle().stroke(StreamHUDTheme.accent.opacity(0.28), lineWidth: 1) }
        .overlay(alignment: .top) { Rectangle().fill(StreamHUDTheme.accent).frame(height: 2) }
        .shadow(color: .black.opacity(0.58), radius: 28, x: 0, y: 20)
    }

    private func nativeHUDCustomizeRow(title: String, subtitle: String?, isVisible: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.streamFont(size: 12, weight: .bold))
                    .foregroundStyle(StreamHUDTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.streamFont(size: 10, weight: .medium))
                        .foregroundStyle(StreamHUDTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(action: action) {
                Image(systemName: isVisible ? "eye" : "eye.slash")
                    .font(.streamFont(size: 12, weight: .bold))
                    .foregroundStyle(isVisible ? StreamHUDTheme.accent : StreamHUDTheme.textTertiary)
                    .frame(width: 30, height: 26)
                    .background(Color.white.opacity(0.07))
                    .overlay { Rectangle().stroke(StreamHUDTheme.divider, lineWidth: 1) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVisible ? "Hide \(title)" : "Show \(title)")
        }
        .padding(.vertical, 9)
    }
}
