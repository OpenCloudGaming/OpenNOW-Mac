//
//  CatalogShowAllResizeViews.swift
//  MacForceNow
//

import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

enum CatalogShowAllWindowPreferences {
    private static let widthKey = "MacForceNow.catalog.showAllWindow.width"
    private static let heightKey = "MacForceNow.catalog.showAllWindow.height"

    static func loadSize() -> CGSize? {
        let width = UserDefaults.standard.double(forKey: widthKey)
        let height = UserDefaults.standard.double(forKey: heightKey)
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    static func saveSize(_ size: CGSize) {
        UserDefaults.standard.set(Double(size.width), forKey: widthKey)
        UserDefaults.standard.set(Double(size.height), forKey: heightKey)
    }
}

struct CatalogShowAllResizeZones<ResizeGesture: Gesture>: View {
    let resizeAction: (CatalogShowAllResizeEdge) -> ResizeGesture

    private let edgeThickness: CGFloat = 8
    private let cornerSize: CGFloat = 28

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                resizeZone(.top, height: edgeThickness)
                Spacer(minLength: 0)
                resizeZone(.bottom, height: edgeThickness)
            }
            HStack(spacing: 0) {
                resizeZone(.left, width: edgeThickness)
                Spacer(minLength: 0)
                resizeZone(.right, width: edgeThickness)
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    resizeZone(.topLeft, width: cornerSize, height: cornerSize)
                    Spacer(minLength: 0)
                    resizeZone(.topRight, width: cornerSize, height: cornerSize)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    resizeZone(.bottomLeft, width: cornerSize, height: cornerSize)
                    Spacer(minLength: 0)
                    ZStack(alignment: .bottomTrailing) {
                        resizeZone(.bottomRight, width: cornerSize, height: cornerSize)
                        VStack(alignment: .trailing, spacing: 4) {
                            Rectangle()
                                .fill(Color.white.opacity(0.28))
                                .frame(width: 9, height: 1)
                            Rectangle()
                                .fill(Color.white.opacity(0.42))
                                .frame(width: 15, height: 1)
                            Rectangle()
                                .fill(MacForceNowDesign.accent.opacity(0.86))
                                .frame(width: 21, height: 1)
                        }
                        .rotationEffect(.degrees(-45))
                        .offset(x: -10, y: -10)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func resizeZone(_ edge: CatalogShowAllResizeEdge, width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(resizeAction(edge))
            .cursor(edge.cursor)
            .accessibilityLabel(edge.accessibilityLabel)
    }
}

enum CatalogShowAllResizeEdge {
    case top
    case bottom
    case left
    case right
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    @MainActor var cursor: NSCursor {
        switch self {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .bottomRight: return .catalogDiagonalResizeForward
        case .topRight, .bottomLeft: return .catalogDiagonalResizeBackward
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .top: return "Resize show all window from top edge"
        case .bottom: return "Resize show all window from bottom edge"
        case .left: return "Resize show all window from left edge"
        case .right: return "Resize show all window from right edge"
        case .topLeft: return "Resize show all window from top left corner"
        case .topRight: return "Resize show all window from top right corner"
        case .bottomLeft: return "Resize show all window from bottom left corner"
        case .bottomRight: return "Resize show all window from bottom right corner"
        }
    }

    func horizontalDelta(from translation: CGFloat) -> CGFloat {
        switch self {
        case .left, .topLeft, .bottomLeft: return -translation
        case .right, .topRight, .bottomRight: return translation
        case .top, .bottom: return 0
        }
    }

    func verticalDelta(from translation: CGFloat) -> CGFloat {
        switch self {
        case .top, .topLeft, .topRight: return -translation
        case .bottom, .bottomLeft, .bottomRight: return translation
        case .left, .right: return 0
        }
    }

    func horizontalOffsetDelta(sizeDelta: CGFloat) -> CGFloat {
        switch self {
        case .left, .topLeft, .bottomLeft: return -sizeDelta / 2
        case .right, .topRight, .bottomRight: return sizeDelta / 2
        case .top, .bottom: return 0
        }
    }

    func verticalOffsetDelta(sizeDelta: CGFloat) -> CGFloat {
        switch self {
        case .top, .topLeft, .topRight: return -sizeDelta / 2
        case .bottom, .bottomLeft, .bottomRight: return sizeDelta / 2
        case .left, .right: return 0
        }
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        modifier(CatalogCursorModifier(cursor: cursor))
    }
}

struct CatalogCursorModifier: ViewModifier {
    let cursor: NSCursor
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, !isHovering {
                    cursor.push()
                    isHovering = true
                } else if !hovering, isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .onDisappear {
                guard isHovering else { return }
                NSCursor.pop()
                isHovering = false
            }
    }
}

@MainActor extension NSCursor {
    static let catalogDiagonalResizeForward = NSCursor.catalogDiagonalResize(angle: 45)
    static let catalogDiagonalResizeBackward = NSCursor.catalogDiagonalResize(angle: -45)

    private static func catalogDiagonalResize(angle: CGFloat) -> NSCursor {
        let size = CGSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        let transform = NSAffineTransform()
        transform.translateX(by: size.width / 2, yBy: size.height / 2)
        transform.rotate(byDegrees: angle)
        transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
        transform.concat()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 3, y: 9))
        path.line(to: CGPoint(x: 15, y: 9))
        path.move(to: CGPoint(x: 3, y: 9))
        path.line(to: CGPoint(x: 7, y: 5))
        path.move(to: CGPoint(x: 3, y: 9))
        path.line(to: CGPoint(x: 7, y: 13))
        path.move(to: CGPoint(x: 15, y: 9))
        path.line(to: CGPoint(x: 11, y: 5))
        path.move(to: CGPoint(x: 15, y: 9))
        path.line(to: CGPoint(x: 11, y: 13))
        path.lineWidth = 1.7
        NSColor.white.setStroke()
        path.stroke()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: CGPoint(x: size.width / 2, y: size.height / 2))
    }
}

struct CatalogShowAllEmptySearchView: View {
    let query: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .nvidiaFont(size: 34, weight: .bold)
                .foregroundStyle(MacForceNowDesign.accent.opacity(0.84))
            Text("No matching games")
                .nvidiaFont(size: 18, weight: .bold)
                .foregroundStyle(.white.opacity(0.88))
            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Try searching by title, genre, store, publisher, input type, rating, or tag." : "No metadata matched \"\(query)\".")
                .nvidiaFont(size: 13, weight: .medium)
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(28)
    }
}
