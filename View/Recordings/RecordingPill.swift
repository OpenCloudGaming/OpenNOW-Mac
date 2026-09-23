//  One pill of recording facts: duration, quality, size. Shared by the library rows and the replay
//  rows, which is why it is not private to either page.
//

import SwiftUI

struct RecordingPill: View {
    let text: String
    let isActive: Bool
    let uiScale: CGFloat

    var body: some View {
        Text(text)
            .font(.recordingsFont(size: 9 * uiScale, weight: .bold))
            .foregroundStyle(isActive ? .black.opacity(0.86) : OPNDesign.Text.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7 * uiScale)
            .frame(height: 20 * uiScale)
            .background(isActive ? OPNDesign.accent : OPNDesign.Stroke.subtle)
            // `strokeBorder`, not `stroke`: an active pill strokes in its own fill colour, so the
            // centred stroke's half-point spill painted as extra pill.
            .overlay { Rectangle().strokeBorder(isActive ? OPNDesign.accent : OPNDesign.Stroke.subtle, lineWidth: 1) }
    }
}
