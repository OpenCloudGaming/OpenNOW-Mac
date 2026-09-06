import SwiftUI

/// Home's one statement that WebRTC is the legacy path.
///
/// The two transports are a single toggle buried in Settings, and nothing in the app said which
/// one is being invested in: a user on WebRTC simply finds that Remote Co-Op hosting, HDR, 4:4:4,
/// 120 fps, rumble and the cursor protocol are missing, one at a time, with no explanation. This
/// says it once, at the top of home, with the switch attached — and it is dismissible, because a
/// notice that cannot be silenced is an advertisement.
struct CatalogLegacyTransportNotice: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale
    @State private var isHoveringDismiss = false

    var body: some View {
        HStack(alignment: .top, spacing: 14 * uiScale) {
            ZStack {
                Rectangle()
                    .fill(OpenNOWDesign.accent.opacity(0.13))
                Image(systemName: "sparkles")
                    .catalogFont(size: 15, weight: .bold)
                    .foregroundStyle(OpenNOWDesign.accent)
            }
            .frame(width: 36 * uiScale, height: 36 * uiScale)
            .overlay { Rectangle().stroke(OpenNOWDesign.accent.opacity(0.30), lineWidth: 1) }

            VStack(alignment: .leading, spacing: 5 * uiScale) {
                HStack(spacing: 8 * uiScale) {
                    Text("You are streaming over WebRTC")
                        .catalogFont(size: 13, weight: .bold)
                        .foregroundStyle(.white.opacity(0.92))
                    Text("LEGACY")
                        .catalogFont(size: 9, weight: .bold)
                        .tracking(0.9)
                        .foregroundStyle(.black.opacity(0.88))
                        .padding(.horizontal, 6 * uiScale)
                        .frame(height: 16 * uiScale)
                        .background(OpenNOWDesign.accent)
                }
                Text("New work goes to the Native transport: Remote Co-Op hosting, HDR, 10-bit 4:4:4, 120 fps, controller rumble. WebRTC keeps streaming and keeps getting fixes, but no new features.")
                    .catalogFont(size: 12, weight: .medium)
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12 * uiScale)

            Button { viewModel.switchToNativeTransportFromNotice() } label: {
                Text("USE NATIVE")
                    .catalogFont(size: 11, weight: .bold)
                    .tracking(0.8)
                    .foregroundStyle(.black.opacity(0.88))
                    .padding(.horizontal, 14 * uiScale)
                    .frame(height: 30 * uiScale)
                    .background(OpenNOWDesign.accent)
            }
            .buttonStyle(.opnPressable(scale: 0.96))
            .accessibilityLabel("Switch to the Native transport")

            Button { viewModel.dismissLegacyTransportNotice() } label: {
                Image(systemName: "xmark")
                    .catalogFont(size: 10, weight: .bold)
                    .foregroundStyle(.white.opacity(isHoveringDismiss ? 0.92 : 0.60))
                    .frame(width: 30 * uiScale, height: 30 * uiScale)
                    .background(Color.white.opacity(isHoveringDismiss ? 0.12 : 0.065))
                    .overlay { Rectangle().stroke(Color.white.opacity(0.13), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .onHover { isHoveringDismiss = $0 }
            .accessibilityLabel("Dismiss")
            .help("Dismiss. Settings, Stream Transport, keeps the switch.")
        }
        .padding(14 * uiScale)
        .background(Color.white.opacity(0.060))
        .overlay(alignment: .leading) { Rectangle().fill(OpenNOWDesign.accent).frame(width: 3) }
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }
}
