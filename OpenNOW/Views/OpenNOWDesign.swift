import SwiftUI

enum OpenNOWDesign {
    enum Surface {
        static let app = Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255)
        static let appBar = Color(red: 45 / 255, green: 45 / 255, blue: 45 / 255)
        static let panel = Color(red: 28 / 255, green: 28 / 255, blue: 28 / 255)
        static let panelRaised = Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255)
        static let tileTray = Color(red: 41 / 255, green: 41 / 255, blue: 41 / 255)
        static let field = Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255)
        static let scrim = Color.black.opacity(0.58)
    }

    enum Text {
        static let primary = Color.white.opacity(0.96)
        static let secondary = Color.white.opacity(0.72)
        static let tertiary = Color.white.opacity(0.52)
        static let muted = Color.white.opacity(0.38)
    }

    enum Stroke {
        static let subtle = Color.white.opacity(0.10)
        static let regular = Color.white.opacity(0.14)
        static let strong = Color.white.opacity(0.22)
    }

    enum Spacing {
        static let pageHorizontal: CGFloat = 40
        static let railHorizontal: CGFloat = 32
        static let card: CGFloat = 18
    }

    enum Radius {
        static let avatar: CGFloat = 14
    }

    static let accent = Color.openNowGreen

    static func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}

extension View {
    func openNowFocusRing(_ isFocused: Bool) -> some View {
        overlay {
            Rectangle()
                .stroke(isFocused ? Color.openNowGreen : .clear, lineWidth: 2)
        }
    }
}
