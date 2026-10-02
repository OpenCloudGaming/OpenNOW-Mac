import AppKit
import Foundation

public struct OPNCouchCoopTile: Codable, Equatable, Sendable {
    public let layout: OPNCouchCoopLayout
    public let instance: Int
    public let frame: CGRect?
    public let backingScale: Double

    public init(layout: OPNCouchCoopLayout, instance: Int, frame: CGRect?, backingScale: Double) {
        self.layout = layout
        self.instance = instance
        self.frame = frame
        self.backingScale = backingScale
    }

    public var isTiled: Bool { frame != nil }

    public var pixelSize: CGSize? {
        guard let frame, backingScale.isFinite, backingScale > 0 else { return nil }
        return CGSize(width: frame.width * backingScale, height: frame.height * backingScale)
    }

    static func make(layout: OPNCouchCoopLayout, instance: Int, area: CGRect, backingScale: Double) -> OPNCouchCoopTile {
        OPNCouchCoopTile(
            layout: layout,
            instance: instance,
            frame: OPNCouchCoopTileGeometry.rect(in: area, layout: layout, instance: instance),
            backingScale: backingScale
        )
    }

    @MainActor
    static func forLaunch(
        isActive: Bool = OPNCouchCoopPresence.shared.isActive,
        layout: OPNCouchCoopLayout = OPNCouchCoopPreferences.layout(),
        instance: OPNAppInstance = OPNAppInstance.current
    ) -> OPNCouchCoopTile? {
        guard OPNLabs.isCouchCoopEnabled, isActive, let screen = OPNMainWindow.existing()?.screen ?? NSScreen.main else { return nil }
        return make(layout: layout, instance: instance.number, area: screen.frame, backingScale: Double(screen.backingScaleFactor))
    }
}

enum OPNCouchCoopTileGeometry {
    static let seatCount = 2

    static func rect(in area: CGRect, layout: OPNCouchCoopLayout, instance: Int) -> CGRect? {
        let seat = instance - OPNAppInstance.primaryNumber
        guard seat >= 0, seat < seatCount, area.width > 0, area.height > 0 else { return nil }
        switch layout {
        case .manual:
            return nil
        case .sideBySide:
            let leftWidth = (area.width / 2).rounded(.down)
            guard seat == 0 else {
                return CGRect(x: area.minX + leftWidth, y: area.minY, width: area.width - leftWidth, height: area.height)
            }
            return CGRect(x: area.minX, y: area.minY, width: leftWidth, height: area.height)
        case .topAndBottom:
            let bottomHeight = (area.height / 2).rounded(.down)
            guard seat == 0 else {
                return CGRect(x: area.minX, y: area.minY, width: area.width, height: bottomHeight)
            }
            return CGRect(x: area.minX, y: area.minY + bottomHeight, width: area.width, height: area.height - bottomHeight)
        }
    }
}
