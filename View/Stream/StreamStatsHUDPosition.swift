//  Pins the floating statistics overlay to one of the stream surface's four corners. A leading
//  corner sits behind the unified sidebar, so the overlay steps clear of the dock while it is open
//  and rides the dock's own motion back into place when it closes.
//

import SwiftUI

extension StreamStatsHUDPosition {
    /// Where the panel is pinned inside the stream surface.
    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    /// The corner the panel unfolds from as it appears, so the transition travels with the corner
    /// it is anchored to rather than always from the top-trailing edge.
    var transitionAnchor: UnitPoint {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }
}

struct StreamStatsHUDPositionModifier: ViewModifier {
    let position: StreamStatsHUDPosition
    let isSidebarVisible: Bool

    /// The margin the panel keeps from the window edge, on every side.
    private let edgeInset: CGFloat = OPNDesign.Spacing.small
    /// A bottom-trailing panel sits above the circular microphone toggle instead of under it: the
    /// toggle occupies a 28pt square inset 24pt from the corner, and `edgeInset` is the gap above it.
    private let microphoneToggleClearance: CGFloat = 24 + 28

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let sidebarShift = position.isLeading && isSidebarVisible
                ? StreamHUDTheme.dockWidth(for: proxy.size.width)
                : 0
            content
                .padding(edgeInset)
                .padding(.bottom, position == .bottomTrailing ? microphoneToggleClearance : 0)
                .padding(.leading, sidebarShift)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: position.alignment)
                .opnMotion(OPNDesign.Motion.panel, value: isSidebarVisible)
        }
    }
}

extension View {
    func streamStatsHUDPosition(_ position: StreamStatsHUDPosition, isSidebarVisible: Bool) -> some View {
        modifier(StreamStatsHUDPositionModifier(position: position, isSidebarVisible: isSidebarVisible))
    }
}

extension StreamStatsDetailLevel {
    /// The square dropdown speaks in `Int` values; a case's index in `allCases` is its stable
    /// identity, and `allCases` order is the declaration order every selector draws.
    var pickerValue: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    static func pickerCase(at value: Int) -> StreamStatsDetailLevel {
        guard allCases.indices.contains(value) else { return OPNStreamStatsHUDSettings.defaultDetailLevel }
        return allCases[value]
    }
}

extension StreamStatsHUDPosition {
    var pickerValue: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    static func pickerCase(at value: Int) -> StreamStatsHUDPosition {
        guard allCases.indices.contains(value) else { return OPNStreamStatsHUDSettings.defaultPosition }
        return allCases[value]
    }
}
