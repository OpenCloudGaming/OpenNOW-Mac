import SwiftUI

/// Tooltip geometry in points at interface scale 1; multiply by `uiScale` at the call site.
enum OPNTooltipMetrics {
    static let caretWidth: CGFloat = 12
    static let caretHeight: CGFloat = 5
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 5
    static let textSize: CGFloat = 11
    static let pointerGap: CGFloat = 6
    static let strokeWidth: CGFloat = 1
}

/// Drops the app-shell balloon below a control while the pointer rests on it, replacing the system
/// `.help` bubble whose rounded chrome clashes with the app-shell's square, stroked plates.
private struct OPNTooltipModifier: ViewModifier {
    let text: String
    @Environment(\.opnUIScale) private var uiScale
    @State private var isHovering = false
    /// Measured, not assumed: controls this rides on differ in height, and an assumed value leaves
    /// the balloon sitting over the icon.
    @State private var controlHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background { controlHeightReader }
            .onHover { isHovering = $0 }
            .overlay(alignment: .top) {
                if isHovering, !text.isEmpty {
                    balloon
                }
            }
            .opnMotion(OPNDesign.Motion.hover, value: isHovering)
    }

    /// Top-anchored, then pushed past the control: anchoring to the bottom edge kept the balloon
    /// inside the frame, over the icon.
    private var balloon: some View {
        OPNTooltipBalloon(text: text, uiScale: uiScale)
            .offset(y: controlHeight + OPNTooltipMetrics.pointerGap * uiScale)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private var controlHeightReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { controlHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { _, height in controlHeight = height }
        }
    }
}

private struct OPNTooltipBalloon: View {
    let text: String
    let uiScale: CGFloat

    var body: some View {
        Text(text)
            .font(.opnUI(size: OPNTooltipMetrics.textSize * uiScale, weight: .bold))
            .foregroundStyle(OPNDesign.Text.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, OPNTooltipMetrics.horizontalPadding * uiScale)
            .padding(.vertical, OPNTooltipMetrics.verticalPadding * uiScale)
            .padding(.top, OPNTooltipMetrics.caretHeight * uiScale)
            .background(bubbleShape.fill(OPNDesign.Surface.panelRaised))
            .overlay { bubbleShape.stroke(OPNDesign.Stroke.regular, lineWidth: OPNTooltipMetrics.strokeWidth) }
            .accessibilityHidden(true)
    }

    private var bubbleShape: OPNTooltipBubbleShape {
        OPNTooltipBubbleShape(
            caretWidth: OPNTooltipMetrics.caretWidth * uiScale,
            caretHeight: OPNTooltipMetrics.caretHeight * uiScale
        )
    }
}

/// A rectangle whose top edge rises into one centred caret, so a single border traces the point.
private struct OPNTooltipBubbleShape: Shape {
    let caretWidth: CGFloat
    let caretHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let halfCaretWidth = min(caretWidth, rect.width) / 2
        let bodyTop = rect.minY + caretHeight
        let caretTipX = rect.midX
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: bodyTop))
        path.addLine(to: CGPoint(x: caretTipX - halfCaretWidth, y: bodyTop))
        path.addLine(to: CGPoint(x: caretTipX, y: rect.minY))
        path.addLine(to: CGPoint(x: caretTipX + halfCaretWidth, y: bodyTop))
        path.addLine(to: CGPoint(x: rect.maxX, y: bodyTop))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

extension View {
    /// Presents the app-shell balloon tooltip below this control on hover.
    func opnTooltip(_ text: String) -> some View {
        modifier(OPNTooltipModifier(text: text))
    }
}
