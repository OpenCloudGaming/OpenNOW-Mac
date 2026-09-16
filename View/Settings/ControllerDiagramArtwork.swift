import SwiftUI

/// Shared artwork constants for the three controller diagrams (`SteamControllerDiagramView`,
/// `DualShock4DiagramView`, and `GenericControllerDiagramView`). Every shell is authored in the
/// same 456×320 space, rendered at the same reference width, and inked with the fixed hardware
/// palette from `OPNDesign.Fixed`, so the diagrams line up wherever they are swapped for one
/// another.
enum ControllerDiagramArtwork {
    /// The authoring space the shell assets and every live overlay are drawn in.
    static let artSize = CGSize(width: 456, height: 320)

    /// Unscaled reference width. The rendered diagram is this times the interface scale, so the
    /// hardware grows with the chrome around it instead of shrinking as the panel widens.
    static let diagramWidth: CGFloat = 560
    static let shoulderHeight: CGFloat = 54
    static let sectionSpacing: CGFloat = 6
    static var diagramSize: CGSize {
        CGSize(width: diagramWidth, height: shoulderHeight + sectionSpacing + artSize.height * diagramWidth / artSize.width)
    }

    static func fittedScale(in size: CGSize, maximumScale: CGFloat) -> CGFloat {
        guard size.width > 0, size.height > 0, maximumScale > 0 else { return 0 }
        return min(maximumScale, size.width / diagramSize.width, size.height / diagramSize.height)
    }

    /// The shell palette: matte black plastic under a fixed grey outline, the same in every
    /// appearance because the hardware is.
    static let shellFill = OPNDesign.Fixed.controllerShell
    static let shellStroke = OPNDesign.Fixed.controllerShellStroke

    /// Everything drawn *on* the shell (buttons, sticks, pads, grips) needs the same fixed
    /// white-on-dark ink the shell itself uses - `OPNDesign.Fill`/`Stroke`/`Text` wash the other way
    /// in light mode and nearly vanish against the fixed-dark plastic.
    enum Overlay {
        static func fill(_ opacity: Double) -> Color { Color.white.opacity(opacity) }
        static let strokeSubtle = Color.white.opacity(0.10)
        static let strokeRegular = Color.white.opacity(0.14)
        static let strokeStrong = Color.white.opacity(0.22)
        static let textTertiary = Color.white.opacity(0.52)
        static let textMuted = Color.white.opacity(0.38)
    }
}
