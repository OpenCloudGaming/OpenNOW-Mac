//  Where each stream window goes when several are on screen, as pure geometry.
//
//  The presenter owns the windows and the screens; this owns only the arithmetic, so the placement
//  rules can be asserted without a window server.

import CoreGraphics
import Foundation

enum OPNStreamTileOrientation: String, CaseIterable, Identifiable, Sendable {
    case auto
    case sideBySide
    case topAndBottom

    static let storageKey = "OpenNOW.CouchCoop.Tiling"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Automatic"
        case .sideBySide: "Side by Side"
        case .topAndBottom: "Top and Bottom"
        }
    }

    static var stored: OPNStreamTileOrientation {
        OPNAppPreferenceStorage.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .auto
    }

    static func store(_ orientation: OPNStreamTileOrientation) {
        OPNAppPreferenceStorage.standard.set(orientation.rawValue, forKey: storageKey)
    }
}

struct OPNStreamTile: Equatable, Sendable {
    let frame: CGRect
    let screenIndex: Int
}

enum OPNStreamTileLayout {
    /// One tile per window, in window order. A window gets a whole screen while there are screens to
    /// spare; past that the windows are dealt over the screens in order and a shared screen is split.
    static func tiles(screens: [CGRect], windowCount: Int, orientation: OPNStreamTileOrientation) -> [OPNStreamTile] {
        guard windowCount > 0, !screens.isEmpty else { return [] }
        let share = windowsPerScreen(screenCount: screens.count, windowCount: windowCount)
        var tiles: [OPNStreamTile] = []
        for (screenIndex, count) in share.enumerated() where count > 0 {
            let cells = split(screens[screenIndex], into: count, orientation: orientation)
            tiles.append(contentsOf: cells.map { OPNStreamTile(frame: $0, screenIndex: screenIndex) })
        }
        return tiles
    }

    /// How many windows each screen holds. Earlier screens take the remainder, so the main screen is
    /// never the one left with fewer.
    static func windowsPerScreen(screenCount: Int, windowCount: Int) -> [Int] {
        guard screenCount > 0, windowCount > 0 else { return [] }
        let base = windowCount / screenCount
        let remainder = windowCount % screenCount
        return (0..<screenCount).map { base + ($0 < remainder ? 1 : 0) }
    }

    /// Cuts `area` into `count` cells covering it exactly, reading order from the top left. Edges are
    /// rounded to whole points and shared, so an odd size leaves no seam and no overlap.
    static func split(_ area: CGRect, into count: Int, orientation: OPNStreamTileOrientation) -> [CGRect] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [area] }
        let grid = gridShape(for: count, in: area, orientation: orientation)
        var cells: [CGRect] = []
        for index in 0..<count {
            let row = index / grid.columns
            let column = index % grid.columns
            let cellsInRow = min(grid.columns, count - row * grid.columns)
            let minX = edge(of: area.minX, length: area.width, step: column, steps: cellsInRow)
            let maxX = edge(of: area.minX, length: area.width, step: column + 1, steps: cellsInRow)
            let top = edge(of: 0, length: area.height, step: row, steps: grid.rows)
            let bottom = edge(of: 0, length: area.height, step: row + 1, steps: grid.rows)
            cells.append(CGRect(x: minX, y: area.maxY - bottom, width: maxX - minX, height: bottom - top))
        }
        return cells
    }

    static func gridShape(for count: Int, in area: CGRect, orientation: OPNStreamTileOrientation) -> (columns: Int, rows: Int) {
        let prefersColumns = switch orientation {
        case .auto: area.width >= area.height
        case .sideBySide: true
        case .topAndBottom: false
        }
        if count <= 3 {
            return prefersColumns ? (count, 1) : (1, count)
        }
        let long = Int(Double(count).squareRoot().rounded(.up))
        let short = Int((Double(count) / Double(long)).rounded(.up))
        return prefersColumns ? (long, short) : (short, long)
    }

    private static func edge(of origin: CGFloat, length: CGFloat, step: Int, steps: Int) -> CGFloat {
        origin + (length * CGFloat(step) / CGFloat(steps)).rounded()
    }
}
